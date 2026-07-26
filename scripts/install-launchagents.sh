#!/bin/bash
# 生成并安装 Acro 的 LaunchAgent(runtime + helper)。
# 在 Mac mini 上以登录用户运行;helper 需要 Aqua 图形会话。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_BIN="$(command -v node)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/.acro/logs"
mkdir -p "$AGENTS_DIR"
install -d -m 700 "$HOME/.acro" "$LOG_DIR"
touch "$LOG_DIR/runtime.log" "$LOG_DIR/helper.log"
chmod 600 "$LOG_DIR/runtime.log" "$LOG_DIR/helper.log"

cat > "$AGENTS_DIR/one.leaper.acro.runtime.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>one.leaper.acro.runtime</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${ROOT}/apps/runtime/src/index.ts</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/runtime.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/runtime.log</string>
</dict>
</plist>
EOF

"$ROOT/scripts/install-helper-launchagent.sh"

echo "已写入:"
echo "  $AGENTS_DIR/one.leaper.acro.runtime.plist"
echo
echo "加载(或重启后自动生效):"
echo "  launchctl bootstrap gui/\$(id -u) $AGENTS_DIR/one.leaper.acro.runtime.plist"
