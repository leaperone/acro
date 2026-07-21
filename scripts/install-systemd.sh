#!/bin/bash
# 生成并安装 Acro Runtime 的 systemd 用户服务(Linux 服务器 / Windows WSL)。
# 以登录用户运行、拥有 ~/.acro,无需 root。对标 macOS 的 install-launchagents.sh。
# iOS 模拟器与 Computer Use 是 macOS 专有,不在此;浏览器表面视是否安装 Chromium。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_BIN="$(command -v node)"
UNIT_DIR="$HOME/.config/systemd/user"
install -d -m 700 "$HOME/.acro" "$HOME/.acro/logs"
mkdir -p "$UNIT_DIR"

# 从源码运行(与 macOS LaunchAgent 一致):Node 直接执行 .ts,daemon 入口由
# import.meta.url 自动解析,无需构建,也无需 ACRO_DAEMON_ENTRY。
cat > "$UNIT_DIR/acro-runtime.service" <<EOF
[Unit]
Description=Acro Runtime

[Service]
Type=simple
ExecStart=${NODE_BIN} ${ROOT}/apps/runtime/src/index.ts
Restart=always
RestartSec=2
# terminal daemon 由 runtime detached 派生,必须活过 runtime 重启以保住会话。
# KillMode=process 让 systemd 停/重启本服务时只终止 runtime 主进程,不波及已脱离的 daemon。
KillMode=process

[Install]
WantedBy=default.target
EOF

echo "已写入:$UNIT_DIR/acro-runtime.service"
echo
echo "前置依赖(目标机一次性):"
echo "  - Node.js ≥ 23.6(可直接运行 .ts;22.x 需在 ExecStart 加 --experimental-strip-types)"
echo "  - node-pty 现编工具链:build-essential python3"
echo "  - 端口面板用 ss(iproute2,通常自带);实时 cwd 读 /proc,无需 lsof"
echo "  - 可选浏览器表面:npx playwright install --with-deps chromium"
echo "  - 在仓库根跑一次 pnpm install(现编 node-pty)"
echo
echo "启用(开机自启 + 立即启动):"
echo "  loginctl enable-linger \"\$USER\"    # 无登录会话也保持运行,headless 服务器必需"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user enable --now acro-runtime.service"
echo
echo "查看日志与首次配对码:"
echo "  journalctl --user -u acro-runtime.service -f"
echo "  cat ~/.acro/bootstrap-offer.txt"
echo
echo "客户端从其他设备连接需公网可达:LAN 直连自动写入配对码;跨网用你的 FRP/代理"
echo "把 host:port 追加进入口(acro endpoints add 或 device.share 的 extraEndpoints)。"
