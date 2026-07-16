# Codex 脉动 macOS 桌面小组件

`Codex 脉动 2.5.2` 将悬浮框与主面板中的核心信息拆成 7 款 WidgetKit 小组件。所有组件读取主 App 原子写入的同一份聚合快照，数据口径与悬浮框一致，并随 macOS 白天/夜晚外观自动适配背景。

## 组件组

| 小组件 | 支持尺寸 | 主要信息 |
| --- | --- | --- |
| Codex 算力总览 | 中、大 | 7 天额度、滚动 24h、重置概率、Full reset；大尺寸增加 Token 汇总、费用和 24h 趋势 |
| 7 天额度 | 小、中 | 剩余额度环、已用比例、重置倒计时 |
| Codex 重置雷达 | 小、中 | 24h 重置概率、研判级别、公开摘要与更新时间 |
| Full reset 权益 | 小、中 | 可用次数和最多 3 次到期时间，只读展示 |
| Token 汇总 | 小、中 | 滚动 24h、今日、近 7 天、本月 Token 与 API 等价预估 |
| Token 趋势 | 中、大 | 24 小时逐时柱状图；大尺寸增加最近 14 天趋势 |
| 项目与用途 | 中、大 | 今日项目 Top 3、本月用途 Top 3 |

## 推荐组合

- 信息完整：中号“Codex 算力总览” + 中号“Token 趋势”。
- 重置关注：小号“Codex 重置雷达” + 小号“Full reset 权益”。
- 极简桌面：仅保留小号“7 天额度”。

## 与悬浮框的关系

- “设置 → 悬浮框 → 启用悬浮框”可以随时关闭或恢复悬浮框；关闭后由 Codex 自动唤起时 App 静默后台运行，手动打开时仍显示普通主窗口，已添加的桌面小组件继续保留。
- 悬浮框中的 7 天额度、滚动 24h Token、重置雷达与 Full reset 权益可以分别勾选，至少保留一项。
- 桌面小组件和悬浮框共享同一数据口径，但显示开关相互独立：隐藏悬浮框信息不会删除或隐藏对应桌面小组件。

## 数据与刷新

- 主 App 继续按设置的 5/10/30 秒频率读取本地额度；完整 Token 汇总按现有 5 分钟节流执行。
- 重置雷达继续独立按 30 分钟同步公开源。
- 成功刷新后同时保留主 App 快照，并原子写入 Widget 扩展自身容器中的 `widget-snapshot.json`。
- 主 App 最多每分钟通知 WidgetKit 重载一次；系统仍会按桌面组件预算决定实际刷新时刻。
- 主 App 未运行时，WidgetKit 每 15 分钟尝试读取一次快照。

## 隐私与沙盒

快照不包含会话内容、源文件路径、项目路径、账户凭据、API Key、完整账户 ID 或 Full reset 兑换 ID。Widget 扩展只启用标准 App Sandbox，不申请临时跨容器权限；主 App 负责将脱敏快照发布到扩展自己的容器。若后续改为 Developer ID 或 Mac App Store 分发，可迁移到正式 App Group container。

## 添加方法

1. 安装并打开一次“Codex 脉动”，等待面板出现数据。
2. 在 macOS 桌面空白处右键，选择“编辑小组件”。
3. 搜索“Codex 脉动”。
4. 选择所需组件与尺寸。

## 构建结构

- 主程序：`CodexSuanliMeter`
- Widget 扩展：`CodexSuanliWidgets`
- Widget 构建目标：`xcode/CodexPulseWidgets.xcodeproj`（原生 App Extension 生命周期）
- 扩展位置：`Codex 脉动.app/Contents/PlugIns/CodexSuanliWidgets.appex`
- 扩展标识：`dev.codex.balance-dashboard.codex.widgets`
