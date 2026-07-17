# Codex 脉动 2.8.0 改版说明

## 第三优先级：可靠性与自动化

- 新增“可靠性与自动化中心”，集中展示官方额度、Token 完整汇总、重置雷达、额度历史、项目预算、Widget 快照和自动启动守护的健康状态。
- 定时巡检默认开启，可选 15、30 或 60 分钟间隔。
- 可靠性事件最多保留 500 条，记录状态变化、恢复、备份和归档结果。

## 受控自动恢复

- 当额度、Token 汇总、重置雷达或 Widget 快照严重过期时，只触发重新读取、重新汇总或刷新快照。
- 恢复冷却为 15 分钟，每轮最多尝试 2 次，避免循环刷新。
- 自动恢复不删除、移动或修改 Codex 源会话日志。

## 本地自动化

- 每日备份 `quota-history-v1.json` 和 `project-budgets-v1.json`，仅保留最近 7 天。
- 可选每日聚合摘要，默认关闭；可设置 0–23 时的归档时间。
- 备份和摘要位于 `~/Library/Application Support/CodexSuanliMeter/automation/`。
- 可一键导出脱敏 Markdown 诊断报告，用于排查过期、损坏和同步问题。

## 隐私与兼容

- 诊断报告不包含账号、对话、项目路径、凭据或 API Key。
- 所有可靠性与自动化数据均保存在本机，不上传、不写入 iCloud 或 Widget 快照。
- Widget schema、iCloud 设备同步 schema、额度预测和项目预算 schema 均未改变。

## 交付

- 系统要求：macOS 14+。
- 架构：Apple Silicon arm64。
- 签名：ad-hoc；未公证。

```text
Codex-Pulse-v2.8.0-20260717-arm64.dmg
Codex-Pulse-v2.8.0-20260717-arm64.dmg.sha256
```
