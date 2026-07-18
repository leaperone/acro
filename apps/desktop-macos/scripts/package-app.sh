#!/bin/bash
# 打包 Acro.app 与分发 zip/dmg。用法:scripts/package-app.sh [version] [build_version]
# 前置:scripts/setup-ghostty.sh 已就绪(GhosttyKit.xcframework + Resources)
#
# 签名:ACRO_SIGN_IDENTITY 设为 Developer ID 证书名则正式签名(hardened runtime),
#      未设则 ad-hoc(本地开发/无证书 CI 回退)。
# 公证:同时设 ACRO_NOTARY_KEY(p8 路径)、ACRO_NOTARY_KEY_ID、ACRO_NOTARY_ISSUER
#      则走 notarytool 公证 + staple;缺任一则跳过。
set -euo pipefail

VERSION="${1:-0.0.0}"
BUILD_VERSION="${2:-0}"
SIGN_IDENTITY="${ACRO_SIGN_IDENTITY:--}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
NODE_ENTITLEMENTS="$DIR/Node.entitlements"
cd "$DIR"

[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || { echo "build_version must be an integer"; exit 1; }
[[ -f "$NODE_ENTITLEMENTS" ]] || { echo "missing Node.entitlements" >&2; exit 1; }

swift build -c release

APP="dist/Acro.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/AcroDesktop "$APP/Contents/MacOS/AcroDesktop"
cp -RL Resources/ghostty "$APP/Contents/Resources/ghostty"
cp -RL Resources/terminfo "$APP/Contents/Resources/terminfo"

# GUI 进程不能依赖用户安装 Node。复制 CI/开发机当前 Node，发布包自包含。
NODE_SOURCE="$(command -v node || true)"
[[ -n "$NODE_SOURCE" && -x "$NODE_SOURCE" ]] \
    || { echo "node executable not found" >&2; exit 1; }
BUNDLED_NODE="$APP/Contents/Resources/node"
cp -L "$NODE_SOURCE" "$BUNDLED_NODE"
chmod 755 "$BUNDLED_NODE"
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/AcroDesktop")"
NODE_ARCHS="$(lipo -archs "$BUNDLED_NODE")"
for ARCH in $APP_ARCHS; do
    [[ " $NODE_ARCHS " == *" $ARCH "* ]] \
        || { echo "bundled node lacks app architecture: $ARCH" >&2; exit 1; }
done
"$BUNDLED_NODE" --version > /dev/null

# 打包 acro CLI(attach 桥):单文件 bundle,客户端机器无需 checkout 仓库
(cd ../cli && pnpm build)
cp ../cli/dist/cli.cjs "$APP/Contents/Resources/cli.cjs"

# 内置本地 runtime + daemon(本地优先:App 自动拉起本机服务)。
# node-pty(原生模块)与 playwright-core 保持 external,随 node_modules 附带
(cd ../runtime && pnpm build)
RT="$APP/Contents/Resources/runtime"
mkdir -p "$RT/node_modules"
cp ../runtime/dist/runtime.cjs ../runtime/dist/daemon.cjs "$RT/"
cp -RL ../runtime/node_modules/node-pty "$RT/node_modules/node-pty"
cp -RL ../runtime/node_modules/playwright-core "$RT/node_modules/playwright-core"
# 桌面包只运行在 macOS；Windows 预编译文件会放大包体，codesign 还会给它们写入
# Sparkle BinaryDelta 不支持的扩展属性。
find "$RT/node_modules/node-pty/prebuilds" -mindepth 1 -maxdepth 1 \
    ! -name 'darwin-*' -exec rm -rf {} +
find "$RT/node_modules/node-pty/prebuilds" -type f -name "spawn-helper" -exec chmod 755 {} +

# Sparkle 自动更新框架(可执行文件 rpath 指向 ../Frameworks)
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

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
    <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/leaperone/acro/main/apps/desktop-macos/appcast.xml</string>
    <key>SUPublicEDKey</key><string>L8iCdFM8cKQvAwF1kOrLzL62X0pXlq248t3Bz3F8yPs=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# 依赖缓存可能带 provenance/quarantine 等扩展属性；签名前统一清掉，
# 避免把非 bundle 元数据带进公证包和后续 delta 基线。
xattr -cr "$APP"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # ad-hoc 没有 Team ID，保留官方 Node 签名里的 library-validation 例外，
    # 才能加载同包的 ad-hoc node-pty；正式包在下方改签为 Acro 最小权限。
    codesign --force --deep --sign - "$APP"
else
    echo "==> signing with: $SIGN_IDENTITY"
    # Sparkle 嵌套组件先签(官方手工签名顺序);Downloader.xpc 保留 sandbox entitlements
    SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
        --sign "$SIGN_IDENTITY" "$SPARKLE_B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
    # 内置 runtime 的原生二进制(node-pty 的 .node 与 spawn-helper)必须逐个签,
    # 否则公证被拒("The staple and validate action failed")
    find "$APP/Contents/Resources/runtime" -type f \( -name "*.node" -o -name "spawn-helper" \) \
        -exec codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" {} \;
    codesign --force --options runtime --timestamp --entitlements "$NODE_ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$BUNDLED_NODE"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

codesign --verify --strict "$BUNDLED_NODE"
NODE_SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$BUNDLED_NODE" 2>/dev/null)"
grep -q 'com.apple.security.cs.allow-jit' <<< "$NODE_SIGNED_ENTITLEMENTS"
if [[ "$SIGN_IDENTITY" != "-" ]] \
    && grep -q 'com.apple.security.get-task-allow' <<< "$NODE_SIGNED_ENTITLEMENTS"; then
    echo "bundled node must not allow debugger attachment" >&2
    exit 1
fi
if [[ -n "$(find "$RT/node_modules/node-pty/prebuilds" -type f -name "spawn-helper" ! -perm -111 -print -quit)" ]]; then
    echo "spawn-helper is not executable" >&2
    exit 1
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
