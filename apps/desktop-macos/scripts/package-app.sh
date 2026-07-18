#!/bin/bash
# 打包 Acro.app 与分发 zip。用法:scripts/package-app.sh [version]
# 前置:scripts/setup-ghostty.sh 已就绪(GhosttyKit.xcframework + Resources)
set -euo pipefail

VERSION="${1:-0.0.0}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

swift build -c release

APP="dist/Acro.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AcroDesktop "$APP/Contents/MacOS/AcroDesktop"
cp -RL Resources/ghostty "$APP/Contents/Resources/ghostty"
cp -RL Resources/terminfo "$APP/Contents/Resources/terminfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AcroDesktop</string>
    <key>CFBundleIdentifier</key><string>one.leaper.acro.desktop</string>
    <key>CFBundleName</key><string>Acro</string>
    <key>CFBundleDisplayName</key><string>Acro</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" "dist/Acro-v${VERSION}-macos.zip"

# DMG:标准拖入 /Applications 安装盘
STAGE="dist/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Acro.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Acro" -srcfolder "$STAGE" -ov -format UDZO \
    "dist/Acro-v${VERSION}-macos.dmg" > /dev/null
rm -rf "$STAGE"
echo "==> dist/Acro-v${VERSION}-macos.zip"
echo "==> dist/Acro-v${VERSION}-macos.dmg"
