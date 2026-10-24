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

# BEGIN WATCHER_RECOVERY
# Keep this self-contained: the same functions are embedded in the rollback.
watcher_launchctl() { /bin/launchctl "$@"; }
watcher_retry_delay() { /bin/sleep "$1"; }
stop_watcher() {
  local target="$1" attempt code
  watcher_launchctl bootout "$target" || true
  # bootout returns before a foreground sleep/trap has finished. Do not let a
  # still-registered, SIGTERMed job count as a restored service below.
  for attempt in {1..21}; do
    if watcher_launchctl print "$target" >/dev/null 2>&1; then
      code=0
    else
      code=$?
    fi
    if [[ "$code" == 113 ]]; then return 0; fi
    if [[ "$code" != 0 ]]; then break; fi
    if (( attempt < 21 )); then watcher_retry_delay 0.5; fi
  done
  print -u2 "自动启动服务仍未退出，本次操作已停止，请稍后重试。"
  return 1
}
restore_watcher() {
  local domain="$1" label="$2" plist="$3" attempt
  if watcher_launchctl print "$domain/$label" >/dev/null 2>&1; then return 0; fi
  for attempt in 1 2 3; do
    # bootstrap can report error 5 while the previous job finishes bootout.
    # Its exit status alone is not proof that the service is registered.
    watcher_launchctl bootstrap "$domain" "$plist" || true
    if watcher_launchctl print "$domain/$label" >/dev/null 2>&1; then return 0; fi
    if (( attempt < 3 )); then watcher_retry_delay 1; fi
  done
  print -u2 "自动启动服务尚未恢复，已尝试 3 次。可在应用设置中重新开启自动启动。"
  return 1
}
# END WATCHER_RECOVERY

# BEGIN APP_QUIESCENCE
# Serialized into rollback as well. Inspect mapped images: ps can retain the
# original pathname after an updater moves the running bundle to a backup.
app_delay() { /bin/sleep "$1"; }
app_signal() { /bin/kill -TERM "$1" 2>/dev/null || true; }
app_candidates() {
  /usr/bin/pgrep -U "$(/usr/bin/id -u)" -x CodexSuanliMeter || true
  /usr/bin/pgrep -U "$(/usr/bin/id -u)" -x CodexSuanliWidgets || true
}
app_image() {
  local pid="$1" line
  while IFS= read -r line; do
    case "$line" in
      n*/Contents/MacOS/CodexSuanliMeter|n*/Contents/PlugIns/CodexSuanliWidgets.appex/Contents/MacOS/CodexSuanliWidgets)
        print -r -- "${line#n}"; return 0 ;;
    esac
  done <<< "$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null || true)"
  # An exited candidate is normal; an alive uninspectable process is not safe
  # to replace underneath. Do not guess its identity or kill it by name.
  if /bin/kill -0 "$pid" 2>/dev/null; then
    [[ "$(/bin/ps -p "$pid" -o stat= 2>/dev/null)" == Z* ]] && return 1
    return 2
  fi
  return 1
}
app_processes() {
  local pid image bundle identifier code
  for pid in $(app_candidates); do
    if image="$(app_image "$pid")"; then
      bundle="${image%%/Contents/*}"
      identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null)" || return 2
      [[ "$identifier" == dev.codex.balance-dashboard.codex ]] && print "$pid"
    else
      code=$?
      [[ "$code" == 1 ]] || return "$code"
    fi
  done
  return 0
}
quiesce_app() {
  local attempt pids pid
  local -A signalled
  for attempt in {1..41}; do
    pids="$(app_processes)" || { print -u2 '无法核对旧应用进程，已停止替换。'; return 1; }
    [[ -z "$pids" ]] && return 0
    for pid in ${=pids}; do
      if [[ -z "${signalled[$pid]:-}" ]]; then
        app_signal "$pid"
        signalled[$pid]=1
      fi
    done
    (( attempt < 41 )) && app_delay 0.25
  done
  print -u2 '旧应用或小组件仍未退出，已停止替换；请退出应用后重试。'
  return 1
}
verify_running_app() {
  local attempt pids pid image main
  for attempt in {1..21}; do
    main=0
    pids="$(app_processes)" || return 1
    for pid in ${=pids}; do
      image="$(app_image "$pid")" || continue
      [[ "$image" == "$DEST_APP/Contents/"* ]] || { print -u2 '检测到旧路径进程，升级验证失败。'; return 1; }
      [[ "$image" == "$DEST_APP/Contents/MacOS/CodexSuanliMeter" ]] && main=1
    done
    [[ "$main" == 1 ]] && return 0
    app_delay 0.5
  done
  print -u2 '新应用未成功运行，升级验证未通过。'
  return 1
}
recover_install_failure() {
  # EXIT trap restores service/registration on a refused shutdown or failed move.
  local result="$?"
  if (( result != 0 )); then
    if [[ ! -d "$DEST_APP" && -d "${PREVIOUS_APP:-/nonexistent}" ]]; then
      /usr/bin/ditto "$PREVIOUS_APP" "$DEST_APP" || true
    fi
    if [[ -d "$DEST_APP" ]]; then
      "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
      [[ ! -d "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" ]] || /usr/bin/pluginkit -a "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
    fi
    if [[ "${WATCHER_WAS_LOADED:-0}" == 1 ]]; then
      restore_watcher "gui/$(/usr/bin/id -u)" "$LABEL" "$WATCH_PLIST" || true
    fi
    print -u2 "本次操作未通过完整验证；备份与恢复入口：$BACKUP_DIR"
  fi
  return "$result"
}

# A successful registration does not prove WidgetKit accepted a timeline.
# Keep missing (possibly unconfigured) kinds explicitly unverified.
report_widget_refresh() {
  local kind events last report="$BACKUP_DIR/widget-refresh.log"
  /bin/sleep 5
  if ! /usr/bin/log show --start "$WIDGET_CHECK_START" --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "dev.codex.balance-dashboard.codex" AND eventMessage CONTAINS "on local reload:"' > "$report" 2>/dev/null; then
    print '小组件刷新记录不可读取，实际显示尚未验证。'
    return 0
  fi
  for kind in quota reset-credits token-summary token-trend workload radar overview; do
    events="$(/usr/bin/grep -F "codex.$kind:" "$report" || true)"
    last="$(print -r -- "$events" | /usr/bin/tail -1)"
    if [[ "$last" == *'on local reload: succeeded'* ]]; then
      print "小组件 $kind：系统已接受新内容。"
    elif [[ -n "$last" ]]; then
      print "小组件 $kind：刷新失败，请检查 $report"
    else
      print "小组件 $kind：未收到刷新记录（可能未添加），尚未验证。"
    fi
  done
  print '通知中心与桌面的实际画面仍需核对；上述结果不等同于画面验收。'
}
# END APP_QUIESCENCE

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
for item in "$SUPPORT_DIR"/quota-history*.json "$SUPPORT_DIR"/project-budgets-v1*.json \
  "$SUPPORT_DIR"/credit-expiry-v1.json "$SUPPORT_DIR"/credit-expiry-v2.json \
  "$SUPPORT_DIR"/credit-expiry-v2.previous.json "$SUPPORT_DIR"/credit-expiry-v2.damaged-*.json "$SUPPORT_DIR"/model-prices*.json \
  "$SUPPORT_DIR"/radar-evaluation-v1 "$SUPPORT_DIR"/codex-radar-tibo-history.json "$SUPPORT_DIR"/codex-reset-calendar-v1.json \
  "$SUPPORT_DIR"/reliability-events-v1.json "$SUPPORT_DIR"/account-scope-salt.txt \
  "$SUPPORT_DIR"/widget-snapshot.json "$SUPPORT_DIR"/live-balance.json \
  "$SUPPORT_DIR"/session-event-cache-v*.plist "$SUPPORT_DIR"/watch-codex.sh; do
  [[ -e "$item" ]] && /usr/bin/ditto "$item" "$BACKUP_DIR/config/${item:t}"
done
[[ -f "$WATCH_PLIST" ]] && /usr/bin/ditto "$WATCH_PLIST" "$BACKUP_DIR/watch-agent.plist"
cat > "$BACKUP_DIR/恢复上一版.command" <<'ROLLBACK_HEADER'
#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB
ROLLBACK_HEADER
typeset -f watcher_launchctl watcher_retry_delay stop_watcher restore_watcher app_delay app_signal app_candidates app_image app_processes quiesce_app verify_running_app recover_install_failure report_widget_refresh >> "$BACKUP_DIR/恢复上一版.command"
cat >> "$BACKUP_DIR/恢复上一版.command" <<'ROLLBACK'
BACKUP_DIR="${0:A:h}"
DEST_APP="$HOME/Applications/Codex 脉动.app"
SUPPORT_DIR="$HOME/Library/Application Support/CodexSuanliMeter"
LABEL="dev.codex.balance-dashboard.codex.watch-codex"
WATCH_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -d "$BACKUP_DIR/Codex 脉动.app" ]] || { print -u2 "没有上一版应用可恢复"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$BACKUP_DIR/Codex 脉动.app"
WIDGET_CHECK_START="$(/bin/date +'%Y-%m-%d %H:%M:%S')"
WATCHER_WAS_LOADED=0
trap recover_install_failure EXIT
if /bin/launchctl print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
  WATCHER_WAS_LOADED=1
  stop_watcher "gui/$(/usr/bin/id -u)/$LABEL" || exit 1
fi
# Unregister before stopping to reduce extension relaunches during replacement.
/usr/bin/pluginkit -r "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
quiesce_app || exit 1
/usr/bin/pluginkit -r "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
PREVIOUS_APP="$BACKUP_DIR/回滚时保留的新版本-$(/bin/date +%Y%m%d-%H%M%S).app"
[[ -d "$DEST_APP" ]] && /bin/mv "$DEST_APP" "$PREVIOUS_APP"
/usr/bin/ditto "$BACKUP_DIR/Codex 脉动.app" "$DEST_APP"
quiesce_app || exit 1
for item in "$BACKUP_DIR/config/"*; do /usr/bin/ditto "$item" "$SUPPORT_DIR/${item:t}"; done
[[ -f "$BACKUP_DIR/preferences.plist" ]] && /usr/bin/defaults import dev.codex.balance-dashboard.codex "$BACKUP_DIR/preferences.plist"
"$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1
if [[ -d "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" ]]; then
  /usr/bin/pluginkit -a "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1
fi
WATCHER_RESTORE_FAILED=0
if [[ "$WATCHER_WAS_LOADED" == 1 ]]; then
  restore_watcher "gui/$(/usr/bin/id -u)" "$LABEL" "$WATCH_PLIST" || WATCHER_RESTORE_FAILED=1
fi
/usr/bin/open -n "$DEST_APP"
verify_running_app || exit 1
if [[ "$WATCHER_RESTORE_FAILED" == 1 ]]; then
  print -u2 "上一版应用已恢复并启动，但自动启动服务需要重试。备份仍在 $BACKUP_DIR"
  exit 1
fi
report_widget_refresh
print "已恢复上一版；回滚前的新版本也已保留在 $BACKUP_DIR"
ROLLBACK
chmod +x "$BACKUP_DIR/恢复上一版.command"
PREVIOUS_APP="$BACKUP_DIR/$APP_NAME.app"
STAGED_APP="$DEST_DIR/.Codex-pulse-install-$STAMP.app"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
WIDGET_CHECK_START="$(/bin/date +'%Y-%m-%d %H:%M:%S')"
WATCHER_WAS_LOADED=0
trap recover_install_failure EXIT
if /bin/launchctl print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
  WATCHER_WAS_LOADED=1
  stop_watcher "gui/$(/usr/bin/id -u)/$LABEL" || exit 1
fi
# Stop verified copies of this product, including retained/preview bundles.
# Unregister before stopping to reduce extension relaunches during replacement.
/usr/bin/pluginkit -r "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
quiesce_app || exit 1
if [[ -d "$DEST_APP" ]]; then
  /usr/bin/pluginkit -r "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$DEST_APP" >/dev/null 2>&1 || true
  /bin/mv "$DEST_APP" "$BACKUP_DIR/$APP_NAME.app"
fi
/bin/mv "$STAGED_APP" "$DEST_APP"
# Catch a system relaunch that raced the pre-replacement shutdown.
quiesce_app || exit 1
"$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1
if [[ -d "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" ]]; then
  /usr/bin/pluginkit -a "$DEST_APP/Contents/PlugIns/CodexSuanliWidgets.appex" >/dev/null 2>&1
fi
# BEGIN WATCHER_RESTORE_AND_OPEN
WATCHER_RESTORE_FAILED=0
if [[ "$WATCHER_WAS_LOADED" == 1 ]]; then
  restore_watcher "gui/$(/usr/bin/id -u)" "$LABEL" "$WATCH_PLIST" || WATCHER_RESTORE_FAILED=1
fi

/usr/bin/open -n "$DEST_APP"
verify_running_app || exit 1
if [[ "$WATCHER_RESTORE_FAILED" == 1 ]]; then
  print -u2 "应用已更新并启动，但自动启动服务需要重试。原应用、配置与回滚入口：$BACKUP_DIR"
  exit 1
fi
report_widget_refresh
print "安装完成：$DEST_APP"
print "原应用、配置与回滚入口：$BACKUP_DIR"
# END WATCHER_RESTORE_AND_OPEN
