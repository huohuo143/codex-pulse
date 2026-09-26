#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
VERSION="${VERSION:-2.11.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2119}"
DATE_TAG="${DATE_TAG:-$(/bin/date +%Y%m%d)}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64)
    ARCH_LABEL="Apple Silicon arm64"
    ;;
  x86_64)
    ARCH_LABEL="Intel x86_64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH (expected arm64 or x86_64)" >&2
    exit 2
    ;;
esac

DIST_DIR="${CODEX_PULSE_DIST_DIR:-$ROOT_DIR/dist}"
APP_OUTPUT_DIR="$DIST_DIR/build-v$VERSION-build$BUILD_NUMBER-$ARCH"
APP_BUNDLE="$APP_OUTPUT_DIR/$APP_NAME.app"
RELEASE_NAME="Codex-Pulse-v$VERSION-build$BUILD_NUMBER"
DMG_PATH="$DIST_DIR/$RELEASE_NAME-$DATE_TAG-$ARCH.dmg"
SHA_PATH="$DMG_PATH.sha256"
NOTES_PATH="$DIST_DIR/$RELEASE_NAME-$ARCH-改版说明.md"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage-$VERSION-build$BUILD_NUMBER-$ARCH"

cd "$ROOT_DIR"

if [[ -e "$DMG_PATH" || -e "$SHA_PATH" || -e "$NOTES_PATH" ]]; then
  echo "Refusing to overwrite an existing $VERSION release artifact." >&2
  exit 1
fi

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ARCH="$ARCH" \
  APP_OUTPUT_DIR="$APP_OUTPUT_DIR" OPEN_APP=0 \
  "$ROOT_DIR/script/build_and_run.sh"

cp "$ROOT_DIR/docs/RELEASE_$VERSION.md" "$NOTES_PATH"
/usr/bin/printf '\n本包为 %s、ad-hoc 签名、未公证版本。首次打开可能出现 Gatekeeper 提示。\n' \
  "$ARCH_LABEL" >>"$NOTES_PATH"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"
cp "$NOTES_PATH" "$STAGE_DIR/改版说明.md"

cp "$ROOT_DIR/script/install_preserving_settings.command" "$STAGE_DIR/安装或更新（保留设置）.command"
chmod +x "$STAGE_DIR/安装或更新（保留设置）.command"

/usr/bin/hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

(cd "$DIST_DIR" && /usr/bin/shasum -a 256 "${DMG_PATH##*/}" >"$SHA_PATH")
echo "DMG: $DMG_PATH"
echo "SHA-256: $SHA_PATH"
echo "Notes: $NOTES_PATH"
