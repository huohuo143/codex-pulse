import CodexBalanceCore
import Foundation
import ImageIO

struct S3HTTPResponse: Sendable { let status: Int; let contentType: String; let data: Data }
protocol S3HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> S3HTTPResponse }

struct S3URLSessionTransport: S3HTTPTransport {
  private let session: URLSession
  init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 40
    config.urlCache = nil
    session = URLSession(configuration: config, delegate: S3NoRedirectDelegate(), delegateQueue: nil)
  }
  func send(_ request: URLRequest) async throws -> S3HTTPResponse {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, data.count <= 8*1024*1024 else { throw S3SandboxError.incompatible }
      return .init(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", data: data)
    } catch let error as URLError where error.code == .timedOut { throw S3SandboxError.timeout }
  }
}

private final class S3NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct S3DeviceStatus: Equatable, Sendable {
  let deviceID: String
  let environment: String?
  let lastSeen: String?
}
struct S3PushReceipt: Equatable, Codable, Sendable { let screen: S3Screen; let taskID: String; let acceptedAt: Date }

protocol S3SandboxServing: Sendable {
  func device(target: S3SandboxTarget, credential: S3SandboxCredential) async throws -> S3DeviceStatus
  func publish(png: Data, sample: EInkPresentation, screen: S3Screen, profile: S3ScreenProfile,
    target: S3SandboxTarget, credential: S3SandboxCredential) async throws -> S3PushReceipt
}

struct S3SandboxService: S3SandboxServing {
  let transport: any S3HTTPTransport
  init(transport: any S3HTTPTransport = S3URLSessionTransport()) { self.transport = transport }
  func device(target: S3SandboxTarget, credential: S3SandboxCredential) async throws -> S3DeviceStatus {
    try target.validate()
    let data = try await request("/openapi/v1/devices/\(target.deviceID)", credential: credential)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw S3SandboxError.incompatible }
    let object = root["device"] as? [String: Any] ?? root
    guard let id = object["device_id"] as? String, id == target.deviceID else { throw S3SandboxError.incompatible }
    let environment = object["environment"] as? String
    if let environment, environment.lowercased() != "sandbox" { throw S3SandboxError.sandboxRequired }
    return .init(deviceID: id, environment: environment, lastSeen: object["last_seen"] as? String)
  }
  func publish(png: Data, sample: EInkPresentation, screen: S3Screen, profile: S3ScreenProfile,
    target: S3SandboxTarget, credential: S3SandboxCredential) async throws -> S3PushReceipt {
    try target.validate()
    guard sample.isSample else { throw S3SandboxError.sandboxRequired }
    guard profile.isValid, png.count >= 24, Array(png.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw S3SandboxError.invalidImage }
    func dimension(_ offset: Int) -> Int { png[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
    guard dimension(16) == profile.width, dimension(20) == profile.height,
      let source = CGImageSourceCreateWithData(png as CFData, nil),
      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
      decoded.width == profile.width, decoded.height == profile.height else { throw S3SandboxError.invalidImage }
    // Re-check authorization/target before each push. Device/template membership is enforced by the platform.
    _ = try await device(target: target, credential: credential)
    try Task.checkCancellation()
    // Sandbox app credentials are documented for OpenAPI, not the separately authenticated upload API.
    // Use structured template data; the local PNG is a review/reference artifact, never an upload probe.
    let data = try S3TemplateData(sample: sample, screen: screen, profile: profile)
    let content = try S3ContentRequest(template: target.template(for: screen), screen: screen, data: data)
    let result = try await request("/openapi/v1/devices/\(target.deviceID)/content", method: "POST",
      body: S3DualScreenContract.encode(content), credential: credential, expectedStatus: 202)
    guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
      let id = object["task_id"] as? String, !id.isEmpty else { throw S3SandboxError.incompatible }
    return .init(screen: screen, taskID: id, acceptedAt: Date())
  }
  private func request(_ path: String, method: String = "GET", body: Data? = nil,
    contentType: String = "application/json", credential: S3SandboxCredential, expectedStatus: Int? = nil) async throws -> Data {
    try Task.checkCancellation()
    var request = URLRequest(url: try S3DualScreenContract.endpoint(path)); request.httpMethod = method
    request.httpBody = body; request.timeoutInterval = 25; request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(contentType, forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
    credential.authorize(&request)
    let response = try await transport.send(request)
    try Task.checkCancellation()
    guard (200...299).contains(response.status) else { throw S3SandboxError.http(response.status) }
    guard expectedStatus == nil || response.status == expectedStatus,
      response.contentType.lowercased().contains("application/json") else { throw S3SandboxError.incompatible }
    // Server error bodies are deliberately not surfaced: they could echo a credential.
    return response.data
  }
}
