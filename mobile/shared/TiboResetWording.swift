import Foundation

/// Original wording drives attention independently of a source's editorial label.
/// A keyword alone is a review cue, never a completion or an account reset.
public enum TiboResetWording {
  public static func containsResetKeyword(_ original: String) -> Bool {
    original.range(of: #"\b(?:resets?|resetting)\b|重置"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  public static func isResetDayAnnouncement(_ original: String) -> Bool {
    let text = original.lowercased().replacingOccurrences(of: "’", with: "'")
    let affirmative = #"\b(?:(?:it's|it is|today is)\s+(?:a\s+)?reset day|today is\s+(?:a\s+)?reset\b|that's\s+(?:a\s+)?reset\b|rest and reset\b)"#
    let caution = #"\b(?:not|never|isn't|won't|don't|hope|wish|if|maybe|would|could|should|might|whether|said|quote)\b"#
    // Inspect the statement's own sentence. An earlier question or a negation
    // about another subject must not suppress "But today is a reset."
    return text.replacingOccurrences(of: "?", with: "?\n")
      .components(separatedBy: CharacterSet(charactersIn: ".!;\n")).contains { sentence in
      guard !sentence.contains("?"),
            let match = sentence.range(of: affirmative, options: .regularExpression),
            String(sentence[..<match.lowerBound]).range(of: caution, options: .regularExpression) == nil,
            sentence.range(of: #"\b(?:banked|card|cards)\b"#, options: .regularExpression) == nil
      else { return false }
      return true
    }
  }

  public static func label(_ original: String) -> String? {
    if isResetDayAnnouncement(original) { return "明确重置表态" }
    return containsResetKeyword(original) ? "含 reset · 重点关注" : nil
  }
}

public extension TiboPublicFeed {
  func latestResetDeclaration(at now: Date) -> TiboPublicPost? {
    posts.filter { $0.publishedAt <= now && $0.publishedAt > now.addingTimeInterval(-86400)
      && TiboResetWording.isResetDayAnnouncement($0.originalText) }
      .max { $0.publishedAt < $1.publishedAt }
  }
  func previewPosts(at now: Date, limit: Int = 4) -> [TiboPublicPost] {
    guard limit > 0 else { return [] }
    let latest = posts.sorted { $0.publishedAt > $1.publishedAt }
    guard let declaration = latestResetDeclaration(at: now) else { return Array(latest.prefix(limit)) }
    return Array(([declaration] + latest.filter { $0.id != declaration.id }).prefix(limit))
  }
}
