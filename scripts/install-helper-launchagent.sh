#!/bin/bash
# 构建、签名并安装使用稳定 TCC 身份的 Computer Use helper。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="one.leaper.acro.helper"
SIGN_IDENTITY="${ACRO_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITIES="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
    | sort -u)"
  if [[ "$(printf '%s\n' "$SIGN_IDENTITIES" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]]; then
    echo "需要通过 ACRO_SIGN_IDENTITY 指定唯一的 Developer ID Application 证书。" >&2
    exit 1
  fi
  SIGN_IDENTITY="$SIGN_IDENTITIES"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "acro-helper 不允许使用 ad-hoc 签名。" >&2
  exit 1
fi

if [[ -n "${ACRO_HELPER_SOURCE_BIN:-}" ]]; then
  SOURCE_BIN="$ACRO_HELPER_SOURCE_BIN"
else
  echo "building helper (release)…"
  (cd "$ROOT/apps/helper-macos" && swift build -c release)
  SOURCE_BIN="$ROOT/apps/helper-macos/.build/release/acro-helper"
fi

if [[ ! -x "$SOURCE_BIN" ]]; then
  echo "helper 不存在或不可执行: $SOURCE_BIN" >&2
  exit 1
fi

ACRO_DIR="$HOME/.acro"
BIN_DIR="$ACRO_DIR/bin"
LOG_DIR="$ACRO_DIR/logs"
AGENTS_DIR="$HOME/Library/LaunchAgents"
HELPER_BIN="$BIN_DIR/acro-helper"
PLIST="$AGENTS_DIR/$LABEL.plist"

install -d -m 700 "$ACRO_DIR" "$BIN_DIR" "$LOG_DIR" "$AGENTS_DIR"
touch "$LOG_DIR/helper.log"
chmod 600 "$LOG_DIR/helper.log"

STAGED_BIN="$(mktemp "$BIN_DIR/.acro-helper.XXXXXX")"
STAGED_PLIST="$(mktemp "$AGENTS_DIR/.$LABEL.XXXXXX")"
trap 'rm -f "$STAGED_BIN" "$STAGED_PLIST"' EXIT

install -m 755 "$SOURCE_BIN" "$STAGED_BIN"
codesign --force --options runtime --timestamp \
  --identifier "$LABEL" --sign "$SIGN_IDENTITY" "$STAGED_BIN"
codesign --verify --strict --verbose=2 "$STAGED_BIN"
SIGN_INFO="$(codesign -dvv --requirements - "$STAGED_BIN" 2>&1)"
if ! grep -Fq "Authority=Developer ID Application:" <<<"$SIGN_INFO" \
  || ! grep -Eq '^TeamIdentifier=[A-Z0-9]+$' <<<"$SIGN_INFO" \
  || ! grep -Fq "designated => identifier \"$LABEL\"" <<<"$SIGN_INFO" \
  || ! grep -Fq 'certificate leaf[field.1.2.840.113635.100.6.1.13]' <<<"$SIGN_INFO"; then
  echo "acro-helper 必须使用固定 identifier 的 Developer ID Application 身份签名。" >&2
  exit 1
fi
if xattr -p com.apple.provenance "$STAGED_BIN" >/dev/null 2>&1; then
  xattr -d com.apple.provenance "$STAGED_BIN"
fi

plutil -create xml1 "$STAGED_PLIST"
plutil -insert Label -string "$LABEL" "$STAGED_PLIST"
plutil -insert ProgramArguments -array "$STAGED_PLIST"
plutil -insert ProgramArguments.0 -string "$HELPER_BIN" "$STAGED_PLIST"
plutil -insert RunAtLoad -bool true "$STAGED_PLIST"
plutil -insert KeepAlive -bool true "$STAGED_PLIST"
plutil -insert LimitLoadToSessionType -string Aqua "$STAGED_PLIST"
plutil -insert StandardOutPath -string "$LOG_DIR/helper.log" "$STAGED_PLIST"
plutil -insert StandardErrorPath -string "$LOG_DIR/helper.log" "$STAGED_PLIST"
plutil -lint "$STAGED_PLIST" >/dev/null
if xattr -p com.apple.provenance "$STAGED_PLIST" >/dev/null 2>&1; then
  xattr -d com.apple.provenance "$STAGED_PLIST"
fi

mv -f "$STAGED_BIN" "$HELPER_BIN"
mv -f "$STAGED_PLIST" "$PLIST"

echo "已安装签名 helper: $HELPER_BIN"
echo "已写入 LaunchAgent: $PLIST"
echo "加载或重启 helper:"
echo "  launchctl bootout gui/\$(id -u) $PLIST 2>/dev/null || true"
echo "  launchctl bootstrap gui/\$(id -u) $PLIST"
echo "首次从旧 ad-hoc helper 迁移时，macOS 可能要求重新授权一次。"
