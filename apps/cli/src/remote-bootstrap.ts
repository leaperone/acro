// 远程引导脚本(Debian / Ubuntu / WSL)。经 `ssh <target>` 以 base64 传入远端执行:
// 幂等安装依赖 → 拉取 / 更新 acro → 启动 systemd 用户服务 → 把配对码打到 stdout。
// 约定:所有进度日志走 stderr(用户实时可见),唯一的 stdout 输出是配对码那一行。
// 以 base64 参数而非 stdin 传入,好让 ssh 的 stdin 留给交互式认证(密码 / passphrase)。
export const REMOTE_BOOTSTRAP = `set -euo pipefail
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
log() { printf '[acro-ssh] %s\\n' "$*" >&2; }
REPO="\${ACRO_REPO:-https://github.com/leaperone/acro.git}"
BRANCH="\${ACRO_BRANCH:-main}"
DIR="$HOME/acro"

apt_install() { sudo apt-get update -qq && sudo apt-get install -y -qq "$@"; }

command -v git >/dev/null || { log "安装 git"; apt_install git; }
command -v curl >/dev/null || { log "安装 curl"; apt_install curl; }

if ! command -v node >/dev/null || [ "$(node -pe 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 23 ]; then
  log "安装 Node.js 24 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >&2
  apt_install nodejs
fi

if ! dpkg -s build-essential >/dev/null 2>&1 || ! dpkg -s python3 >/dev/null 2>&1; then
  log "安装编译工具 build-essential python3 (node-pty 现编)"
  apt_install build-essential python3
fi

command -v pnpm >/dev/null || { log "启用 pnpm (corepack)"; sudo corepack enable || corepack enable; }

if [ -d "$DIR/.git" ]; then
  log "更新 $DIR ($BRANCH)"
  git -C "$DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$DIR" checkout -q "$BRANCH"
  git -C "$DIR" reset --hard -q "origin/$BRANCH"
else
  log "克隆 $REPO ($BRANCH) 到 $DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$DIR" >&2
fi

cd "$DIR"
log "pnpm install(现编 node-pty)"
pnpm install --prefer-offline >&2

log "安装并启动 systemd 用户服务"
bash scripts/install-systemd.sh >&2
loginctl enable-linger "$USER" >/dev/null 2>&1 || true
# 非交互 SSH 会话里 systemctl --user 需要 XDG_RUNTIME_DIR + 已就绪的 user manager
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for _ in $(seq 1 10); do systemctl --user show-environment >/dev/null 2>&1 && break; sleep 1; done
systemctl --user daemon-reload
systemctl --user enable --now acro-runtime.service

log "等待配对码"
for _ in $(seq 1 30); do [ -f "$HOME/.acro/bootstrap-offer.txt" ] && break; sleep 1; done
if [ ! -f "$HOME/.acro/bootstrap-offer.txt" ]; then
  log "未生成配对码,查看: journalctl --user -u acro-runtime.service -e"
  exit 1
fi
cat "$HOME/.acro/bootstrap-offer.txt"
log "完成"
`;
