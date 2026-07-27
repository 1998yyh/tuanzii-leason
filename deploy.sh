#!/usr/bin/env bash
# 团子课堂 · 一键部署到腾讯云 CVM（OpenCloudOS 9）
# 用法：
#   1. cp deploy.env.example deploy.env 并填好（推荐填 DEPLOY_PASSWORD）
#   2. ./deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

ENV_FILE="${DEPLOY_ENV_FILE:-$ROOT/deploy.env}"
NGINX_TEMPLATE="$ROOT/deploy/nginx-tuanzii.conf"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok() { echo "✅ $*"; }

# —— 加载配置 ——
[[ -f "$ENV_FILE" ]] || die "缺少 $ENV_FILE，请先：cp deploy.env.example deploy.env 并填写"

# 不用 process substitution（部分环境会加载失败）；写临时文件再 source
TMP_ENV="$(mktemp)"
# 去 CRLF、去行尾空白、跳过空行与注释
sed -e 's/\r$//' -e 's/[[:space:]]*$//' "$ENV_FILE" \
  | grep -v '^[[:space:]]*$' \
  | grep -v '^[[:space:]]*#' >"$TMP_ENV" || true
set -a
# shellcheck disable=SC1090
source "$TMP_ENV"
set +a
rm -f "$TMP_ENV"

: "${DEPLOY_HOST:?请在 deploy.env 中设置 DEPLOY_HOST}"
: "${DEPLOY_USER:?请在 deploy.env 中设置 DEPLOY_USER}"
DEPLOY_PORT="${DEPLOY_PORT:-9000}"
DEPLOY_WEB_ROOT="${DEPLOY_WEB_ROOT:-/var/www/tuanzii}"
DEPLOY_SSH_PORT="${DEPLOY_SSH_PORT:-22}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-}"
DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-}"

# 展开 ~
if [[ -n "${DEPLOY_SSH_KEY}" ]]; then
  DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY/#\~/$HOME}"
fi

# 填了密码就走密码；密钥文件不存在时忽略（避免把密码误填进 KEY 字段）
if [[ -n "$DEPLOY_PASSWORD" ]]; then
  DEPLOY_SSH_KEY=""
elif [[ -n "$DEPLOY_SSH_KEY" && ! -f "$DEPLOY_SSH_KEY" ]]; then
  die "SSH 私钥不存在: $DEPLOY_SSH_KEY（若用密码登录，请填 DEPLOY_PASSWORD，并把 DEPLOY_SSH_KEY 留空）"
fi

[[ -n "$DEPLOY_PASSWORD" || -n "$DEPLOY_SSH_KEY" ]] \
  || die "请在 deploy.env 中设置 DEPLOY_PASSWORD（密码）或 DEPLOY_SSH_KEY（密钥）二选一"

# —— SSH 封装：密码优先用 sshpass，否则用密钥 ——
SSH_BASE=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

if [[ -n "$DEPLOY_PASSWORD" ]]; then
  command -v sshpass >/dev/null || die "密码部署需要 sshpass。macOS 安装：brew install hudochenkov/sshpass/sshpass
  或：brew install esolitos/ipa/sshpass"
  export SSHPASS="$DEPLOY_PASSWORD"
  SSH_BASE+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
  # BatchMode 与密码不兼容，这里不加
  ssh_cmd() { sshpass -e ssh "${SSH_BASE[@]}" -p "$DEPLOY_SSH_PORT" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }
  scp_cmd() { sshpass -e scp "${SSH_BASE[@]}" -P "$DEPLOY_SSH_PORT" "$@"; }
  RSYNC_RSH="sshpass -e ssh ${SSH_BASE[*]} -p ${DEPLOY_SSH_PORT}"
  AUTH_MODE="密码"
elif [[ -n "$DEPLOY_SSH_KEY" ]]; then
  SSH_BASE+=(-o BatchMode=yes -i "$DEPLOY_SSH_KEY")
  ssh_cmd() { ssh "${SSH_BASE[@]}" -p "$DEPLOY_SSH_PORT" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }
  scp_cmd() { scp "${SSH_BASE[@]}" -P "$DEPLOY_SSH_PORT" "$@"; }
  RSYNC_RSH="ssh ${SSH_BASE[*]} -p ${DEPLOY_SSH_PORT}"
  AUTH_MODE="密钥"
fi

command -v rsync >/dev/null || die "本地需要 rsync（macOS 一般自带；没有则 brew install rsync）"
command -v python3 >/dev/null || die "本地需要 python3"
[[ -f "$NGINX_TEMPLATE" ]] || die "缺少 Nginx 模板: $NGINX_TEMPLATE"

echo "=== 团子课堂一键部署 ==="
echo "  目标: ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_SSH_PORT}"
echo "  认证: ${AUTH_MODE}"
echo "  站点: http://${DEPLOY_HOST}:${DEPLOY_PORT}/"
echo "  目录: ${DEPLOY_WEB_ROOT}"
echo

# —— 1. 本地构建 ——
info "本地构建 dist/ …"
python3 "$ROOT/build.py"
[[ -f "$ROOT/dist/index.html" ]] || die "构建失败：dist/index.html 不存在"
ok "构建完成"

# —— 2. 探测 SSH ——
info "检测 SSH 连通性 …"
ssh_cmd "echo ok" >/dev/null || die "SSH 连接失败，请检查 IP / 用户 / 密码(或密钥) / 安全组 22 端口"
ok "SSH 通"

# —— 3. 远端安装 Nginx（先不启动，避开已被占用的 80）——
info "远端安装 Nginx …"
ssh_cmd "bash -s -- '$DEPLOY_PORT' '$DEPLOY_WEB_ROOT'" <<'REMOTE'
set -euo pipefail
PORT="$1"
WEB_ROOT="$2"

if ! command -v dnf >/dev/null 2>&1; then
  echo "当前系统没有 dnf，本脚本面向 OpenCloudOS 9 / RHEL 系" >&2
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  dnf install -y nginx
fi

mkdir -p "$WEB_ROOT"
chmod -R a+rX "$WEB_ROOT"

# 默认 nginx.conf 内嵌 listen 80 的 server；若只注释 listen，
# nginx 会对「无 listen 的 server」默认回落到 80，仍会冲突。整段注释掉。
if grep -qE 'root\s+/usr/share/nginx/html' /etc/nginx/nginx.conf \
   && ! grep -q 'tuanzii-default-server-disabled' /etc/nginx/nginx.conf; then
  cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"
  python3 - <<'PY'
from pathlib import Path
import re
p = Path("/etc/nginx/nginx.conf")
text = p.read_text()
# 匹配第一个指向发行版默认 html 的 server 块
pattern = re.compile(r"\n    server \{.*?\n    \}\n", re.S)
for m in pattern.finditer(text):
    block = m.group(0)
    if "/usr/share/nginx/html" not in block:
        continue
    commented = ["\n# tuanzii-default-server-disabled\n"]
    for line in block.splitlines(True):
        if line.strip() == "":
            commented.append(line)
        elif line.lstrip().startswith("#"):
            commented.append(line)
        else:
            commented.append("#" + line)
    text = text[: m.start()] + "".join(commented) + text[m.end() :]
    p.write_text(text)
    print("default server block commented out")
    break
else:
    print("no default html server block to disable")
PY
fi

# firewalld 放行自定义端口
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  firewall-cmd --reload || true
fi

# SELinux：非标准端口需放行（没有 SELinux / 未 enforcing 则跳过）
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t http_port_t -p tcp "$PORT" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "$PORT" 2>/dev/null \
      || true
  fi
fi

systemctl enable nginx
REMOTE
ok "Nginx 已安装（尚未启动，下一步写入 9000 站点配置）"

# —— 4. 上传并启用 Nginx 配置，再启动 ——
info "写入 Nginx 站点配置（端口 ${DEPLOY_PORT}）…"
TMP_CONF="$(mktemp)"
sed -e "s|__LISTEN_PORT__|${DEPLOY_PORT}|g" \
    -e "s|__WEB_ROOT__|${DEPLOY_WEB_ROOT}|g" \
    "$NGINX_TEMPLATE" >"$TMP_CONF"

REMOTE_CONF="/etc/nginx/conf.d/tuanzii.conf"
scp_cmd "$TMP_CONF" "${DEPLOY_USER}@${DEPLOY_HOST}:/tmp/tuanzii.conf"
rm -f "$TMP_CONF"

ssh_cmd "bash -s" <<REMOTE
set -euo pipefail
mv /tmp/tuanzii.conf '$REMOTE_CONF'
nginx -t
systemctl restart nginx
systemctl --no-pager --full status nginx | head -15
REMOTE
ok "Nginx 已在 ${DEPLOY_PORT} 端口运行"

# —— 5. 同步 dist/ ——
info "rsync 同步 dist/ → ${DEPLOY_WEB_ROOT}/ …"
rsync -az --delete \
  -e "$RSYNC_RSH" \
  "$ROOT/dist/" \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_WEB_ROOT}/"

ssh_cmd "chmod -R a+rX '$DEPLOY_WEB_ROOT'"
ok "文件已同步"

echo
echo "🚀 部署完成"
echo "   访问: http://${DEPLOY_HOST}:${DEPLOY_PORT}/"
echo
echo "⚠️  若打不开，请到腾讯云控制台 → 安全组，放行入站 TCP ${DEPLOY_PORT}"
echo "   （本机 firewalld 已尝试放行；云厂商安全组需手动开）"
