# 2.11.0 / Build 2118 本地验收与维护

本版的阶段日志、源码基线、性能原始数据、视觉样本与最终运行报告保存在维护者本机的 `analysis_results/optimization-2.11.0-build2118`，不随源码发布。2026-09-06 的最终回归记录为 163 项测试、20 个套件通过。2026-09-18 发布前重新核对，功能源码、测试和构建脚本与该验收源码归档逐文件一致；安装包 SHA-256、App/Widget 严格签名、版本、arm64 架构和七类小组件验证通过。本次复用已验收安装包，没有重新编译。所有测试使用独立本机支持目录及偏好域，正式应用只在完整验收后统一安装一次。

## 测试与构建

使用 Swift 6、macOS SDK，在本机独立工作副本运行。主项目保持 macOS 13 部署目标，Widget Xcode target 保持 macOS 14。网络卷上的编译缓存可能出现输入时间戳变动，应将源码复制到独立本机目录后编译，不能把该错误当作产品测试通过。

```sh
CODEX_PULSE_SUPPORT_DIR=/tmp/codex-pulse-check-support \
CODEX_PULSE_PREFERENCES_SUITE=dev.codex.pulse.check \
swift test -j 1 --disable-index-store --scratch-path /tmp/codex-pulse-check-build
```

设置 `CODEX_PULSE_RENDER_DIR` 为新的输出目录，会额外执行真实视图渲染，输出 42 张主应用/悬浮框样本和 46 张 Widget 样本，包含部分计价情形。主应用使用原生 NSHostingView 离屏渲染，小组件采用实际 SwiftUI 视图与明确的 WidgetFamily。最终测试数以 Swift Testing 的 `Test run with … tests` 为准，不采用 XCTest 空宿主的 `Executed 0 tests`。

测试覆盖官方读取失败、恢复与旧值保留；五分钟缓存、三十分钟停显、官方重置周期；匿名账户隔离、到期记录迁移；旧快照与 v5 日志缓存迁移；未知模型、部分计价、价格导入失败和通知去重；增量文件、新增、替换、截断、目录事件和滚动统计边界。100、1,000、10,000 个模拟会话与独立参考汇总逐项核对。

```sh
OPEN_APP=0 VERSION=2.11.0 BUILD_NUMBER=2118 \
CODEX_PULSE_SWIFT_SCRATCH_PATH=/tmp/codex-pulse-check-build \
CODEX_PULSE_WIDGET_DERIVED_DATA=/tmp/codex-pulse-check-widget \
./script/build_and_run.sh
```

`script/verify_widget_bundle.sh` 验证扩展标识、七类小组件和 App/Widget 签名。实际 Mach-O 部署版本还需用 `xcrun vtool -show-build` 核对。打包可通过 `CODEX_PULSE_DIST_DIR` 指定新目录；打包脚本拒绝覆盖已经存在的同版交付文件。

## 官方数据、价格与记录

`quotaRead`、`flexibleCreditRead`、`resetCreditsRead` 各自持有来源和读取时间。快照生成/写入时间与读取成功时间分开；Widget schema 4 的缺失新字段只表明状态待确认。雷达读取成功必须来自 Tibo 数据源的真实成功请求，五分钟重评不能延长该成功时间。

内置价格在 `Sources/CodexBalanceCore/Resources/model-prices-v1.json`。可复制该格式制作本机 JSON：`schemaVersion` 为 1，`verifiedAt` 为 ISO 8601 日期，`models` 可只提供需要更新的模型。每行包含模型名、别名、输入/缓存输入/输出单价、长上下文规则及 HTTPS 来源。`cachedInput: null` 表示官方未公布，不能用 0 代替未知价格。应用前核对差异，金额按新的价格表版本重新计算，Token 保留。

用户确认的灵活额度到期记录保存在 `credit-expiry-v1.json`，仅对相同匿名账户标识有效。旧日期仅作为待核实历史保留。请在设置中填写实际依据，再确认当前账户；没有依据时维持未确认状态。

`radar-evaluation-v1` 从本版开始记录真实产生的预测。结果标注必须给出核实来源；只有完整结束且已核实的 24 小时窗口用于 Brier score。n 为已纳入的预测数；重叠窗口不是独立实验样本，少量样本的评分只供本机对照。

## 连续运行与回滚

候选版本通过 `CODEX_PULSE_SUPPORT_DIR` 和 `CODEX_PULSE_PREFERENCES_SUITE` 隔离，记录 `runtime-acceptance.jsonl`，不记录凭据、账号名或对话内容。该记录只在隔离验收模式启用；正式应用不启用额外运行追踪。验收至少连续 60 分钟，确认两个自动雷达周期的真实成功时间，并保留 CPU/RSS、解析计数、分析次数和主线程定时器延迟。

安装包内“安装或更新（保留设置）.command”先验证签名，备份旧 App、偏好和指定本机配置，生成“恢复上一版.command”，再替换当前应用。保持原有自动启动状态，不清空桌面小组件或系统缓存。脚本支持 `--check`，只验证源包和目标路径，不执行安装。

回滚时运行本次备份目录的“恢复上一版.command”；脚本保留被回滚的新版本，恢复旧应用及配置，并重新登记本应用的小组件。源码初始基线独立保存，不依赖 App 回滚包。

验收边界：当前主机验证不能替代 macOS 13/14 各自系统上的实机测试；WidgetKit 有系统调度预算，不能保证每次请求立即上屏。Touch Bar 的显示逻辑与编译可验证，硬件观感仍需带 Touch Bar 的设备。本地发行使用 ad-hoc 签名，未进行 Developer ID 公证。
