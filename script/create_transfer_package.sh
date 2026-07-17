#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
VERSION="2.9.0"
BUILD_NUMBER="291"
DATE_TAG="20260717"
ARCH="arm64"
DIST_DIR="$ROOT_DIR/dist"
APP_OUTPUT_DIR="$DIST_DIR/build-v$VERSION-build$BUILD_NUMBER"
APP_BUNDLE="$APP_OUTPUT_DIR/$APP_NAME.app"
RELEASE_NAME="Codex-Pulse-v$VERSION-build$BUILD_NUMBER"
DMG_PATH="$DIST_DIR/$RELEASE_NAME-$DATE_TAG-$ARCH.dmg"
SHA_PATH="$DMG_PATH.sha256"
NOTES_PATH="$DIST_DIR/$RELEASE_NAME-改版说明.md"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage-$VERSION-build$BUILD_NUMBER"

cd "$ROOT_DIR"

if [[ -e "$DMG_PATH" || -e "$SHA_PATH" || -e "$NOTES_PATH" ]]; then
  echo "Refusing to overwrite an existing $VERSION release artifact." >&2
  exit 1
fi

APP_OUTPUT_DIR="$APP_OUTPUT_DIR" OPEN_APP=0 "$ROOT_DIR/script/build_and_run.sh"

cat >"$NOTES_PATH" <<'NOTES'
# Codex 脉动 2.9.0 改版说明

- build 291 修复主面板与 Widget 的刷新延迟：展示内容变化后约 10 秒内请求重载，密集变化自动合并。
- 安装时注销历史构建副本的 Widget 注册，避免系统在多个同 Bundle ID 扩展之间选错。
- 安装后自动重载 WidgetKit 时间线服务，避免桌面卡片继续显示旧缓存；不删除小组件布局或用户数据。
- 新增自动版本更新检测，默认开启，从项目公开 GitHub Releases 读取最新正式版。
- 启动时自动检查，成功后 24 小时内不重复请求；网络失败时保留上次结果并延后重试。
- 新增设置页更新状态、手动检查、发布说明和查看下载入口。
- 菜单栏在检测到新版本时显示明确提示；不自动下载、不自动安装、不读取 GitHub 凭据。
- 版本比较支持语义化版本、预发布标记与本地开发版，避免把较旧的线上版本误报为更新。
- 未改变 Widget、iCloud 设备同步、额度预测、高级分析或可靠性 schema。

本包为 arm64、ad-hoc 签名、未公证版本。首次打开可能出现 Gatekeeper 提示。
NOTES

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
