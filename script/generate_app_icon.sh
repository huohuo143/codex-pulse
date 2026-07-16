#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_IMAGE="${1:-$ROOT_DIR/assets/AppIcon-generated.png}"
ASSET_DIR="$ROOT_DIR/assets"
MASTER_IMAGE="$ASSET_DIR/AppIcon-1024.png"
OUTPUT_ICNS="$ASSET_DIR/AppIcon.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-maidong-icon.XXXXXX")"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  echo "Icon source not found: $SOURCE_IMAGE" >&2
  exit 1
fi

mkdir -p "$ASSET_DIR" "$ICONSET_DIR"
/usr/bin/sips -z 1024 1024 "$SOURCE_IMAGE" --out "$MASTER_IMAGE" >/dev/null

make_icon() {
  local size="$1"
  local filename="$2"
  /usr/bin/sips -z "$size" "$size" "$MASTER_IMAGE" --out "$ICONSET_DIR/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
echo "Icon master: $MASTER_IMAGE"
echo "App icon: $OUTPUT_ICNS"
