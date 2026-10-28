import Foundation

public struct XiaowuDevice: Codable, Equatable, Identifiable, Sendable {
  public let mac: String
  public let nickname: String
  public var id: String { mac }
  public var title: String { nickname.isEmpty ? mac : nickname }
  public init(mac: String, nickname: String = "") { self.mac = mac.uppercased(); self.nickname = nickname }
}

public enum XiaowuCloudError: Error, LocalizedError, Equatable {
  case loginRequired, unsupported, invalidImage, invalidDevice, unavailable, timeout
  case http(Int)
  public var errorDescription: String? {
    switch self {
    case .loginRequired: "小悟登录已失效，自动同步已暂停。请在官方窗口自行重新登录。"
    case .unsupported: "小悟线上接口与预期不兼容；已保留本地预览和上一次云端画面。"
    case .invalidImage: "小悟未返回有效图片，已保留上一次画面。"
    case .invalidDevice: "请先选择已绑定的小悟设备。"
    case .unavailable: "无法连接小悟云，已保留上一次画面。"
    case .timeout: "小悟请求超时，稍后重试。"
    case .http(let code): "小悟请求失败（\(code)），已保留上一次画面。"
    }
  }
}

public enum XiaowuCloudContract {
  public static let origin = URL(string: "https://xiaowuai.vip")!
  public static func validMAC(_ value: String) -> Bool {
    value.range(of: #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#, options: .regularExpression) != nil
  }
  public static func modeID(installationID: String, mac: String) -> String {
    let suffix = installationID.filter { $0.isASCII && $0.isHexDigit }.prefix(12).uppercased()
    return "CODEX_PULSE_\(suffix)_\(mac.filter { $0.isHexDigit }.uppercased())"
  }
  public static func devices(from data: Data) throws -> [XiaowuDevice] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let rows = root["devices"] as? [[String: Any]] else { throw XiaowuCloudError.unsupported }
    var seen = Set<String>()
    return rows.compactMap { row in
      guard let mac = row["mac"] as? String, validMAC(mac), seen.insert(mac.uppercased()).inserted else { return nil }
      return XiaowuDevice(mac: mac, nickname: row["nickname"] as? String ?? "")
    }
  }
  public static func uploadURL(from data: Data) throws -> URL {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["ok"] as? Bool == true,
          let raw = root["url"] as? String,
          let url = URL(string: raw, relativeTo: origin)?.absoluteURL,
          url.scheme == "https", url.host?.lowercased() == origin.host,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.port == nil || url.port == 443,
          UUID(uuidString: String(url.path.dropFirst("/api/uploads/".count))) != nil,
          url.path.hasPrefix("/api/uploads/") else { throw XiaowuCloudError.unsupported }
    return url
  }
  public static func modeDefinition(modeID: String, device: XiaowuDevice, profile: EInkScreenProfile, imageURL: URL) throws -> Data {
    guard validMAC(device.mac), profile.canPublish else { throw XiaowuCloudError.unsupported }
    let object: [String: Any] = [
      "mode_id": modeID, "mac": device.mac, "display_name": "Codex 脉动",
      "description": "额度、重置预告与最近7天额度历史；数据截至图内标注时间。",
      "cacheable": false, "content": ["type": "static", "static_data": ["image_url": imageURL.absoluteString]],
      "layout": ["body_align": "top", "body": [["type": "image", "field": "image_url", "x": 0,
        "y": profile.headerHeight, "width": 400, "height": profile.imageBaseHeight,
        "fit": "contain", "photo_enhance": false, "margin_bottom": 0]],
        "footer": ["label": "Codex 脉动", "height": 30]]
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
