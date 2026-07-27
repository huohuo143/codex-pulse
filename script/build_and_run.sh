#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
WIDGET_EXECUTABLE_NAME="CodexSuanliWidgets"
BUNDLE_ID="dev.codex.balance-dashboard.codex"
WIDGET_BUNDLE_ID="$BUNDLE_ID.widgets"
VERSION="${VERSION:-2.10.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2102}"
ARCH="${ARCH:-$(uname -m)}"
MIN_SYSTEM_VERSION="14.0"

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported architecture: $ARCH (expected arm64 or x86_64)" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${CODEX_PULSE_DIST_DIR:-$ROOT_DIR/dist}"
APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-$DIST_DIR}"
APP_BUNDLE="$APP_OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SUPPORT_DIR="${CODEX_PULSE_SUPPORT_DIR:-$HOME/Library/Application Support/CodexSuanliMeter}"
BUILD_LOCK="$SUPPORT_DIR/build.lock"
SWIFT_SCRATCH_PATH="${CODEX_PULSE_SWIFT_SCRATCH_PATH:-$ROOT_DIR/.build/swiftpm-$BUILD_NUMBER-$ARCH}"
ICON_PATH="$ROOT_DIR/assets/AppIcon.icns"
WIDGET_ENTITLEMENTS="$ROOT_DIR/config/CodexSuanliWidgets.entitlements"
WIDGET_XCODE_PROJECT="$ROOT_DIR/xcode/CodexPulseWidgets.xcodeproj"
WIDGET_DERIVED_DATA="$ROOT_DIR/.build/xcode-widget-$BUILD_NUMBER-$ARCH"
CONFIGURATION="release"

case "$MODE" in
  run|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  --debug|debug) CONFIGURATION="debug" ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

mkdir -p "$DIST_DIR" "$APP_OUTPUT_DIR" "$SUPPORT_DIR"
touch "$BUILD_LOCK"
trap 'rm -f "$BUILD_LOCK"' EXIT

# 交付打包时不干扰用户已安装的实例；只有“构建并运行”才重启 v2。
# 无论哪种模式都不会触碰旧版 CodexBalance/算力码表 0.1.0。
if [[ "${OPEN_APP:-1}" != "0" ]]; then
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --arch "$ARCH" --scratch-path "$SWIFT_SCRATCH_PATH" --product "$EXECUTABLE_NAME"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --scratch-path "$SWIFT_SCRATCH_PATH" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"
if [[ "$CONFIGURATION" == "debug" ]]; then
  WIDGET_XCODE_CONFIGURATION="Debug"
else
  WIDGET_XCODE_CONFIGURATION="Release"
fi
/usr/bin/xcodebuild \
  -project "$WIDGET_XCODE_PROJECT" \
  -scheme "$WIDGET_EXECUTABLE_NAME" \
  -configuration "$WIDGET_XCODE_CONFIGURATION" \
  -derivedDataPath "$WIDGET_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  PRODUCT_BUNDLE_IDENTIFIER="$WIDGET_BUNDLE_ID" \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  build >/dev/null
WIDGET_XCODE_BUNDLE="$WIDGET_DERIVED_DATA/Build/Products/$WIDGET_XCODE_CONFIGURATION/$WIDGET_EXECUTABLE_NAME.appex"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ ! -f "$ICON_PATH" || ! -f "$WIDGET_ENTITLEMENTS" || ! -d "$WIDGET_XCODE_BUNDLE" ]]; then
  echo "Missing AppIcon.icns, widget entitlements or Xcode widget build." >&2
  exit 1
fi
cp "$ICON_PATH" "$APP_CONTENTS/Resources/AppIcon.icns"

WIDGET_BUNDLE="$APP_CONTENTS/PlugIns/$WIDGET_EXECUTABLE_NAME.appex"
WIDGET_CONTENTS="$WIDGET_BUNDLE/Contents"
WIDGET_MACOS="$WIDGET_CONTENTS/MacOS"
mkdir -p "$APP_CONTENTS/PlugIns"
/usr/bin/ditto --noextattr --norsrc "$WIDGET_XCODE_BUNDLE" "$WIDGET_BUNDLE"
mkdir -p "$WIDGET_CONTENTS/Resources"
cp "$ICON_PATH" "$WIDGET_CONTENTS/Resources/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" "$WIDGET_CONTENTS/Info.plist" >/dev/null
# NAS/iCloud-style filesystems can attach Finder/resource-fork metadata while
# assembling the bundle. Ad-hoc signing rejects those attributes.
xattr -cr "$APP_BUNDLE"
/usr/bin/codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_BUNDLE" >/dev/null
if ! /usr/bin/codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 \
  || ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  LOCAL_OUTPUT_DIR="$SUPPORT_DIR/build-output"
  LOCAL_APP_BUNDLE="$LOCAL_OUTPUT_DIR/$APP_NAME.app"
  LOCAL_WIDGET_BUNDLE="$LOCAL_APP_BUNDLE/Contents/PlugIns/$WIDGET_EXECUTABLE_NAME.appex"
  rm -rf "$LOCAL_APP_BUNDLE"
  mkdir -p "$LOCAL_OUTPUT_DIR"
  /usr/bin/ditto --noextattr --norsrc "$APP_BUNDLE" "$LOCAL_APP_BUNDLE"
  xattr -cr "$LOCAL_APP_BUNDLE"
  /usr/bin/codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$LOCAL_WIDGET_BUNDLE" >/dev/null
  /usr/bin/codesign --force --sign - "$LOCAL_APP_BUNDLE" >/dev/null
  /usr/bin/codesign --verify --deep --strict "$LOCAL_APP_BUNDLE" >/dev/null
  APP_BUNDLE="$LOCAL_APP_BUNDLE"
  APP_CONTENTS="$APP_BUNDLE/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
  INFO_PLIST="$APP_CONTENTS/Info.plist"
  WIDGET_BUNDLE="$APP_CONTENTS/PlugIns/$WIDGET_EXECUTABLE_NAME.appex"
fi

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ARCH="$ARCH" \
  "$ROOT_DIR/script/verify_widget_bundle.sh" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

if [[ "${OPEN_APP:-1}" == "0" && "$MODE" == "run" ]]; then
  echo "Packaged: $APP_BUNDLE"
  exit 0
fi

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    echo "Verified running process: $EXECUTABLE_NAME"
    ;;
esac

echo "App bundle: $APP_BUNDLE"
