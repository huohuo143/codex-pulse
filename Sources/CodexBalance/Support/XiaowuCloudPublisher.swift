import AppKit
import Foundation
import CodexBalanceCore

@MainActor
protocol XiaowuCloudService: AnyObject {
  func devices() async throws -> [XiaowuDevice]
  func publish(png: Data, device: XiaowuDevice, profile: EInkScreenProfile, modeID: String) async throws -> Data
  func preview(device: XiaowuDevice, profile: EInkScreenProfile, modeID: String) async throws -> Data
}

@MainActor
final class XiaowuCloudPublisher: XiaowuCloudService {
  private let transport: any XiaowuCloudTransport
  init(transport: any XiaowuCloudTransport) { self.transport = transport }
  func devices() async throws -> [XiaowuDevice] {
    try XiaowuCloudContract.devices(from: await checked("/api/user/devices"))
  }
  func publish(png: Data, device: XiaowuDevice, profile: EInkScreenProfile, modeID: String) async throws -> Data {
    guard XiaowuCloudContract.validMAC(device.mac), profile.canPublish else { throw XiaowuCloudError.unsupported }
    guard try await devices().contains(where: { $0.mac == device.mac }) else { throw XiaowuCloudError.invalidDevice }
    let url = try XiaowuCloudContract.uploadURL(from: await checked("/api/uploads", method: "POST", body: png, contentType: "image/png"))
    let definition = try XiaowuCloudContract.modeDefinition(modeID: modeID, device: device, profile: profile, imageURL: url)
    let mode = try JSONSerialization.jsonObject(with: definition)
    let probe = try JSONSerialization.data(withJSONObject: ["mode_def": mode, "mac": device.mac,
      "w": profile.width, "h": profile.height, "colors": profile.colors])
    // Validate image/layout before replacing the device's last working definition.
    let preview = try await checked("/api/modes/custom/preview", method: "POST", body: probe, image: true)
    try validatePNG(preview, profile: profile)
    try Task.checkCancellation()
    let result = try await checked("/api/modes/custom", method: "POST", body: definition)
    guard let root = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any], root["ok"] as? Bool == true,
      root["mode_id"] as? String == modeID else { throw XiaowuCloudError.unsupported }
    return preview
  }
  func preview(device: XiaowuDevice, profile: EInkScreenProfile, modeID: String) async throws -> Data {
    guard XiaowuCloudContract.validMAC(device.mac) else { throw XiaowuCloudError.invalidDevice }
    var parts = URLComponents(); parts.path = "/api/preview"
    parts.queryItems = [.init(name: "mac", value: device.mac), .init(name: "persona", value: modeID),
      .init(name: "w", value: String(profile.width)), .init(name: "h", value: String(profile.height)),
      .init(name: "colors", value: String(profile.colors)), .init(name: "no_cache", value: "1")]
    let result = try await checked(parts.string!, image: true)
    try validatePNG(result, profile: profile)
    return result
  }
  private func checked(_ path: String, method: String = "GET", body: Data? = nil,
    contentType: String = "application/json", image: Bool = false) async throws -> Data {
    try Task.checkCancellation()
    let response = try await transport.request(path: path, method: method, body: body, contentType: contentType)
    try Task.checkCancellation()
    if response.status == 401 { throw XiaowuCloudError.loginRequired }
    if [403, 404, 405, 422].contains(response.status) { throw XiaowuCloudError.unsupported }
    guard (200...299).contains(response.status) else { throw XiaowuCloudError.http(response.status) }
    guard response.contentType.lowercased().contains(image ? "image/png" : "application/json") else { throw XiaowuCloudError.unsupported }
    return response.data
  }
  private func validatePNG(_ data: Data, profile: EInkScreenProfile) throws {
    guard data.count >= 24, Array(data.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw XiaowuCloudError.invalidImage }
    func integer(_ offset: Int) -> Int { data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
    guard integer(16) == profile.width, integer(20) == profile.height,
      let decoded = NSBitmapImageRep(data: data), decoded.pixelsWide == profile.width,
      decoded.pixelsHigh == profile.height else { throw XiaowuCloudError.invalidImage }
  }
}
