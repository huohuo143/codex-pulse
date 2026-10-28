# 小悟 S3 双屏众创候选版

版本：0.1.0。当前交付为本地候选版，线上沙箱联调等待平台分配测试设备和模板。

## 功能

在设置中新增“小悟 S3 双屏沙箱”，与原小悟云个人看板接入分别配置。A 屏显示额度、24h Token、Full reset 和周期重置；B 屏显示重置状态、展示剩余时间和七日趋势。文字不小于 18px，不使用动画或大面积反色。B 屏可切换纯黑白降级。

布局提供 400×300、648×480、800×480 等像素尺寸的本地渲染，宽度范围 400–1600、高度 300–1200；预设不能替代真实机型规格。PNG 精确输出目标尺寸、无透明通道，仅使用黑白或黑白红；同一几何数据输出可编辑 SVG 与布局 JSON。

本版本只构造和推送明确标注的示例数据，没有真实账号数据同步开关。导出资料不带凭据、账号、真实设备 ID、项目、路径或对话内容。

## 连接步骤

1. 在[众创中心](https://dual.xiaowuai.vip/developer)建立沙箱应用，自行保存仅显示一次的沙箱 Token。
2. 取得该应用获准访问的测试设备 ID、两屏模板 ID、模板字段和各屏实际像素尺寸。当前创作者页面未显示这些信息，不能把应用 ID 当设备 ID，也不能假设提案模板已安装。
3. 在应用填写沙箱设备、已安装模板和实际尺寸，确认沙箱用途，点击“应用沙箱配置”。
4. 将沙箱凭据直接填入隐藏输入框，点击“连接测试设备”。凭据只驻留当前进程，断开或退出后清除，不保存到偏好或导出文件。正常重新启动时需重新连接。
5. 分别推送 A/B 屏示例。202 响应必须含 task_id 才记录“平台已受理”；不会据此标记实机显示成功。B 屏开始推送后至少等待 15 分钟，防止超时但服务端实际已排队时重复推送；A 屏成功后至少等待 10 分钟。间隔保存在独立设置中，断开和重启仍生效；两屏独立节流，失败另有 30 秒起步退避。
6. 平台受理之后，由模拟器和真实测试设备核对内容、字体、颜色、刷新及过期行为，再补齐审核验证记录。

## 接口与模板

依据[官方 OpenAPI 0.1.0](https://dual.xiaowuai.vip/backend/openapi.json)：

- `GET /backend/openapi/v1/devices/{device_id}`：读取目标设备并检查返回的设备 ID；如返回 environment 且不是 sandbox，拒绝继续。
- `POST /backend/openapi/v1/devices/{device_id}/content`：使用 Authorization Bearer 沙箱凭据发送 `template / screen / data / expires_in_seconds`。screen 分别为 A、B；内容有效期 3600 秒。
- 请求仅访问固定官方域名，不跟随重定向，不使用共享 Cookie 或持久网络缓存。接口错误只显示状态码，不把可能回显凭据的服务端正文展示到界面。

主流程直接推送结构化模板数据。没有将沙箱应用凭据用于未确认权限的 `/api/uploads`，也没有调用管理接口、修改生产设备或自动提交审核。

`codex-pulse-a` / `codex-pulse-b` 是供平台评估的模板 ID 提案。模板请求 JSON、数据 schema、布局 JSON、PNG 与 SVG 构成一致的设计资料。**schema 注册本身不等于已有渲染器；平台需确认并安装相应模板/渲染映射。** 线上排版以平台实际渲染结果为准，必须与本地参考图另行核对。

关键字段：schema_version、is_sample、generated_at、title、status、detail、screen_width、screen_height、minimum_font_pixels。A 屏另含 remaining_percent、tokens24h、full_reset_count、quota_resets_at；B 屏 history 中含 recorded_at、remaining_percent、segment，跨 segment 不连线。

## 候选应用与构建

`CODEX_PULSE_S3_CANDIDATE=1` 打包会写入候选标记。该应用直接打开沙箱界面，关闭仪表盘采集服务，并使用独立偏好和 `CodexSuanliMeter/S3SandboxCandidate` 数据目录。候选包使用独立 Bundle ID，不安装或替换日常版本；本地候选包不附桌面小组件。

通过现有 `script/build_and_run.sh` 生成候选包；具体构建参数与本次产物见 `analysis_results/s3_dual_creator_20261026/` 的交付说明。正常主应用的构建默认不变。

## 验证边界

专项测试覆盖接口编码和固定目标、数据白名单、非示例输入拒绝、错误认证和生产环境拦截、PNG 完整性、202 回执校验、部分失败、取消、独立节流、图像配色、尺寸、文字边界、资料导出及设置页渲染。测试使用模拟服务，不等于已完成线上沙箱。

macOS 13 为部署目标；未在该系统另行实机运行。离线候选版的布局、构建和启动验收，不替代平台模板、真实固件或设备显示验收。
