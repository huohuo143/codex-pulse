<p align="center">
  <img src="assets/AppIcon-1024.png" width="144" alt="Codex 脉动 Logo">
</p>

<h1 align="center">Codex 脉动</h1>

<p align="center">
  原生 macOS Codex 状态面板、悬浮框与桌面小组件
</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-2.5.2-8b7cff">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-111827">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-f05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-22c55e"></a>
</p>

`Codex 脉动` 将 Codex 的额度、Token 消耗、重置节奏和 Full reset 权益集中到一套原生 macOS 界面中。它既可以作为常驻悬浮框，也可以完全隐藏悬浮框，仅使用主窗口或 7 款桌面小组件。

> 当前版本：`2.5.2`。安装包为 Apple Silicon、ad-hoc 签名、未公证版本，要求 macOS 14 或更高版本。

## 当前版本界面

以下截图直接来自已安装的 `Codex 脉动 2.5.2`，不再使用旧版 Codex/Claude 双面板图片。

<p align="center">
  <img src="docs/screenshots/codex-pulse-overview-v2.5.2.png" width="680" alt="Codex 脉动 2.5.2 概览">
  <br>
  <sub>主面板：7 天额度、滚动 24h Token、重置雷达与 Tibo 雷达</sub>
</p>

<table>
  <tr>
    <td align="center" valign="top" width="34%">
      <img src="docs/screenshots/codex-pulse-floating-v2.5.2.png" width="236" alt="Codex 脉动 2.5.2 悬浮框">
      <br><sub>悬浮框：额度、Token、重置概率与 Full reset 权益</sub>
    </td>
    <td align="center" valign="top" width="66%">
      <img src="docs/screenshots/codex-pulse-settings-v2.5.2.png" width="520" alt="Codex 脉动 2.5.2 设置页">
      <br><sub>设置：跟随系统 / 白天 / 夜晚、悬浮框开关、信息选择与八种样式</sub>
    </td>
  </tr>
</table>

## 功能一览

| 能力 | 展示内容 |
| --- | --- |
| 官方额度 | Codex 7 天剩余额度、已用比例和重置倒计时 |
| Token 统计 | 滚动 24 小时、今日、近 7 天、本月 Token，以及 input、cached input、output 和 model |
| 重置雷达 | Codex 24h 重置概率、研判、公开摘要、更新时间和 Tibo PT 时钟 |
| Full reset | 可用次数、获得时间和逐次到期日，只读展示，不提供消耗操作 |
| 用量分析 | 最近 14 天趋势、设备对比、项目 Top、13 类工作用途、最近调用和 CSV 导出 |
| 金额估算 | 按 OpenAI 官方模型价格估算 API 等价金额，并通过 Frankfurter 换算 USD/CNY |
| 显示载体 | 主窗口、可配置悬浮框、Touch Bar、7 款 WidgetKit 桌面小组件 |
| 外观 | 极光、玻璃、石墨三套视觉方案，六套主题色，以及跟随系统、白天、夜晚背景模式 |

金额是 API 等价预估，不是 ChatGPT/Codex 订阅账单。reasoning token 已包含在 output 中，不重复计费。

## 三种使用形态

### 1. 完整主面板

主窗口分为“概览、趋势、分析、设置”四个区域：

- 概览：额度、Token 汇总、重置雷达、Full reset 权益和最近额度事件。
- 趋势：最近 14 天用量、日/月视图和多设备对比。
- 分析：缓存输入占比、项目排行、工作类型构成和最近调用。
- 设置：刷新频率、悬浮框、主题、背景模式、Touch Bar、桌面小组件说明和致谢。

### 2. 可选择的悬浮框

悬浮框不是必选项。在“设置 → 悬浮框”中可以：

- 开启或关闭悬浮框总开关；关闭后，小组件和普通主窗口仍可继续使用。
- 分别选择是否显示 7 天额度、滚动 24h Token、重置雷达和 Full reset 权益。
- 在“额度环、圆形、方形、胶囊、横条、横条·详细、徽章、徽章·详细”八种样式间切换。
- 选择额度环横向或竖向排列；样式会随所选信息自动调整尺寸。

由 Codex 自动唤起时，如果悬浮框已关闭，App 会静默在后台更新数据；手动打开 App 时仍会显示普通主窗口。

### 3. 七款桌面小组件

| 小组件 | 尺寸 | 主要信息 |
| --- | --- | --- |
| Codex 算力总览 | 中、大 | 7 天额度、滚动 24h、重置概率、Full reset；大号增加 Token 汇总、费用和趋势 |
| 7 天额度 | 小、中 | 剩余额度环、已用比例和重置倒计时 |
| Codex 重置雷达 | 小、中 | 24h 重置概率、研判、公开摘要和更新时间 |
| Full reset 权益 | 小、中 | 可用次数和最多 3 次到期时间 |
| Token 汇总 | 小、中 | 滚动 24h、今日、近 7 天、本月 Token 和金额预估 |
| Token 趋势 | 中、大 | 24 小时逐时柱状图；大号增加最近 14 天趋势 |
| 项目与用途 | 中、大 | 今日项目 Top 3 和本月用途 Top 3 |

安装并打开一次 App 后，在桌面空白处右键，选择“编辑小组件”，搜索“Codex 脉动”即可添加。更多说明见 [桌面小组件指南](docs/WIDGETS.md)。

## 白天与夜晚背景

App 提供三种背景模式：

- 跟随系统：随 macOS 外观自动切换。
- 白天：手动固定为浅色背景。
- 夜晚：手动固定为深色背景。

主窗口、设置页和八种悬浮样式共享这一设置；桌面小组件随系统外观自动适配。

## 数据来源与工作方式

```mermaid
flowchart LR
  A["~/.codex/sessions 本地日志"] --> E["本地聚合与缓存"]
  B["Codex 账户只读状态"] --> E
  C["Codex 重置雷达公开源"] --> E
  D["Frankfurter 汇率"] --> E
  E --> F["主窗口"]
  E --> G["悬浮框 / Touch Bar"]
  E --> H["脱敏 Widget 快照"]
  H --> I["7 款桌面小组件"]
```

- 本地用量从 `~/.codex/sessions` 增量读取，聚合 input、cached input、output、model、项目和工作类型。
- Codex 额度和 Full reset 权益通过只读方式获取；Full reset 不提供兑换或消耗入口。
- 重置雷达读取小程序实际使用的公开 `/radar-api/dashboard` 数据，无需 API Key，每 30 分钟自动同步。
- USD/CNY 汇率来自 Frankfurter；网络失败时使用上次成功缓存。
- iCloud 仅同步小时、日、月聚合 Token 与模型名，使用 schema 4 的 `设备-codex-v2.json`。

## 隐私边界

- Codex 会话日志只在本机只读解析，不上传原始消息。
- Full reset 凭据和原始响应只在内存中短暂使用；缓存不保存 token、完整账户 ID、后台权益 ID 或原始响应。
- Widget 快照只包含额度、公开雷达、权益到期时间和聚合 Token，不包含会话内容、项目路径、账户凭据、API Key 或兑换 ID。
- 重置雷达公开数据采用 30 分钟内存缓存，不写入 iCloud。
- 会话解析缓存位于独立 Application Support 目录，只保存增量聚合所需结果。

## 安装

在 [Releases](https://github.com/huohuo143/codex-pulse/releases) 下载：

```text
Codex-Pulse-v2.5.2-20260716-arm64.dmg
Codex-Pulse-v2.5.2-20260716-arm64.dmg.sha256
```

1. 打开 DMG。
2. 将 `Codex 脉动.app` 拖入 Applications；也可以运行 DMG 内的“安装并启用自动启动”脚本。
3. 首次打开若被 Gatekeeper 拦截，在“系统设置 → 隐私与安全性”中选择“仍要打开”。
4. 打开一次 App，等待首次历史数据解析完成。

首次运行需要建立历史解析缓存；日志较多时可能持续约 1 分钟。缓存建立后只会恢复历史结果并增量读取新增字节。

## 与旧版并行

| 项目 | Codex 脉动 2.5.2 | 旧算力码表 0.1.0 |
| --- | --- | --- |
| App | `Codex 脉动.app` | `算力码表.app` |
| Bundle ID | `dev.codex.balance-dashboard.codex` | `dev.codex.balance-dashboard` |
| 进程 | `CodexSuanliMeter` | `CodexBalance` |
| Application Support | `CodexSuanliMeter` | `CodexBalanceDashboard` |
| LaunchAgent | `dev.codex.balance-dashboard.codex.watch-codex` | `dev.codex.balance-dashboard.watch-codex` |

新版不会覆盖、删除或终止旧版。

卸载新版时，只删除新版路径：

```text
~/Applications/Codex 脉动.app
~/Library/LaunchAgents/dev.codex.balance-dashboard.codex.watch-codex.plist
~/Library/Application Support/CodexSuanliMeter/
```

## 从源码构建

### 环境要求

- macOS 14+
- Apple Silicon Mac
- Swift 6 / Xcode Command Line Tools
- 完整 Xcode，用于构建原生 Widget App Extension

### 构建与测试

```bash
./script/generate_app_icon.sh
swift test --parallel
OPEN_APP=0 ./script/build_and_run.sh
./script/verify_widget_bundle.sh
./script/package_release.sh
```

主程序由 SwiftPM 构建；Widget 扩展由 `xcode/CodexPulseWidgets.xcodeproj` 的原生 App Extension target 构建，以满足 WidgetKit 生命周期要求。

主要目录：

| 路径 | 内容 |
| --- | --- |
| `Sources/CodexBalance` | App 生命周期、状态管理、主窗口、悬浮框和设置界面 |
| `Sources/CodexBalanceCore` | Codex 状态读取、Token 聚合、雷达、汇率、权益和 Widget 快照 |
| `Sources/CodexSuanliWidgets` | 7 款 WidgetKit 组件 |
| `Tests/CodexBalanceCoreTests` | 核心逻辑测试 |
| `script` | 图标生成、构建、验证、打包与迁移脚本 |
| `config` / `xcode` | Widget 扩展配置、entitlements 和 Xcode target |

## 已知边界

- 当前 DMG 仅支持 arm64，采用 ad-hoc 签名且尚未公证。
- 本地 Token 统计来自 Codex 会话日志，不包含无法在本机日志中观察到的网页端用量。
- 未知模型不会猜测价格，而会保持“未计价”。
- WidgetKit 的实际刷新时刻仍受 macOS 桌面小组件预算控制。
- Full reset 和重置雷达均为只读信息，概率与研判仅供参考。

## 版本说明

2.5.2 新增桌面小组件、悬浮框总开关与信息选择、昼夜背景模式和全新 Logo，并修复 WidgetKit 无法识别扩展入口的问题。完整内容见 [2.5.2 改版说明](docs/RELEASE_2.5.2.md)。

## 致谢

- 最初源码与构思：[waytosea-oss/suanli-dashboard](https://github.com/waytosea-oss/suanli-dashboard)。
- Codex 重置雷达：感谢 [Codex 雷达](https://codexradar.com/) 提供公开数据；官网公开署名为 `designed by Codex`，未公开个人作者姓名。

感谢上述作者与公开项目为 Codex 脉动提供起点、思路与公开雷达数据。

## License

本项目采用 [MIT License](LICENSE)。
