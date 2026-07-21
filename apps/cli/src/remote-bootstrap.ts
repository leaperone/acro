// 远程引导脚本(Debian / Ubuntu / WSL)。经 `ssh -t <target>` 在远端执行,输出全程直通用户终端:
// 幂等安装依赖 → 拉取 / 更新 acro → 编译 → 安装并(重)启动 systemd 用户服务 → 等 runtime 就绪。
// -t 分配 PTY,好让需要密码的 sudo 能提示。配对码不在这里取——装完后由客户端单独一段干净 ssh
// `cat ~/.acro/bootstrap-offer.txt` 拿回(见 cli.ts),避免把安装噪声和配对码混在一条流里。
export const REMOTE_BOOTSTRAP = `set -euo pipefail
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
log() { printf '[acro-ssh] %s\\n' "$*"; }
REPO="\${ACRO_REPO:-https://github.com/leaperone/acro.git}"
BRANCH="\${ACRO_BRANCH:-main}"
DIR="$HOME/acro"

apt_install() { sudo apt-get update -qq && sudo apt-get install -y -qq "$@"; }

command -v git >/dev/null || { log "安装 git"; apt_install git; }
command -v curl >/dev/null || { log "安装 curl"; apt_install curl; }

if ! command -v node >/dev/null || [ "$(node -pe 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 23 ]; then
  log "安装 Node.js 24 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
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
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$DIR"
fi

cd "$DIR"
log "pnpm install(现编 node-pty)"
pnpm install --prefer-offline

log "安装 systemd 用户服务"
bash scripts/install-systemd.sh
# 无登录会话也保活;polkit 可能要求管理员认证,优先走 sudo(装阶段本就依赖 sudo)
sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || loginctl enable-linger "$USER" >/dev/null 2>&1 || true
# 非交互 SSH 会话里 systemctl --user 需要 XDG_RUNTIME_DIR + 已就绪的 user manager
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for _ in $(seq 1 10); do systemctl --user show-environment >/dev/null 2>&1 && break; sleep 1; done
systemctl --user daemon-reload
systemctl --user enable acro-runtime.service
# restart 而非 enable --now:首次启动、更新重跑都能加载新代码(--now 对已运行服务是 no-op)
log "启动 / 重启 runtime"
systemctl --user restart acro-runtime.service

log "等待 runtime 监听 8790"
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:8790/health >/dev/null 2>&1 && break; sleep 1; done
# 首次启动时配对码在监听后写入,留一拍让落盘完成(客户端随后单独 ssh 取回)
sleep 1
log "完成"
`;
