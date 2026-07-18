#!/bin/bash
# 打包 Acro.app 与分发 zip/dmg。用法:scripts/package-app.sh [version]
# 前置:scripts/setup-ghostty.sh 已就绪(GhosttyKit.xcframework + Resources)
#
# 签名:ACRO_SIGN_IDENTITY 设为 Developer ID 证书名则正式签名(hardened runtime),
#      未设则 ad-hoc(本地开发/无证书 CI 回退)。
# 公证:同时设 ACRO_NOTARY_KEY(p8 路径)、ACRO_NOTARY_KEY_ID、ACRO_NOTARY_ISSUER
#      则走 notarytool 公证 + staple;缺任一则跳过。
set -euo pipefail

VERSION="${1:-0.0.0}"
SIGN_IDENTITY="${ACRO_SIGN_IDENTITY:--}"
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

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP"
else
    echo "==> signing with: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

ZIP="dist/Acro-v${VERSION}-macos.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${ACRO_NOTARY_KEY:-}" && -n "${ACRO_NOTARY_KEY_ID:-}" && -n "${ACRO_NOTARY_ISSUER:-}" ]]; then
    echo "==> notarizing"
    xcrun notarytool submit "$ZIP" \
        --key "$ACRO_NOTARY_KEY" \
        --key-id "$ACRO_NOTARY_KEY_ID" \
        --issuer "$ACRO_NOTARY_ISSUER" \
        --wait
    xcrun stapler staple "$APP"
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

# DMG:标准拖入 /Applications 安装盘
STAGE="dist/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Acro.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Acro-v${VERSION}-macos.dmg"
hdiutil create -volname "Acro" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${ACRO_NOTARY_KEY:-}" && -n "${ACRO_NOTARY_KEY_ID:-}" && -n "${ACRO_NOTARY_ISSUER:-}" ]]; then
    xcrun notarytool submit "$DMG" \
        --key "$ACRO_NOTARY_KEY" \
        --key-id "$ACRO_NOTARY_KEY_ID" \
        --issuer "$ACRO_NOTARY_ISSUER" \
        --wait
    xcrun stapler staple "$DMG"
fi

echo "==> $ZIP"
echo "==> $DMG"
