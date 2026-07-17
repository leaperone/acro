#!/bin/bash
# 下载预编译 GhosttyKit.xcframework 与 ghostty 运行资源(取自 muxy 的做法,MIT)。
# 产物不入库;重新下载先 rm -rf GhosttyKit.xcframework Resources GhosttyKit/ghostty.h
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_REPO="muxy-app/ghostty"
TAG="${ACRO_GHOSTTY_TAG:-build-2026-04-29}" # pin;升级时改这里并回归验证

cd "$DIR"

if [[ ! -d GhosttyKit.xcframework ]]; then
    echo "==> downloading GhosttyKit.xcframework ($TAG)"
    gh release download "$TAG" --pattern "GhosttyKit.xcframework.tar.gz" --repo "$FORK_REPO"
    tar xzf GhosttyKit.xcframework.tar.gz
    rm GhosttyKit.xcframework.tar.gz
fi

if [[ ! -d Resources/ghostty ]]; then
    echo "==> downloading ghostty resources ($TAG)"
    gh release download "$TAG" --pattern "GhosttyKit-resources.tar.gz" --repo "$FORK_REPO"
    mkdir -p Resources
    tar xzf GhosttyKit-resources.tar.gz -C Resources
    rm GhosttyKit-resources.tar.gz
fi

cp GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h GhosttyKit/ghostty.h
echo "==> ghostty ready"
