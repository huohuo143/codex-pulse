#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$PACKAGE_DIR/Codex 脉动.app"
INSTALLER="$PACKAGE_DIR/支持文件/保留设置安装器.command"
OLD_UNINSTALLER="$PACKAGE_DIR/支持文件/移除旧侧栏.command"

[[ -d "$SOURCE_APP" && -f "$INSTALLER" && -f "$OLD_UNINSTALLER" ]] || {
  echo "分享包不完整，请先完整解压。" >&2; exit 1;
}
[[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == 1 ]] || {
  echo "此分享包适用于 Apple Silicon Mac（M 系列芯片）。" >&2; exit 1;
}
major_version="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"
[[ "$major_version" =~ ^[0-9]+$ && "$major_version" -ge 14 ]] || {
  echo "使用当前 Codex 桌面版需要 macOS 14 或更高版本。" >&2; exit 1;
}
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
source_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
[[ "$source_build" =~ ^[0-9]+$ ]] || { echo "无法核对分享包版本。" >&2; exit 1; }
for installed in "$HOME/Applications/Codex 脉动.app" "/Applications/Codex 脉动.app"; do
  if [[ -d "$installed" ]]; then
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist" 2>/dev/null || true)"
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$app_id" == "dev.codex.balance-dashboard.codex" && "$build" =~ ^[0-9]+$ ]] || {
      echo "已有同名应用的标识或版本无法核对，未安装。" >&2; exit 1;
    }
    (( 10#$build <= 10#$source_build )) || {
      echo "检测到更新的脉动版本，未覆盖。" >&2; exit 1;
    }
  fi
done
export CODEX_PULSE_INSTALL_SOURCE="$SOURCE_APP"
if [[ "${1:-}" == "--check" ]]; then
  exec /bin/zsh "$INSTALLER" --check
fi
[[ $# == 0 ]] || { echo "支持的参数：--check" >&2; exit 2; }
echo "将安装或更新 Codex 脉动，保留已有设置和额度历史，并备份旧版。"
echo "若存在可识别的旧侧栏 App，会在安装成功后连同它的启动项移入废纸篓。"
read -r -p "输入 y 后按回车继续，其他输入取消：" reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "已取消。"; exit 0; }
/bin/zsh "$INSTALLER"
if [[ -e "$HOME/Applications/Codex 侧栏状态.app" || -e "$HOME/Library/LaunchAgents/local.codexpulse.sidebar-status.plist" ]]; then
  if ! printf 'y\n' | /bin/bash "$OLD_UNINSTALLER"; then
    echo "脉动已安装，但旧侧栏未能自动移除；请检查旧侧栏 App 和启动项。" >&2
    exit 1
  fi
fi
echo "完成。打开脉动的“设置 → Codex 侧栏状态”可调整五项显示。"
echo "如需自动启动，在设置中开启“打开 Codex 时自动启动”。"
