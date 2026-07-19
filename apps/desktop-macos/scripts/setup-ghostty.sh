#!/bin/bash
# 下载预编译 GhosttyKit.xcframework 与 ghostty 运行资源(取自 muxy 的做法,MIT)。
# 产物不入库;重新下载先 rm -rf GhosttyKit.xcframework Resources GhosttyKit/ghostty.h
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_REPO="muxy-app/ghostty"
TAG="${ACRO_GHOSTTY_TAG:-build-2026-04-29}" # pin;升级时改这里并回归验证
case "$TAG" in
    build-2026-04-29)
        XCFRAMEWORK_SHA256="8f30a557470383e21f1dcfcf0b8278a3a08eb6ca5a886c32238425fa8b43bf8e"
        RESOURCES_SHA256="877081c96cf4bc97fa7a15c397ad285f6e5c544ec43778b0903011eff9a74ca2"
        ;;
    *)
        echo "untrusted Ghostty release: $TAG" >&2
        exit 1
        ;;
esac

cd "$DIR"

download_asset() {
    local name="$1"
    local sha256="$2"
    rm -f "$name"
    gh release download "$TAG" --pattern "$name" --repo "$FORK_REPO"
    printf '%s  %s\n' "$sha256" "$name" | shasum -a 256 -c -
}

if [[ ! -d GhosttyKit.xcframework ]]; then
    echo "==> downloading GhosttyKit.xcframework ($TAG)"
    download_asset "GhosttyKit.xcframework.tar.gz" "$XCFRAMEWORK_SHA256"
    tar xzf GhosttyKit.xcframework.tar.gz
    rm GhosttyKit.xcframework.tar.gz
fi

if [[ ! -d Resources/ghostty ]]; then
    echo "==> downloading ghostty resources ($TAG)"
    download_asset "GhosttyKit-resources.tar.gz" "$RESOURCES_SHA256"
    mkdir -p Resources
    tar xzf GhosttyKit-resources.tar.gz -C Resources
    rm GhosttyKit-resources.tar.gz
fi

cp GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h GhosttyKit/ghostty.h
echo "==> ghostty ready"
