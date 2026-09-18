import Foundation

struct UsageKeywordRule {
  var bytes: [UInt8]
  var weight: Int

  init(_ keyword: String, _ weight: Int) {
    bytes = Array(keyword.utf8)
    self.weight = weight
  }
}

let tokenCountNeedle = Array(#""token_count""#.utf8)
let developerRoleNeedle = Array(#""role":"developer""#.utf8)
let systemRoleNeedle = Array(#""role":"system""#.utf8)
let turnContextNeedle = Array(#""type":"turn_context""#.utf8)
let sessionMetaNeedle = Array(#""type":"session_meta""#.utf8)
let functionOutputNeedle = Array(#""type":"function_call_output""#.utf8)
let cwdNeedle = Array(#""cwd""#.utf8)
let userRoleNeedle = Array(#""role":"user""#.utf8)
let assistantRoleNeedle = Array(#""role":"assistant""#.utf8)
let userMessageNeedle = Array(#""type":"user_message""#.utf8)
let functionCallNeedle = Array(#""type":"function_call""#.utf8)
let presentationKeywordRules = [
  UsageKeywordRule("pptx", 10),
  UsageKeywordRule("powerpoint", 10),
  UsageKeywordRule("演示文稿", 10),
  UsageKeywordRule("幻灯片", 10),
  UsageKeywordRule("slide deck", 9),
  UsageKeywordRule("presentation deck", 9),
  UsageKeywordRule("slides", 7),
  UsageKeywordRule("slide", 5),
  UsageKeywordRule("presentations:", 7),
  UsageKeywordRule("presentations", 6),
  UsageKeywordRule("generate_deck", 7),
  UsageKeywordRule("powerpoint:", 7),
  UsageKeywordRule("ppt", 4)
]
let imageKeywordRules = [
  UsageKeywordRule("imagegen", 10),
  UsageKeywordRule("生成图片", 9),
  UsageKeywordRule("做图", 9),
  UsageKeywordRule("图片", 5),
  UsageKeywordRule("图像", 5),
  UsageKeywordRule("海报", 5),
  UsageKeywordRule("插画", 5),
  UsageKeywordRule("视觉", 4),
  UsageKeywordRule("figma", 6),
  UsageKeywordRule("canva", 6),
  UsageKeywordRule("png", 3),
  UsageKeywordRule("jpg", 3)
]
let documentKeywordRules = [
  UsageKeywordRule("docx", 10),
  UsageKeywordRule("word", 7),
  UsageKeywordRule("申请表", 9),
  UsageKeywordRule("文档", 5),
  UsageKeywordRule("表格", 5),
  UsageKeywordRule("填写", 4),
  UsageKeywordRule("documents", 6),
  UsageKeywordRule("render_docx", 8),
  UsageKeywordRule("xlsx", 7),
  UsageKeywordRule("spreadsheet", 6),
  UsageKeywordRule("excel", 6)
]
let codingKeywordRules = [
  UsageKeywordRule("apply_patch", 10),
  UsageKeywordRule("swift test", 8),
  UsageKeywordRule("npm run", 7),
  UsageKeywordRule("package.swift", 6),
  UsageKeywordRule(".swift", 4),
  UsageKeywordRule(".jsx", 4),
  UsageKeywordRule(".tsx", 4),
  UsageKeywordRule("代码", 5),
  UsageKeywordRule("编程", 6),
  UsageKeywordRule("修复", 3),
  UsageKeywordRule("bug", 4),
  UsageKeywordRule("构建", 3),
  UsageKeywordRule("git diff", 5)
]
let researchKeywordRules = [
  UsageKeywordRule("search_query", 8),
  UsageKeywordRule("web.run", 8),
  UsageKeywordRule("pubmed", 10),
  UsageKeywordRule("zotero", 9),
  UsageKeywordRule("doi", 7),
  UsageKeywordRule("literature", 8),
  UsageKeywordRule("文献", 9),
  UsageKeywordRule("检索", 8),
  UsageKeywordRule("browse", 5),
  UsageKeywordRule("搜索", 5),
  UsageKeywordRule("调研", 6),
  UsageKeywordRule("引用", 4),
  UsageKeywordRule("citations", 5),
  UsageKeywordRule("sourceurl", 4),
  UsageKeywordRule("联网", 4)
]
let videoKeywordRules = [
  UsageKeywordRule("剪映", 10),
  UsageKeywordRule("jianying", 10),
  UsageKeywordRule("premiere", 10),
  UsageKeywordRule("after effects", 10),
  UsageKeywordRule("视频制作", 10),
  UsageKeywordRule("生成视频", 9),
  UsageKeywordRule("字幕", 7),
  UsageKeywordRule("配音", 7),
  UsageKeywordRule("video", 5),
  UsageKeywordRule("mp4", 5)
]
let manuscriptKeywordRules = [
  UsageKeywordRule("manuscript", 10),
  UsageKeywordRule("response letter", 10),
  UsageKeywordRule("reviewer", 8),
  UsageKeywordRule("abstract", 8),
  UsageKeywordRule("discussion", 7),
  UsageKeywordRule("润色", 10),
  UsageKeywordRule("改写", 8),
  UsageKeywordRule("论文", 8),
  UsageKeywordRule("综述", 9),
  UsageKeywordRule("摘要", 8),
  UsageKeywordRule("审稿", 9),
  UsageKeywordRule("基金", 7),
  UsageKeywordRule("申请书", 8),
  UsageKeywordRule("翻译", 6)
]
let dataAnalysisKeywordRules = [
  UsageKeywordRule("pandas", 10),
  UsageKeywordRule("numpy", 9),
  UsageKeywordRule("matplotlib", 9),
  UsageKeywordRule("scipy", 9),
  UsageKeywordRule("jupyter", 8),
  UsageKeywordRule("heatmap", 8),
  UsageKeywordRule("volcano", 8),
  UsageKeywordRule("pca", 7),
  UsageKeywordRule("统计分析", 10),
  UsageKeywordRule("数据分析", 10),
  UsageKeywordRule("数据清洗", 9),
  UsageKeywordRule("可视化", 6),
  UsageKeywordRule("作图", 5),
  UsageKeywordRule("绘图", 5)
]
let lifeScienceKeywordRules = [
  UsageKeywordRule("rna-seq", 10),
  UsageKeywordRule("single-cell", 10),
  UsageKeywordRule("transcriptome", 9),
  UsageKeywordRule("proteome", 9),
  UsageKeywordRule("metabolome", 9),
  UsageKeywordRule("fasta", 8),
  UsageKeywordRule("gff", 8),
  UsageKeywordRule("vcf", 8),
  UsageKeywordRule("kegg", 8),
  UsageKeywordRule("bioinformatics", 10),
  UsageKeywordRule("水稻", 10),
  UsageKeywordRule("褐飞虱", 10),
  UsageKeywordRule("病毒", 8),
  UsageKeywordRule("基因", 7),
  UsageKeywordRule("蛋白", 7),
  UsageKeywordRule("转录组", 9),
  UsageKeywordRule("代谢组", 9),
  UsageKeywordRule("组学", 8),
  UsageKeywordRule("生物信息", 10)
]
let webDevelopmentKeywordRules = [
  UsageKeywordRule("astro", 10),
  UsageKeywordRule("next.js", 10),
  UsageKeywordRule("react", 8),
  UsageKeywordRule("cloudflare", 9),
  UsageKeywordRule("website", 8),
  UsageKeywordRule("网页", 9),
  UsageKeywordRule("网站", 9),
  UsageKeywordRule("部署", 7),
  UsageKeywordRule("路由", 6),
  UsageKeywordRule("css", 6),
  UsageKeywordRule("html", 6)
]
let systemOperationsKeywordRules = [
  UsageKeywordRule("launchagent", 10),
  UsageKeywordRule("launchctl", 10),
  UsageKeywordRule("synology", 10),
  UsageKeywordRule("cloudflare tunnel", 10),
  UsageKeywordRule("dns", 8),
  UsageKeywordRule("nas920", 8),
  UsageKeywordRule("terminal", 6),
  UsageKeywordRule("群晖", 10),
  UsageKeywordRule("内网穿透", 10),
  UsageKeywordRule("网络问题", 9),
  UsageKeywordRule("电脑维护", 9),
  UsageKeywordRule("服务器", 7),
  UsageKeywordRule("自动启动", 7),
  UsageKeywordRule("安装", 5),
  UsageKeywordRule("权限", 5)
]
