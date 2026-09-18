# Codex 脉动 2.10.6 改版说明

## build 2113：修复桌面启动时 7 天额度空白

- 内部 Codex 进程现在会继承 macOS 当前的 HTTP/HTTPS 代理和绕过列表。
- 从 Finder、开机启动项或 LaunchServices 启动 App 时，官方 `account/rateLimits/read` 不再因缺少图形会话网络环境而读取失败。
- 已存在的环境变量优先，App 不修改 UniClash、Clash Verge、系统代理、DNS 或路由。
- 保留 build 2112 的冷启动旧快照保护：官方值尚未读到时不伪装成当前值。

## 版本信息

- 版本：2.10.6
- build：2113
- 最低系统：macOS 13
- 小组件完整支持：macOS 14 或更高版本
