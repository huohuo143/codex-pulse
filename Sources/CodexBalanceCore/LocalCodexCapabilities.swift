import Foundation

public struct LocalCodexModel: Codable, Equatable, Identifiable, Sendable {
  public struct Effort: Codable, Equatable, Sendable {
    public var reasoningEffort: String
  }
  public var id: String
  public var model: String
  public var displayName: String
  public var isDefault: Bool
  public var hidden: Bool?
  public var supportedReasoningEfforts: [Effort]
  public var defaultReasoningEffort: String

  public var availableForAnalysis: Bool {
    hidden != true && !model.isEmpty && model.count <= 200
      && model.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$"#, options: .regularExpression) != nil
  }
}

public struct LocalCodexCapabilities: Equatable, Sendable {
  public var installed: Bool
  public var accountType: String?
  public var models: [LocalCodexModel]
  public var message: String

  public init(installed: Bool, accountType: String? = nil,
              models: [LocalCodexModel] = [], message: String = "") {
    self.installed = installed; self.accountType = accountType
    self.models = models; self.message = message
  }
  public var signedIn: Bool { accountType == "chatgpt" || accountType == "apiKey" }
  public var loginLabel: String {
    switch accountType {
    case "chatgpt": "本机已登录 ChatGPT"
    case "apiKey": "本机使用 API Key；模型分析按 API 计费"
    default: message.isEmpty ? "请先在本机 Codex 登录" : message
    }
  }
  public static func inspect() async -> Self {
    await Task.detached(priority: .utility) {
      guard CodexAppServerRateLimitSource.codexExecutableURL() != nil else {
        return Self(installed: false, message: "未找到 Codex。先安装 Codex 桌面版或 CLI，并登录自己的账号。")
      }
      do {
        let source = CodexAppServerRateLimitSource()
        return try withExtendedLifetime(source) { try source.readCapabilities() }
      }
      catch { return Self(installed: true, message: "暂时无法读取本机登录与模型列表，请打开 Codex 确认登录后重试。") }
    }.value
  }
}

public struct TiboAnalysisPreferences: Equatable, Sendable {
  public static let enabledKey = "tiboAnalysisEnabled"
  public static let modelKey = "tiboAnalysisModel"
  public static let effortKey = "tiboAnalysisEffort"
  public static let sourceKey = "tiboSource"
  public var enabled: Bool
  public var model: String
  public var effort: String
  public var usesX: Bool

  public init(enabled: Bool = false, model: String = "", effort: String = "auto", usesX: Bool = false) {
    self.enabled = enabled; self.model = model; self.effort = effort; self.usesX = usesX
  }
  public static func load(defaults: UserDefaults = PulsePreferences.shared) -> Self {
    Self(enabled: defaults.bool(forKey: enabledKey),
         model: defaults.string(forKey: modelKey) ?? "",
         effort: defaults.string(forKey: effortKey) ?? "auto",
         usesX: defaults.string(forKey: sourceKey) == "x")
  }
  public func save(defaults: UserDefaults = PulsePreferences.shared) {
    defaults.set(enabled, forKey: Self.enabledKey)
    defaults.set(model, forKey: Self.modelKey)
    defaults.set(effort, forKey: Self.effortKey)
    defaults.set(usesX ? "x" : "public", forKey: Self.sourceKey)
  }
  /// Preserve an existing user's successful, explicitly configured analysis.
  /// A fresh install has no history and never starts a model request by default.
  public static func migrate(defaults: UserDefaults = PulsePreferences.shared, historyURL: URL? = nil) {
    guard defaults.object(forKey: enabledKey) == nil else { return }
    guard let historyURL = historyURL ?? CodexRadarTiboHistoryStore.defaultURL,
          let history = CodexRadarTiboHistoryStore.load(from: historyURL),
          let previous = history.analysis, let model = previous.model, !model.isEmpty else { return }
    Self(enabled: true, model: model, effort: previous.reasoningEffort ?? "auto").save(defaults: defaults)
  }

  public func selection(from capabilities: LocalCodexCapabilities) throws -> (model: String, effort: String) {
    guard enabled else { throw LocalCodexAnalysisError.disabled }
    guard capabilities.installed else { throw LocalCodexAnalysisError.missingCodex }
    guard capabilities.signedIn else { throw LocalCodexAnalysisError.signInRequired }
    let available = capabilities.models.filter(\.availableForAnalysis)
    let selected = model.isEmpty
      ? available.first(where: \.isDefault) ?? available.first
      : available.first(where: { $0.model == model })
    guard let selected else { throw LocalCodexAnalysisError.modelUnavailable }
    let supported = selected.supportedReasoningEfforts.map(\.reasoningEffort)
    let resolvedEffort = effort == "auto" ? selected.defaultReasoningEffort : effort
    guard ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(resolvedEffort),
          supported.contains(resolvedEffort) else { throw LocalCodexAnalysisError.effortUnavailable }
    return (selected.model, resolvedEffort)
  }
}

public enum LocalCodexAnalysisError: Error, LocalizedError {
  case disabled, missingCodex, signInRequired, modelUnavailable, effortUnavailable, incompatibleCLI
  public var errorDescription: String? {
    switch self {
    case .disabled: "模型分析未启用。动态仍会刷新；可在设置中选择本机模型并开启分析。"
    case .missingCodex: "未找到本机 Codex；动态读取不受影响，请安装 Codex 后再启用分析。"
    case .signInRequired: "请先在本机 Codex 登录自己的账号，再检测可用模型。"
    case .modelUnavailable: "当前账号未提供所选模型；请在设置中选择“自动使用当前账号默认模型”或其他可用模型。"
    case .effortUnavailable: "当前模型不支持所选推理强度；请在设置中改为“模型默认”。"
    case .incompatibleCLI: "本机 Codex CLI 版本不支持隔离分析。请更新 Codex；公开动态仍可查看。"
    }
  }
}
