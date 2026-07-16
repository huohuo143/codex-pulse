#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex 脉动"
EXECUTABLE_NAME="CodexSuanliMeter"
VERSION="2.5.2"
DATE_TAG="20260716"
ARCH="arm64"
DIST_DIR="$ROOT_DIR/dist"
APP_OUTPUT_DIR="$DIST_DIR/build-v$VERSION"
APP_BUNDLE="$APP_OUTPUT_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-v$VERSION-$DATE_TAG-$ARCH.dmg"
SHA_PATH="$DMG_PATH.sha256"
NOTES_PATH="$DIST_DIR/$APP_NAME-v$VERSION-改版说明.md"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage-$VERSION"

cd "$ROOT_DIR"

if [[ -e "$DMG_PATH" || -e "$SHA_PATH" || -e "$NOTES_PATH" ]]; then
  echo "Refusing to overwrite an existing $VERSION release artifact." >&2
  exit 1
fi

APP_OUTPUT_DIR="$APP_OUTPUT_DIR" OPEN_APP=0 "$ROOT_DIR/script/build_and_run.sh"

cat >"$NOTES_PATH" <<'NOTES'
# Codex 脉动 2.5.2 改版说明

- App 正式更名为“Codex 脉动”，保留原 Bundle ID、进程名和数据目录，历史统计与设置无需迁移。
- 新增 7 款 macOS WidgetKit 桌面小组件：总览、7 天额度、Codex 重置雷达、Full reset 权益、Token 汇总、Token 趋势、项目与用途。
- 中/大号总览复刻悬浮框的核心信息；用户也可按关注点拆分组合小组件。
- 新增“启用悬浮框”总开关；关闭后由 Codex 自动唤起时静默后台运行，手动打开 App 仍显示普通主窗口。
- 悬浮框可分别勾选 7 天额度、滚动 24h Token、重置雷达与 Full reset 权益，八种样式会自动适配内容和尺寸。
- 新增“跟随系统 / 白天 / 夜晚”三种背景模式；主窗口、设置页和八种悬浮样式均可自动或手动切换，桌面小组件随 macOS 外观适配。
- Widget 扩展启用标准 App Sandbox；主 App 将脱敏聚合快照写入扩展自身容器，不读取会话内容、凭据、项目路径或权益兑换 ID。
- 修复 2.5.1 中扩展入口按普通 SwiftPM 可执行程序链接、WidgetKit 无法取得组件清单的问题；改为原生 App Extension 生命周期后，系统可识别全部 7 款组件并生成预览。
- 主 App 最多每分钟通知 WidgetKit 重载；雷达仍保持独立 30 分钟同步，未增加额外公开源请求。
- 新增额度环/雷达主题的原生多尺寸 macOS logo，统一用于 Dock、Finder 与小组件库。
- 设置页新增桌面小组件说明和“致谢”区：感谢最初源码与构思作者 waytosea-oss；感谢 Codex 重置雷达公开数据，官网署名为“designed by Codex”。
- 延续 2.4.7 的重置雷达防回退、Full reset 只读展示、八种悬浮样式、拖动优化、工作分析、CSV 和独立安装边界。

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
