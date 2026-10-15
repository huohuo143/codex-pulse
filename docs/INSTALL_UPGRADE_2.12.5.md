# Codex 脉动 2.12.5 安装与升级

本次提供 Apple Silicon（arm64）Mac 安装包，主应用要求 macOS 13+，桌面小组件要求 macOS 14+。Windows 公开安装包继续从 [v2.12.2](https://github.com/huohuo143/codex-pulse/releases/tag/v2.12.2) 下载。

1. 下载 `Codex-Pulse-v2.12.5-build2131-20261015-arm64.dmg` 及对应 `.sha256` 校验文件。
2. 打开 DMG，运行“安装或更新（保留设置）.command”。应用安装到 `~/Applications/Codex 脉动.app`。
3. 安装器保留旧应用、偏好、额度记录和现有自动启动配置，在 `~/Library/Application Support/CodexSuanliMeter/version-backups/` 创建备份和“恢复上一版.command”。
4. 打开应用，确认主窗口显示 `v2.12.5`，等待首次历史用量统计完成。

本包采用 ad-hoc 签名，尚未公证；首次运行可能受到 macOS Gatekeeper 拦截。请根据系统的“隐私与安全性”提示自行决定是否允许打开。

## 现有自动启动服务的登记问题

本机升级时曾在恢复原有服务时返回 `Bootstrap failed: 5: Input/output error`。当时应用已经正确替换、旧版与配置备份也已完成，但安装命令没有正常结束。检查服务尚未登记后，重新登记同一份原有 plist 成功，应用与守护服务正常运行。

遇到该提示时先确认已安装版本，保留安装日志和备份。可先从 `~/Applications` 打开应用；若需要恢复原有自动启动服务，可在终端执行：

```sh
label=dev.codex.balance-dashboard.codex.watch-codex
if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$label.plist"
fi
```

仅适用于原先已存在该 plist 的安装。请勿为此删除额度记录、重置偏好或新建另一套自动启动服务。

## 回退

退出应用后，运行此次安装备份目录中的“恢复上一版.command”。回退会恢复备份时的应用与配置，同时保留回退前的新应用。回退入口已做语法检查，本次未实际执行回退。
