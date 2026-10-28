import Foundation

public enum S3Screen: String, Codable, CaseIterable, Sendable { case a = "A", b = "B" }

public enum S3SandboxError: Error, LocalizedError, Equatable {
  case invalidConfiguration, credentialRequired, sandboxRequired, incompatible, invalidImage
  case http(Int), coolingDown(Int), timeout
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "请填写平台提供的测试设备 ID、模板 ID 和屏幕尺寸。"
    case .credentialRequired: "请在隐藏输入框中填写本次沙箱凭据。"
    case .sandboxRequired: "请先确认目标属于此应用的沙箱；当前版本只发送示例。"
    case .incompatible: "平台返回格式与公开接口不一致，请保留本地预览并联系平台确认模板和设备。"
    case .invalidImage: "平台没有返回有效的本站图片地址。"
    case .http(let code): code == 401 ? "沙箱登录已失效，请重新连接。" : "平台请求失败（\(code)），已保留各屏独立结果。"
    case .coolingDown(let seconds): "本屏正在等待刷新间隔或失败退避，约 \(max(1, Int(ceil(Double(seconds)/60)))) 分钟后可重试。"
    case .timeout: "平台请求超时，请稍后重试。"
    }
  }
}

/// Runtime-only credential: never Codable, persisted, exported, or included in error descriptions.
public struct S3SandboxCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let value: String
  public init(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw S3SandboxError.credentialRequired }
    self.value = trimmed
  }
  public func authorize(_ request: inout URLRequest) { request.setValue("Bearer " + value, forHTTPHeaderField: "Authorization") }
  public var description: String { "<沙箱凭据已隐藏>" }
  public var debugDescription: String { description }
}

public struct S3SandboxTarget: Codable, Equatable, Sendable {
  public var deviceID: String
  public var templateA: String
  public var templateB: String
  public var confirmedSandbox: Bool
  public init(deviceID: String = "", templateA: String = "", templateB: String = "", confirmedSandbox: Bool = false) {
    self.deviceID = deviceID; self.templateA = templateA; self.templateB = templateB; self.confirmedSandbox = confirmedSandbox
  }
  public func validate() throws {
    guard confirmedSandbox else { throw S3SandboxError.sandboxRequired }
    guard deviceID.range(of: #"^[A-Za-z0-9:_-]{3,80}$"#, options: .regularExpression) != nil,
      [templateA, templateB].allSatisfy({ $0.range(of: #"^[a-z0-9-]{1,80}$"#, options: .regularExpression) != nil })
    else { throw S3SandboxError.invalidConfiguration }
  }
  public func template(for screen: S3Screen) -> String { screen == .a ? templateA : templateB }
}

public struct S3TemplatePoint: Codable, Equatable, Sendable {
  public let recordedAt: Date
  public let remainingPercent: Double
  public let segment: Int
}

/// Project-defined template contract. The platform must install/confirm these fields before use.
/// No generic snapshot, project data, account identifier, or free-form model output is accepted.
public struct S3TemplateData: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let isSample: Bool
  public let generatedAt: Date
  public let title: String
  public let status: String
  public let detail: String
  public let remainingPercent: Double?
  public let tokens24h: Int?
  public let fullResetCount: Int?
  public let quotaResetsAt: Date?
  public let history: [S3TemplatePoint]
  public let screenWidth: Int
  public let screenHeight: Int
  public let minimumFontPixels: Int

  public init(sample: EInkPresentation, screen: S3Screen, profile: S3ScreenProfile) throws {
    guard sample.isSample else { throw S3SandboxError.sandboxRequired }
    guard profile.isValid else { throw S3SandboxError.invalidConfiguration }
    schemaVersion = 1; isSample = true; generatedAt = sample.generatedAt
    title = screen == .a ? "Codex 脉动 · 示例" : "重置预告 · 示例"
    status = screen == .a ? "算力总览" : sample.radarState
    detail = screen == .a ? "截至生成时刻 · 北京时间" : "展示剩余 " + EInkFormat.duration(until: sample.completionUntil, at: sample.generatedAt)
    remainingPercent = screen == .a ? sample.remainingPercent : nil
    tokens24h = screen == .a ? sample.tokens24h : nil
    fullResetCount = screen == .a ? sample.resetCredits : nil
    quotaResetsAt = screen == .a ? sample.resetsAt : nil
    history = screen == .b ? sample.history.map { .init(recordedAt: $0.recordedAt, remainingPercent: $0.remainingPercent, segment: $0.segment) } : []
    screenWidth = profile.width; screenHeight = profile.height; minimumFontPixels = 18
  }
}

public struct S3ContentRequest: Codable, Equatable, Sendable {
  public let template: String
  public let screen: S3Screen
  public let data: S3TemplateData
  public let expiresInSeconds: Int
  public init(template: String, screen: S3Screen, data: S3TemplateData) throws {
    guard data.isSample, template.range(of: #"^[a-z0-9-]{1,80}$"#, options: .regularExpression) != nil else { throw S3SandboxError.invalidConfiguration }
    self.template = template; self.screen = screen; self.data = data; expiresInSeconds = 3600
  }
}

public enum S3DualScreenContract {
  public static let origin = URL(string: "https://dual.xiaowuai.vip")!
  public static let candidateVersion = "0.1.0"
  public static var isCandidateBuild: Bool { Bundle.main.object(forInfoDictionaryKey: "CodexS3SandboxCandidate") as? Bool == true }
  public static func endpoint(_ path: String) throws -> URL {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw S3SandboxError.invalidConfiguration }
    return origin.appendingPathComponent("backend" + path)
  }
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

/// Keep each screen's accepted push separate; B never bypasses the 15-minute interval.
public struct S3ScreenPushPolicy: Codable, Sendable {
  private var accepted: [S3Screen: Date] = [:]
  private var attemptedB: Date?
  private var failures: [S3Screen: Int] = [:]
  private var retryAt: [S3Screen: Date] = [:]
  public init() {}
  public func validate(_ screen: S3Screen, at now: Date) throws {
    let ambiguousAttempt = screen == .b ? attemptedB?.addingTimeInterval(900) ?? .distantPast : .distantPast
    let next = max(accepted[screen]?.addingTimeInterval(screen == .b ? 900 : 600) ?? .distantPast, retryAt[screen] ?? .distantPast, ambiguousAttempt)
    if now < next { throw S3SandboxError.coolingDown(Int(ceil(next.timeIntervalSince(now)))) }
  }
  public mutating func started(_ screen: S3Screen, at now: Date) { if screen == .b { attemptedB = now } }
  public mutating func succeeded(_ screen: S3Screen, at now: Date) { accepted[screen] = now; failures[screen] = 0; retryAt[screen] = nil }
  public mutating func failed(_ screen: S3Screen, at now: Date) {
    let count = min(6, (failures[screen] ?? 0) + 1); failures[screen] = count
    retryAt[screen] = now.addingTimeInterval(min(600, 30 * pow(2, Double(count-1))))
  }
}
