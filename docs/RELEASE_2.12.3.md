# Codex 脉动 2.12.3 · Build 2129

Mac 与 Windows 同步改善检查更新的可靠性。

- 首选本项目公开版本清单，GitHub API 作为备用，减少共享网络下的 API 限流影响。
- 遇到限流按服务器恢复时间等待，冷却状态在重启后保留，连续点击不会重复请求。
- 网络失败保留上次成功结果和发布页入口；成功后清除旧错误。
- 失败采用逐步延长的重试间隔，成功检查后 24 小时内不自动重复。
- Windows 明确优先选择 Installer/Setup 安装版，提供独立 Portable 免安装版。

安装包：Apple Silicon Mac DMG，以及 Windows x64 Installer 和 Portable。源码、安装说明和 SHA-256 校验文件一并提供。更新检查不要求用户提供 GitHub Token。
