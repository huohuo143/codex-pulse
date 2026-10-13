import Foundation

/// Display-only labels; raw paths remain the identity used by budgets and usage records.
public enum ProjectDisplayLabel {
  public static func name(_ name: String, path: String) -> String {
    guard path.lowercased().hasPrefix("file://"),
      let component = URLComponents(string: path)?.percentEncodedPath.split(separator: "/").last,
      name == String(component) else { return name }
    return decoded(name)
  }

  public static func path(_ path: String) -> String {
    guard path.lowercased().hasPrefix("file://") else { return path }
    return decoded(path)
  }

  private static func decoded(_ text: String) -> String {
    guard let value = text.removingPercentEncoding,
      value.rangeOfCharacter(from: .controlCharacters) == nil else { return text }
    return value
  }
}
