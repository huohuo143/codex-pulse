# Codex 脉动 2.7.0 改版说明

## 第二优先级：高级分析

- “分析”页新增近 7 天与前 7 天同期对比、近 7 天日均 Token 及月末消耗推演。
- 新增 cached input 复用率、输出/输入比、平均每次调用 Token、主要模型占比和项目集中度。
- 使用 median + MAD 稳健基线识别近 7 天异常高峰，降低单个极端日对阈值的干扰。
- 新增规则化诊断，区分消耗上升、节奏平稳、缓存效率、模型/项目集中和预算风险。

## 项目预算

- 可从本月已识别项目中选择项目，设置每月 Token 上限。
- 展示已用 Token、预算进度、剩余 Token、按当前月进度推演的月末消耗。
- 风险分为“预算健康”“预计超支”“已超预算”和“暂无用量”。
- 预算保存在 `~/Library/Application Support/CodexSuanliMeter/project-budgets-v1.json`。

## 边界与隐私

- 项目预算是用户自定义的本地管理目标，不代表 OpenAI 官方配额或账单。
- 高级分析只使用本机已聚合的 Token、模型、项目和分类结果，不读取或上传对话正文。
- 本版不改变 Widget schema、iCloud 设备同步 schema、额度预测或提醒决策。
- 统计仅覆盖本机 Codex 日志中可观察的用量；月末推演会随后续任务强度变化。

## 交付

- 系统要求：macOS 14+。
- 架构：Apple Silicon arm64。
- 签名：ad-hoc；未公证。

```text
Codex-Pulse-v2.7.0-20260717-arm64.dmg
Codex-Pulse-v2.7.0-20260717-arm64.dmg.sha256
```
