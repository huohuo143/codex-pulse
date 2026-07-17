#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
VERSION="2.5.4"
DATE_TAG="20260716"
ARCH="arm64"
DIST_DIR="$ROOT_DIR/dist"
APP_OUTPUT_DIR="$DIST_DIR/build-v$VERSION"
APP_BUNDLE="$APP_OUTPUT_DIR/$APP_NAME.app"
RELEASE_NAME="Codex-Pulse-v$VERSION"
DMG_PATH="$DIST_DIR/$RELEASE_NAME-$DATE_TAG-$ARCH.dmg"
SHA_PATH="$DMG_PATH.sha256"
NOTES_PATH="$DIST_DIR/$RELEASE_NAME-改版说明.md"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage-$VERSION"

cd "$ROOT_DIR"

if [[ -e "$DMG_PATH" || -e "$SHA_PATH" || -e "$NOTES_PATH" ]]; then
  echo "Refusing to overwrite an existing $VERSION release artifact." >&2
  exit 1
fi

APP_OUTPUT_DIR="$APP_OUTPUT_DIR" OPEN_APP=0 "$ROOT_DIR/script/build_and_run.sh"

cat >"$NOTES_PATH" <<'NOTES'
# Codex 脉动 2.5.4 改版说明

- “设置 → 关于”中的“开发维护”署名更正为 `ZhangS`。
- “最初源码与构思”继续在致谢区单独标注为 `waytosea-oss`，不与当前维护者混淆。
- 延续 2.5.3 的最近 24 小时即时悬停气泡、M/亿紧凑读数和精确 Token 整数。
- 未改变 Token 统计、额度解析、重置雷达、Widget 或同步数据口径。

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
BUNDLE_ID="dev.codex.balance-dashboard.codex"
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

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "找不到 $APP_NAME.app。请从 DMG 中直接运行本脚本。"
  read -r "?按回车退出。"
  exit 1
fi

mkdir -p "$DEST_DIR" "$SUPPORT_DIR" "$LEGACY_BACKUP_DIR" "$HOME/Library/LaunchAgents"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
rm -rf "$DEST_APP"
/usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
WIDGET_BUNDLE="$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex"
"$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
/usr/bin/pluginkit -a "$WIDGET_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/pluginkit -e use -i "dev.codex.balance-dashboard.codex.widgets" >/dev/null 2>&1 || true
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
