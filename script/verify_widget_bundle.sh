#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-2.10.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2102}"
ARCH="${ARCH:-$(uname -m)}"
APP_BUNDLE="${1:-$ROOT_DIR/dist/build-v$VERSION-build$BUILD_NUMBER-$ARCH/Codex 脉动.app}"
APP_INFO="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/CodexSuanliMeter"
WIDGET_BUNDLE="$APP_BUNDLE/Contents/PlugIns/CodexSuanliWidgets.appex"
WIDGET_INFO="$WIDGET_BUNDLE/Contents/Info.plist"
WIDGET_BINARY="$WIDGET_BUNDLE/Contents/MacOS/CodexSuanliWidgets"
WIDGET_SOURCE="$ROOT_DIR/Sources/CodexSuanliWidgets/WidgetBundle.swift"

fail() {
  echo "Widget bundle verification failed: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label expected '$expected', got '$actual'"
}

require_file "$APP_INFO"
require_file "$APP_BINARY"
require_file "$WIDGET_INFO"
require_file "$WIDGET_BINARY"
require_file "$WIDGET_SOURCE"
require_file "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
require_file "$WIDGET_BUNDLE/Contents/Resources/AppIcon.icns"

/usr/bin/plutil -lint "$APP_INFO" "$WIDGET_INFO" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_INFO")" "Codex 脉动" "App display name"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")" "$VERSION" "App version"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")" "$BUILD_NUMBER" "App build"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO")" "dev.codex.balance-dashboard.codex" "App bundle ID"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$WIDGET_INFO")" "Codex 脉动" "Widget display name"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WIDGET_INFO")" "$VERSION" "Widget version"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WIDGET_INFO")" "$BUILD_NUMBER" "Widget build"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET_INFO")" "dev.codex.balance-dashboard.codex.widgets" "Widget bundle ID"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$WIDGET_INFO")" "com.apple.widgetkit-extension" "Extension point"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$WIDGET_INFO")" "MacOSX" "Widget platform"

WIDGET_COUNT="$(/usr/bin/grep -c 'configurationDisplayName' "$WIDGET_SOURCE")"
assert_equal "$WIDGET_COUNT" "7" "Widget configuration count"

LINKED_FRAMEWORKS="$(/usr/bin/otool -L "$WIDGET_BINARY")"
[[ "$LINKED_FRAMEWORKS" == *"WidgetKit.framework"* ]] || fail "WidgetKit.framework is not linked"
[[ "$LINKED_FRAMEWORKS" == *"SwiftUI.framework"* ]] || fail "SwiftUI.framework is not linked"

SYMBOLS="$(/usr/bin/nm -m "$WIDGET_BINARY")"
[[ "$SYMBOLS" == *"external _NSExtensionMain"* ]] || fail "Widget extension lifecycle entry point missing"

ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements - "$WIDGET_BUNDLE" 2>&1)"
[[ "$ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]] || fail "App Sandbox entitlement missing"
[[ "$ENTITLEMENTS" == *"[Bool] true"* ]] || fail "App Sandbox entitlement is not true"
[[ "$ENTITLEMENTS" != *"temporary-exception"* ]] || fail "temporary sandbox exceptions are not allowed"

assert_equal "$(/usr/bin/lipo -archs "$APP_BINARY")" "$ARCH" "App architecture"
assert_equal "$(/usr/bin/lipo -archs "$WIDGET_BINARY")" "$ARCH" "Widget architecture"

echo "Verified App: $APP_BUNDLE"
echo "Verified Widget: $WIDGET_BUNDLE"
echo "Verified $ARCH architecture, 7 widget configurations, icons, standard sandbox, frameworks and signatures."
