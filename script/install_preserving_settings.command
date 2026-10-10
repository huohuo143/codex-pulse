#!/bin/zsh
# Install one already-built, verified local bundle. No downloads, preference
# resets, new launch agents or desktop-layout/cache resets.
set -euo pipefail
setopt NULL_GLOB
APP_NAME="Codex 脉动"
BUNDLE_ID="dev.codex.balance-dashboard.codex"
SOURCE_APP="${CODEX_PULSE_INSTALL_SOURCE:-${0:A:h}/$APP_NAME.app}"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"
SUPPORT_DIR="$HOME/Library/Application Support/CodexSuanliMeter"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${CODEX_PULSE_BACKUP_DIR:-$SUPPORT_DIR/version-backups/$STAMP}"
LABEL="dev.codex.balance-dashboard.codex.watch-codex"
WATCH_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -d "$SOURCE_APP" ]] || { print -u2 "找不到安装源：$SOURCE_APP"; exit 1; }
[[ "${SOURCE_APP:A}" != "${DEST_APP:A}" ]] || { print -u2 "安装源与目标不能相同"; exit 1; }
[[ ! -e "$BACKUP_DIR" ]] || { print -u2 "备份目录已存在，请使用新的目录"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
[[ "$SOURCE_ID" == "$BUNDLE_ID" ]] || { print -u2 "安装源不是正式版应用"; exit 1; }
if [[ "${1:-}" == "--check" ]]; then
  SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
  SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
  print "检查通过：$SOURCE_VERSION / Build $SOURCE_BUILD；签名有效，正式应用标识匹配。"
  print "目标：$DEST_APP"
  print "备份：$BACKUP_DIR"
  print "仅检查，未写入配置、停止应用或安装。"
  exit 0
fi
[[ $# == 0 ]] || { print -u2 "支持的参数：--check（仅检查）"; exit 2; }
mkdir -p "$DEST_DIR" "$BACKUP_DIR/config"
/usr/bin/defaults export "$BUNDLE_ID" "$BACKUP_DIR/preferences.plist" >/dev/null 2>&1 || true
for item in "$SUPPORT_DIR"/quota-history*.json "$SUPPORT_DIR"/project-budgets-v1.json \
  "$SUPPORT_DIR"/credit-expiry-v1.json "$SUPPORT_DIR"/credit-expiry-v2.json "$SUPPORT_DIR"/model-prices*.json \
  "$SUPPORT_DIR"/radar-evaluation-v1 "$SUPPORT_DIR"/codex-radar-tibo-history.json \
  "$SUPPORT_DIR"/reliability-events-v1.json "$SUPPORT_DIR"/account-scope-salt.txt \
  "$SUPPORT_DIR"/widget-snapshot.json "$SUPPORT_DIR"/live-balance.json \
  "$SUPPORT_DIR"/session-event-cache-v*.plist "$SUPPORT_DIR"/watch-codex.sh; do
  [[ -e "$item" ]] && /usr/bin/ditto "$item" "$BACKUP_DIR/config/${item:t}"
done
[[ -f "$WATCH_PLIST" ]] && /usr/bin/ditto "$WATCH_PLIST" "$BACKUP_DIR/watch-agent.plist"
cat > "$BACKUP_DIR/恢复上一版.command" <<'ROLLBACK'
#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB
BACKUP_DIR="${0:A:h}"
DEST_APP="$HOME/Applications/Codex 脉动.app"
SUPPORT_DIR="$HOME/Library/Application Support/CodexSuanliMeter"
LABEL="dev.codex.balance-dashboard.codex.watch-codex"
WATCH_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -d "$BACKUP_DIR/Codex 脉动.app" ]] || { print -u2 "没有上一版应用可恢复"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$BACKUP_DIR/Codex 脉动.app"
WATCHER_WAS_LOADED=0
if /bin/launchctl print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
  WATCHER_WAS_LOADED=1
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || true
fi
for pid in $(/usr/bin/pgrep -x CodexSuanliMeter || true) $(/usr/bin/pgrep -x CodexSuanliWidgets || true); do
  executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
  [[ "$executable" == "$DEST_APP/Contents/"* ]] && /bin/kill -TERM "$pid" 2>/dev/null || true
done
/bin/sleep 1
/usr/bin/pluginkit -r "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
[[ -d "$DEST_APP" ]] && /bin/mv "$DEST_APP" "$BACKUP_DIR/回滚时保留的新版本-$(/bin/date +%Y%m%d-%H%M%S).app"
/usr/bin/ditto "$BACKUP_DIR/Codex 脉动.app" "$DEST_APP"
for item in "$BACKUP_DIR/config/"*; do /usr/bin/ditto "$item" "$SUPPORT_DIR/${item:t}"; done
[[ -f "$BACKUP_DIR/preferences.plist" ]] && /usr/bin/defaults import dev.codex.balance-dashboard.codex "$BACKUP_DIR/preferences.plist"
"$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
/usr/bin/pluginkit -a "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
if [[ "$WATCHER_WAS_LOADED" == 1 && -f "$WATCH_PLIST" ]]; then /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$WATCH_PLIST"; fi
/usr/bin/open -n "$DEST_APP"
print "已恢复上一版；回滚前的新版本也已保留在 $BACKUP_DIR"
ROLLBACK
chmod +x "$BACKUP_DIR/恢复上一版.command"
STAGED_APP="$DEST_DIR/.Codex-pulse-install-$STAMP.app"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
WATCHER_WAS_LOADED=0
if /bin/launchctl print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
  WATCHER_WAS_LOADED=1
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || true
fi
# Stop only processes whose executable belongs to the installed target.
for pid in $(/usr/bin/pgrep -x CodexSuanliMeter || true) $(/usr/bin/pgrep -x CodexSuanliWidgets || true); do
  executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
  [[ "$executable" == "$DEST_APP/Contents/"* ]] && /bin/kill -TERM "$pid" 2>/dev/null || true
done
/bin/sleep 1
if [[ -d "$DEST_APP" ]]; then
  /usr/bin/pluginkit -r "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$DEST_APP" >/dev/null 2>&1 || true
  /bin/mv "$DEST_APP" "$BACKUP_DIR/$APP_NAME.app"
fi
/bin/mv "$STAGED_APP" "$DEST_APP"
"$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
/usr/bin/pluginkit -a "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
if [[ "$WATCHER_WAS_LOADED" == 1 && -f "$WATCH_PLIST" ]]; then
  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$WATCH_PLIST"
fi

/usr/bin/open -n "$DEST_APP"
print "安装完成：$DEST_APP"
print "原应用、配置与回滚入口：$BACKUP_DIR"
