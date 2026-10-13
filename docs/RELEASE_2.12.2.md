Codex 脉动 2.12.2 · Build 2128

macOS 与 Windows 同步更新，重点改善预算保存、提醒记录、刷新反馈和中文项目显示。

- 预算仅接受正整数，支持英文千位逗号；保存失败时保留输入，后台刷新不会覆盖草稿，删除使用独立入口。
- 提醒回执晚于账户切换时仍记入原账户，减少重复提醒和旧状态覆盖。
- 操作结果与刷新进度分别显示；失败后可重试，恢复成功后清除对应旧错误。
- file URL 中的中文项目名显示更清晰，原始项目标识和预算关联保持不变。
- Windows 补齐按文件校验的每日备份、同日增补及日志路径增量索引，并保留上一版圆环文字布局修复。
- Mac 自动守护采用随进程释放的系统文件锁，改善异常退出后的恢复；未开启守护的用户不会被自动开启。

本次提供 Apple Silicon（arm64）Mac DMG，以及 Windows x64 的 `Installer.exe` 安装版和 `Portable.exe` 免安装版。GitHub 附件采用英文文件名，程序内容与本机构建的中文文件名版本一致。优先使用 Mac 包内“安装或更新（保留设置）.command”或 Windows 安装版升级。安装要求、设置保留与回退方法见随附 INSTALL_UPGRADE_2.12.2.md；验证范围与未测项目见 VALIDATION_2.12.2.md。

Mac 安装包为 ad-hoc 签名、未公证版本；Windows 安装包没有商业 Authenticode 签名。Mac DMG 内“本地版本；未发布到 GitHub”是构建时保存的说明快照，本次发布状态以此 Release 页面为准。

下载与后续更新：https://github.com/huohuo143/codex-pulse/releases
