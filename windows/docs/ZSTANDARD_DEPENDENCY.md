# Windows 压缩日志支持

流式解压使用应用随附 Electron 43.1.0 的 Node.js zlib Zstandard 接口，无需额外安装命令行工具。开发测试要求 Node.js 24+。

在解压前额外扫描 Zstandard 帧头、块边界、结束标记和校验字段是否完整，避免解压接口接受截断输入后提交半截统计。边界读取遵循项目现有上游 Zstandard 帧大小读取逻辑，保持有界内存；内容解码及校验由 zlib 执行。

Electron 的第三方许可随其运行时包含在分发包中。历史日历数据的 CC BY 4.0 署名与来源另见 RESET_HISTORY_SOURCES.md 及随包资源。
