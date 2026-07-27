#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
VERSION="${VERSION:-2.10.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2102}"
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

DIST_DIR="$ROOT_DIR/dist"
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

cat >"$NOTES_PATH" <<'NOTES'
# Codex 脉动 2.10.0 改版说明

- 趋势页新增“24 小时 / 按天”切换，默认保持原有 24 小时视图。
- 按天视图展示包含今天在内的最近 30 个自然日，可横向滚动并默认定位到最新日期。
- 每日柱支持悬停查看日期、精确 Token 数和调用次数；无调用日期按 0 保留。
- 24 小时和按天视图使用本机时间轴对齐多台 iCloud 设备，并按设备稳定分色堆叠。
- 图例与悬停气泡显示合计、各设备 Token、调用次数和快照更新时间。
- 显式 0 Token 与缺少 bucket 分开处理；缺失值不参与合计，旧 schema 无趋势时不生成虚假数据。
- 本地与 iCloud 设备日序列扩展为 30 天，schema 继续为 4，兼容旧设备的可变长度数组。
- 高级分析仍使用最近 14 天，Widget 的 `daily14` 也仍为 14 天，未改变 Widget schema。
- 完整测试覆盖多设备对齐、缺失值、旧 schema、跨月、跨年、30 日上限和 14 日兼容性。

NOTES
/usr/bin/printf '\n本包为 %s、ad-hoc 签名、未公证版本。首次打开可能出现 Gatekeeper 提示。\n' \
  "$ARCH_LABEL" >>"$NOTES_PATH"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"
cp "$NOTES_PATH" "$STAGE_DIR/改版说明.md"

cat >"$STAGE_DIR/安装并启用自动启动.command" <<'INSTALLER'
#!/bin/zsh
set -euo pipefail

APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
WIDGET_EXECUTABLE_NAME="CodexSuanliWidgets"
BUNDLE_ID="dev.codex.balance-dashboard.codex"
WIDGET_BUNDLE_ID="dev.codex.balance-dashboard.codex.widgets"
LABEL="dev.codex.balance-dashboard.codex.watch-codex"
SOURCE_DIR="${0:A:h}"
SOURCE_APP="$SOURCE_DIR/$APP_NAME.app"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"
LEGACY_APP="$DEST_DIR/Codex算力码表.app"
SUPPORT_DIR="$HOME/Library/Application Support/CodexSuanliMeter"
LEGACY_BACKUP_DIR="$SUPPORT_DIR/legacy-app-backups"
WATCHER_SCRIPT="$SUPPORT_DIR/watch-codex.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "找不到 $APP_NAME.app。请从 DMG 中直接运行本脚本。"
  read -r "?按回车退出。"
  exit 1
fi

mkdir -p "$DEST_DIR" "$SUPPORT_DIR" "$LEGACY_BACKUP_DIR" "$HOME/Library/LaunchAgents"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$WIDGET_EXECUTABLE_NAME" >/dev/null 2>&1 || true

# 只注销历史 Widget 注册，不删除任何历史 App 或构建文件。
while IFS= read -r line; do
  widget_path="${line##*$'\t'}"
  [[ "$widget_path" == *.appex && -d "$widget_path" ]] || continue
  /usr/bin/pluginkit -r "$widget_path" >/dev/null 2>&1 || true
  host_app="${widget_path%%/Contents/PlugIns/*}"
  [[ -d "$host_app" ]] && "$LSREGISTER" -u "$host_app" >/dev/null 2>&1 || true
done < <(/usr/bin/pluginkit -m -A -D -v -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true)

if [[ -d "$DEST_APP" ]]; then
  DEST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
  DEST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
  DEST_BACKUP="$LEGACY_BACKUP_DIR/Codex脉动-v$DEST_VERSION-build$DEST_BUILD-$(/bin/date +%Y%m%d-%H%M%S).app"
  /bin/mv "$DEST_APP" "$DEST_BACKUP"
  echo "已备份已安装版本：$DEST_BACKUP"
fi
/usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
WIDGET_BUNDLE="$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex"
"$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
/usr/bin/pluginkit -a "$WIDGET_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/pluginkit -e use -i "$WIDGET_BUNDLE_ID" >/dev/null 2>&1 || true
WIDGET_REGISTERED=0
for _ in {1..20}; do
  if /usr/bin/pluginkit -m -A -D -v 2>/dev/null | /usr/bin/grep -F "$WIDGET_BUNDLE" >/dev/null; then
    WIDGET_REGISTERED=1
    break
  fi
  /bin/sleep 0.1
done
[[ "$WIDGET_REGISTERED" == "1" ]] || { echo "小组件扩展注册失败。"; exit 1; }

# 清除安装前仍驻留的 WidgetKit 时间线缓存；不删除桌面布局或用户数据。
/usr/bin/killall chronod >/dev/null 2>&1 || true
/usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
/usr/bin/killall Dock >/dev/null 2>&1 || true
/bin/sleep 2

if [[ -d "$LEGACY_APP" ]]; then
  LEGACY_BACKUP="$LEGACY_BACKUP_DIR/Codex算力码表-$(/bin/date +%Y%m%d-%H%M%S).app"
  /bin/mv "$LEGACY_APP" "$LEGACY_BACKUP"
  echo "旧名称 App 已备份：$LEGACY_BACKUP"
fi

cat >"$WATCHER_SCRIPT" <<'WATCHER'
#!/bin/zsh
set -u
APP_PATH="$HOME/Applications/Codex 脉动.app"
while true; do
  if /usr/bin/pgrep -f "Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 ||
     /usr/bin/pgrep -x "Codex" >/dev/null 2>&1 ||
     /usr/bin/pgrep -f "Contents/Resources/codex app-server" >/dev/null 2>&1; then
    if ! /usr/bin/pgrep -x "CodexSuanliMeter" >/dev/null 2>&1 && [[ -d "$APP_PATH" ]]; then
      /usr/bin/open -g "$APP_PATH" --args --background
    fi
  fi
  /bin/sleep 5
done
WATCHER
chmod +x "$WATCHER_SCRIPT"

cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$WATCHER_SCRIPT</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/$LABEL.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/$LABEL.err.log</string>
</dict>
</plist>
PLIST

/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$PLIST"
/usr/bin/open "$DEST_APP"
echo
echo "安装完成：$DEST_APP"
echo "已启用：打开 Codex 时自动启动 Codex 脉动。"
echo "旧版 App 文件仍保留；自动启动已切换为 Codex 脉动。"
read -r "?按回车退出。"
INSTALLER
chmod +x "$STAGE_DIR/安装并启用自动启动.command"

/usr/bin/hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

/usr/bin/shasum -a 256 "$DMG_PATH" >"$SHA_PATH"
echo "DMG: $DMG_PATH"
echo "SHA-256: $SHA_PATH"
echo "Notes: $NOTES_PATH"
