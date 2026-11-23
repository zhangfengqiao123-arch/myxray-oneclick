#!/usr/bin/env bash
# MyXray 独立自有一键安装器 v1.0, 2026-11-22
# 仅支持全新 Ubuntu VPS；不覆盖已有节点。源码可以托管在自己的 GitHub/域名。
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

say() { printf '\n[MyXray] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die '请以 root 运行：sudo bash install.sh'
[[ -r /etc/os-release ]] || die '找不到系统信息'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'ubuntu' ]] || die '当前版本仅支持 Ubuntu 22.04/24.04/26.04 等 LTS'
[[ "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' || "${VERSION_ID:-}" == '26.04' ]] || die '建议使用 Ubuntu 22.04/24.04/26.04 LTS'
[[ ! -e /etc/myxray/state.json ]] || die '本机已安装 MyXray：请输入 myxray 管理，无需重复安装'
[[ ! -e /usr/local/etc/xray/config.json ]] || die '检测到已有 Xray 配置，避免覆盖。请改用全新 VPS。'
[[ ! -e /etc/systemd/system/xray.service ]] || die '检测到现有 Xray 服务，避免覆盖。请改用全新 VPS。'

say '欢迎使用你自己拥有的 MyXray 一键安装器'
printf '默认协议：VLESS + TCP + REALITY + Vision（兼容 v2rayN）\n'
printf '不会自动修改 SSH 端口、UFW 或云平台安全组。\n'
read -r -p '请输入本台 VPS 的公网 IPv4 地址（如 203.0.113.10）: ' SERVER_IP
read -r -p 'REALITY 目标域名 [www.microsoft.com]: ' SNI
SNI=${SNI:-www.microsoft.com}
read -r -p '监听端口 [443]: ' PORT
PORT=${PORT:-443}
read -r -p '第一个员工英文名 [owner]: ' FIRST_USER
FIRST_USER=${FIRST_USER:-owner}

# Validate input before apt install or editing the server.
python3 - "$SERVER_IP" "$SNI" "$PORT" "$FIRST_USER" <<'PYVALID' || die '输入不合法，请重新执行脚本'
import ipaddress, re, sys
ip, sni, port, name = sys.argv[1:]
a = ipaddress.ip_address(ip)
assert a.version == 4
assert re.fullmatch(r'(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+', sni) and len(sni) <= 253
assert port.isdigit() and 1 <= int(port) <= 65535
assert re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,29}', name)
print('输入检查通过')
PYVALID

if command -v ss >/dev/null 2>&1; then
  if ss -lntH "( sport = :$PORT )" 2>/dev/null | grep -q .; then
    die "端口 $PORT 正在被占用，请选择其他端口或使用全新 VPS"
  fi
fi
read -r -p '确认在本台全新 VPS 安装？请输入 YES: ' CONFIRM
[[ "$CONFIRM" == 'YES' ]] || die '已取消，没有修改系统'

say '安装 Ubuntu 系统依赖'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl python3 qrencode iproute2

say '从 Xray 官方仓库下载核心安装器（不是第三方一键脚本）'
TMP_INSTALL=$(mktemp /tmp/myxray-upstream.XXXXXX.sh)
trap 'rm -f "$TMP_INSTALL"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
  -o "$TMP_INSTALL" || die '官方下载失败；未执行远端脚本'
bash -n "$TMP_INSTALL" || die '官方脚本 Bash 语法校验失败'
bash "$TMP_INSTALL" install || die '官方 Xray 安装失败'
command -v xray >/dev/null 2>&1 || die '未找到 xray 命令'

say '在服务器本地生成专属管理工具（私钥绝不上传代码仓库）'
install -d -m 0755 /usr/local/lib/myxray
cat > /usr/local/lib/myxray/myxrayctl.py <<'MYXRAY_MANAGER_EOF'
#!/usr/bin/env python3
# MyXray 1.0 — management program embedded into install.sh
# Generates local Xray VLESS + REALITY (Vision) configs. Does not contact any third-party service.
import copy
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import quote, urlencode
import uuid

BASE = Path(os.environ.get('MYXRAY_BASE', '/etc/myxray'))
STATE = BASE / 'state.json'
CONF = Path(os.environ.get('MYXRAY_CONFIG', '/usr/local/etc/xray/config.json'))
BACKUPS = Path(os.environ.get('MYXRAY_BACKUPS', '/var/backups/myxray'))
EXPORTS = Path(os.environ.get('MYXRAY_EXPORTS', '/root/myxray-exports'))
XRAY = os.environ.get('MYXRAY_XRAY', '/usr/local/bin/xray')
SYSTEMCTL = os.environ.get('MYXRAY_SYSTEMCTL', 'systemctl')


def error(message):
    raise RuntimeError(message)


def root_required():
    if os.geteuid() != 0 and os.environ.get('MYXRAY_TEST_MODE') != '1':
        error('请使用 root 执行：sudo myxray')


def run(argv, check=True, capture=False):
    return subprocess.run(argv, check=check, text=True, capture_output=capture)


def check_user(name):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,29}', name):
        error('名称只能使用英文开头、英文/数字/下划线/短横线，最长30个字符')
    return name


def check_addr(s):
    s = s.strip()
    try:
        addr = ipaddress.ip_address(s)
        if addr.version != 4:
            error('当前简单版本只支持 IPv4；IPv6 需另行配置')
        return s
    except ValueError:
        pass
    if len(s) > 253 or not re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', s):
        error('请输入有效的 IPv4 地址或完整域名')
    return s


def check_sni(s):
    s = check_addr(s)
    try:
        ipaddress.ip_address(s)
        error('REALITY 目标请输入有效的域名，不能填 VPS IP')
    except ValueError:
        return s


def state_read():
    if not STATE.is_file():
        error('找不到配置：请先在一台全新 VPS 上执行 install.sh')
    return json.loads(STATE.read_text(encoding='utf-8'))


def write_atomic(path, data, mode, group=None):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.myxray-', dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        if group is not None:
            os.fchown(fd, 0, group)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def config_group():
    import grp
    try:
        return grp.getgrnam('xray').gr_gid
    except KeyError:
        error('未找到 xray 系统组，官方 Xray 安装可能失败')


def build_config(s):
    users = [{'id': c['uuid'], 'flow': 'xtls-rprx-vision', 'email': name+'@myxray.local'}
             for name, c in sorted(s['users'].items())]
    return {
        'log': {'loglevel': 'warning'},
        'inbounds': [{
            'tag': 'myxray-in', 'listen': '0.0.0.0', 'port': s['port'],
            'protocol': 'vless',
            'settings': {'clients': users, 'decryption': 'none'},
            'streamSettings': {
                'network': 'tcp', 'security': 'reality',
                'realitySettings': {
                    'show': False,
                    'target': s['sni'] + ':443',
                    'xver': 0,
                    'serverNames': [s['sni']],
                    'privateKey': s['private_key'],
                    'shortIds': [c['sid'] for _, c in sorted(s['users'].items())]
                }
            }
        }],
        'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}]
    }


def config_json(s):
    return json.dumps(build_config(s), ensure_ascii=False, indent=2) + '\n'


def save_backup(quiet=False):
    BACKUPS.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(BACKUPS, 0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    name = BACKUPS / ('backup-' + stamp + '-' + secrets.token_hex(3) + '.tar.gz')
    with tarfile.open(name, 'w:gz') as tf:
        if STATE.exists():
            tf.add(STATE, arcname='state.json')
        if CONF.exists():
            tf.add(CONF, arcname='config.json')
    os.chmod(name, 0o600)
    if not quiet:
        print('备份已保存：' + str(name))
    return name


def apply(s):
    """Validate before swap, then restart; revert previous config on service failure."""
    group = config_group()
    CONF.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    os.chown(CONF.parent, 0, group)
    os.chmod(CONF.parent, 0o750)
    fd, test_path = tempfile.mkstemp(prefix='.myxray-test-', suffix='.json', dir=str(CONF.parent))
    os.close(fd)
    try:
        Path(test_path).write_text(config_json(s), encoding='utf-8')
        os.chmod(test_path, 0o640)
        os.chown(test_path, 0, group)
        result = run([XRAY, 'run', '-test', '-config', test_path], check=False, capture=True)
        if result.returncode != 0:
            error('Xray 配置检查不通过：\n' + (result.stderr or result.stdout))
    finally:
        Path(test_path).unlink(missing_ok=True)

    old_conf = CONF.read_bytes() if CONF.exists() else None
    old_state = STATE.read_bytes() if STATE.exists() else None
    try:
        write_atomic(CONF, config_json(s), 0o640, group)
        result = run([SYSTEMCTL, 'restart', 'xray'], check=False, capture=True)
        if result.returncode != 0:
            error('Xray 服务未能重启：' + (result.stderr or result.stdout))
        result = run([SYSTEMCTL, 'is-active', '--quiet', 'xray'], check=False)
        if result.returncode != 0:
            error('服务不在运行状态')
        BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(BASE, 0o700)
        write_atomic(STATE, json.dumps(s, ensure_ascii=False, indent=2) + '\n', 0o600)
    except Exception:
        if old_conf is None:
            CONF.unlink(missing_ok=True)
        else:
            # rollback exact previous content
            fd, tp = tempfile.mkstemp(prefix='.myxray-rollback-', dir=str(CONF.parent))
            with os.fdopen(fd, 'wb') as f:
                f.write(old_conf)
            os.chmod(tp, 0o640)
            os.chown(tp, 0, group)
            os.replace(tp, CONF)
        if old_state is None:
            STATE.unlink(missing_ok=True)
        else:
            fd, tp = tempfile.mkstemp(prefix='.myxray-rollback-', dir=str(BASE))
            with os.fdopen(fd, 'wb') as f:
                f.write(old_state)
            os.chmod(tp, 0o600)
            os.replace(tp, STATE)
        if old_conf is not None:
            run([SYSTEMCTL, 'restart', 'xray'], check=False)
        else:
            run([SYSTEMCTL, 'stop', 'xray'], check=False)
        raise


def make_user():
    return {'uuid': str(uuid.uuid4()), 'sid': secrets.token_hex(8)}


def create(ip, sni, port, name):
    if STATE.exists():
        error('本机已经存在自有节点；请运行 myxray 查看菜单，禁止重复覆盖')
    name = check_user(name)
    ip = check_addr(ip)
    sni = check_sni(sni)
    if not 1 <= port <= 65535:
        error('端口必须在1至65535之间')
    out = run([XRAY, 'x25519'], capture=True).stdout
    priv = re.search(r'^PrivateKey:\s*(\S+)\s*$', out, re.M | re.I)
    pub = re.search(r'^(?:Password|PublicKey|Public key):\s*(\S+)\s*$', out, re.M | re.I)
    if not priv or not pub:
        error('无法识别 xray x25519 的输出格式，拒绝生成错误配置：\n' + out)
    s = {'schema': 1, 'address': ip, 'port': port, 'sni': sni,
         'private_key': priv.group(1), 'public_key': pub.group(1),
         'users': {name: make_user()}}
    apply(s)
    print('安装成功！\n输入 myxray 可打开管理菜单。\n')
    link(name, s)


def link(name, s=None):
    s = s or state_read()
    check_user(name)
    if name not in s['users']:
        error('没有该员工：' + name)
    c = s['users'][name]
    params = {
        'encryption': 'none', 'security': 'reality',
        'type': 'tcp', 'sni': s['sni'], 'fp': 'chrome',
        'pbk': s['public_key'], 'sid': c['sid'],
        'spx': '/', 'flow': 'xtls-rprx-vision'
    }
    return_url = ('vless://' + c['uuid'] + '@' + s['address'] + ':' + str(s['port'])
                  + '?' + urlencode(params, quote_via=quote) + '#' + quote('myxray-' + name))
    print(return_url)
    return return_url


def qr(name):
    s = state_read()
    c = s['users'].get(name)
    if not c:
        error('员工不存在')
    # link outputs once; qrencode prints the terminal QR.
    uri = link(name, s)
    if not shutil.which('qrencode'):
        error('未安装 qrencode；请先运行 apt install -y qrencode')
    run(['qrencode', '-t', 'ANSIUTF8', '-m', '1', uri])


def export_clash(name):
    s = state_read()
    if name not in s['users']:
        error('员工不存在')
    c = s['users'][name]
    # JSON quoted scalar values are valid YAML scalars.
    label = 'myxray-' + name
    q = json.dumps
    yaml = f'''# Clash Meta / Mihomo YAML. Do not upload publicly; contains credentials.
proxies:
  - name: {q(label)}
    type: vless
    server: {q(s['address'])}
    port: {s['port']}
    uuid: {q(c['uuid'])}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: {q(s['sni'])}
    client-fingerprint: chrome
    reality-opts:
      public-key: {q(s['public_key'])}
      short-id: {q(c['sid'])}
proxy-groups:
  - name: MyXray
    type: select
    proxies:
      - {q(label)}
rules:
  - MATCH,MyXray
'''
    EXPORTS.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(EXPORTS, 0o700)
    path = EXPORTS / (name + '.yaml')
    write_atomic(path, yaml, 0o600)
    print('已生成 Clash Meta/Mihomo 配置：' + str(path))
    print('请通过 FinalShell 安全下载到电脑，然后在 Clash Verge Rev 中导入本地文件。')


def modify(op, name):
    name = check_user(name)
    s = state_read()
    if op == 'add':
        if name in s['users']:
            error('员工已存在')
        s['users'][name] = make_user()
    elif op == 'remove':
        if name not in s['users']:
            error('员工不存在')
        if len(s['users']) == 1:
            error('至少保留一个用户，禁止删掉最后一个')
        del s['users'][name]
    elif op == 'rotate':
        if name not in s['users']:
            error('员工不存在')
        s['users'][name] = make_user()
    save_backup(quiet=True)
    apply(s)
    print('操作完成：' + op + ' ' + name)
    if op != 'remove':
        link(name, s)


def set_address(new_address):
    s = state_read()
    save_backup(quiet=True)
    s['address'] = check_addr(new_address)
    # Does not require restarting Xray, only affects generated connection links.
    write_atomic(STATE, json.dumps(s, ensure_ascii=False, indent=2) + '\n', 0o600)
    print('地址已更新；旧客户端链接需要重新导入。')


def status():
    s = state_read()
    result = run([SYSTEMCTL, 'is-active', 'xray'], check=False, capture=True)
    print('Xray:', result.stdout.strip() or 'unknown')
    print('服务器地址:', s['address'], '端口:', s['port'])
    print('REALITY SNI:', s['sni'], '| 协议：VLESS + TCP/REALITY + Vision')
    print('员工数:', len(s['users']))
    print('防火墙/外网连通性需要另外测试。')


def user_list():
    s = state_read()
    print('员工名单（不展示凭证）：')
    for name in sorted(s['users']):
        print(' - ' + name)


def upgrade():
    # Deliberately use official installer only, never auto-update silently.
    save_backup()
    fd, path = tempfile.mkstemp(prefix='xray-official-', suffix='.sh')
    os.close(fd)
    try:
        run(['curl', '-fL', '--retry', '3', '--connect-timeout', '15',
             'https://github.com/XTLS/Xray-install/raw/main/install-release.sh', '-o', path])
        run(['bash', '-n', path])
        print('即将通过官方安装器更新 Xray，更新可能短暂中断连接。')
        run(['bash', path, 'install'])
        check = run([XRAY, 'run', '-test', '-config', str(CONF)], check=False)
        if check.returncode != 0:
            error('更新后配置检查失败，请查看备份和官方版本回退方法')
        print('更新结果：')
        run([XRAY, 'version'])
        run([SYSTEMCTL, 'is-active', 'xray'], check=False)
    finally:
        os.unlink(path)


def menu():
    actions = {
        '1': (lambda: status()),
        '2': (lambda: user_list()),
        '3': (lambda: modify('add', input('新员工英文名: ').strip())),
        '4': (lambda: link(input('员工英文名: ').strip())),
        '5': (lambda: qr(input('员工英文名: ').strip())),
        '6': (lambda: export_clash(input('员工英文名: ').strip())),
        '7': (lambda: modify('rotate', input('需要更换凭证的员工: ').strip())),
        '8': (lambda: modify('remove', input('需要停用的员工: ').strip())),
        '9': (lambda: save_backup()),
        '10': (lambda: set_address(input('新的公网 IP/域名: ').strip())),
        '11': (lambda: upgrade()),
    }
    while True:
        print('\n' + '=' * 43)
        print(' 我的自有节点 MyXray v1.0  |  root 本地管理')
        print('=' * 43)
        print('1  状态检查       2  员工列表')
        print('3  新增员工       4  生成分享链接')
        print('5  显示二维码     6  导出 Clash 配置')
        print('7  更换员工凭证   8  停用员工')
        print('9  备份配置      10  修改公网 IP/域名')
        print('11 官方核心升级    0  退出')
        ch = input('请选择: ').strip()
        if ch == '0':
            return
        if ch not in actions:
            print('选择无效')
            continue
        try:
            actions[ch]()
        except Exception as e:
            print('错误：' + str(e), file=sys.stderr)


def main(argv):
    root_required()
    if len(argv) <= 1 or argv[1] == 'menu':
        menu()
        return
    cmd = argv[1]
    if cmd == 'init' and len(argv) == 6:
        create(argv[2], argv[3], int(argv[4]), argv[5]); return
    if cmd == 'status': status(); return
    if cmd == 'list': user_list(); return
    if cmd == 'backup': save_backup(); return
    if cmd == 'update': upgrade(); return
    if cmd == 'set-address' and len(argv) == 3:
        set_address(argv[2]); return
    if cmd in ['add', 'remove', 'rotate'] and len(argv) == 3:
        modify(cmd, argv[2]); return
    if cmd == 'link' and len(argv) == 3:
        link(argv[2]); return
    if cmd == 'qr' and len(argv) == 3:
        qr(argv[2]); return
    if cmd == 'clash' and len(argv) == 3:
        export_clash(argv[2]); return
    print('用法：myxray [status|list|add|remove|rotate|link|qr|clash|backup|set-address|update] [员工名]', file=sys.stderr)
    sys.exit(2)


if __name__ == '__main__':
    try:
        main(sys.argv)
    except Exception as exc:
        print('错误：' + str(exc), file=sys.stderr)
        sys.exit(1)

MYXRAY_MANAGER_EOF
chmod 0755 /usr/local/lib/myxray/myxrayctl.py
cat > /usr/local/bin/myxray <<'MYXRAY_COMMAND_EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/lib/myxray/myxrayctl.py "$@"
MYXRAY_COMMAND_EOF
chmod 0755 /usr/local/bin/myxray

say '生成专属 UUID、REALITY 密钥、配置并检查启动'
myxray init "$SERVER_IP" "$SNI" "$PORT" "$FIRST_USER" || die '初始化失败，检查前面的报错并不要重复强制安装'

say '完成：以后输入 myxray 进入中文菜单'
printf '\n注意：请在云服务器安全组手动放行 TCP %s；检查 SSH 端口不要误关。\n' "$PORT"
printf 'FinalShell 中复制 vless:// 分享链接导入 v2rayN 即可测试。\n'
