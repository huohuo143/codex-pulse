# Codex 脉动 2.12.46 / build 2174（macOS）

本版在 2.12.41 基础上整合 Codex 侧栏与 OpenAI API 用量，增加手动确认的 API 赠额到期时间和提醒。

- 脉动内置 Codex 侧栏，七天额度、Tibo、Codex Credits、Full reset 和 API 用量可分别显示或隐藏。
- API 组织月消费按 UTC 自然月读取；赠额金额、余额和到期时间以实际账单为准，未知时保持待确认。API 赠额与 Codex Credits 分开显示，手动余额不会自动扣减。
- 已核对的到期时间与倒计时显示在主界面、悬浮框、侧栏及 API 小组件；可选择在到期前 3 天、1 天及到期时接收 macOS 提醒。到期后不会猜测下一周期。
- 更新时保留已有设置和账户数据。请使用包内“安装或更新”工具，该工具检查侧栏兼容等级并备份旧版；直接拖拽覆盖不经过兼容性检查。

安装包适用于 Apple Silicon，安装工具要求 macOS 14 或更高版本。应用采用 ad-hoc 签名，尚未经过 Apple 公证。首次打开可能需要在 Finder 或系统设置中确认。软件并非 OpenAI 官方发行版。

本次只提供 Mac 安装包；Windows 继续使用 [2.12.29](https://github.com/huohuo143/codex-pulse/releases/tag/v2.12.29)。真实到期通知投递和用户桌面上的 API 小组件画面尚未验证，系统调度可能造成延迟。

[安装与升级](https://github.com/huohuo143/codex-pulse/blob/v2.12.46/docs/INSTALL_UPGRADE_2.12.46.md) · [验证范围](https://github.com/huohuo143/codex-pulse/blob/v2.12.46/docs/VALIDATION_2.12.46.md)
