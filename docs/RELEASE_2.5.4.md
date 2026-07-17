# Codex 脉动 2.5.4 改版说明

## 署名修正

- “设置 → 关于”中的“开发维护”署名由旧值更正为 `ZhangS`。
- “最初源码与构思”继续在致谢区单独标注为 `waytosea-oss`，明确区分当前维护者和原项目作者。
- 项目许可证继续显示为 MIT。

## 功能延续

- 保留 2.5.3 的最近 24 小时即时悬停气泡、M/亿紧凑读数和精确 Token 整数。
- Token 统计、额度解析、重置雷达、Full reset、Widget 和同步数据口径均未改变。

## 安装边界

- 系统要求：macOS 14 或更高版本。
- 架构：Apple Silicon arm64。
- 签名：ad-hoc。
- 公证：未公证，首次打开可能出现 Gatekeeper 提示。
- 打包过程不会覆盖已安装版本；只有用户主动运行 DMG 内安装脚本时才会替换同名 App。

安装包：

```text
Codex-Pulse-v2.5.4-20260716-arm64.dmg
Codex-Pulse-v2.5.4-20260716-arm64.dmg.sha256
```
