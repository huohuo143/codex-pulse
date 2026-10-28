import Foundation

/// Original wording drives attention independently of a source's editorial label.
/// A keyword alone is a review cue, never a completion or an account reset.
public enum CodexRadarTiboAttention {
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

  public static func label(for post: CodexRadarTiboPost) -> String? {
    guard !post.isPublicSummary else { return nil }
    if isResetDayAnnouncement(post.originalText) { return "明确重置表态" }
    if containsResetKeyword(post.originalText) { return "含 reset · 重点关注" }
    return relatedCueLabel(post.originalText)
  }

  public static func relatedCueLabel(_ original: String) -> String? {
    if original.range(of: #"\b(?:(?:usage|rate|weekly|daily)\s+limits?|quotas?|refills?)\b|额度|重置卡"#,
      options: [.regularExpression, .caseInsensitive]) != nil { return "额度线索 · 重点核验" }
    if original.range(of: #"\b(?:propagat(?:ed|ing|ion)|lands?|landed|landing|by\s+midnight|EOD|PST|PDT)\b|到账|发放完成"#,
      options: [.regularExpression, .caseInsensitive]) != nil { return "时间/到账线索 · 待核验上下文" }
    return nil
  }

  /// A recent reset-related reply must survive a burst of unrelated posts.
  /// Attention changes presentation only; it never creates an announcement.
  public static func previewPosts(_ posts: [CodexRadarTiboPost], at now: Date, limit: Int = 3) -> [CodexRadarTiboPost] {
    guard limit > 0 else { return [] }
    let latest = posts.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    let declaration = latest.first { post in
      guard let date = post.publishedAt, date <= now, date > now.addingTimeInterval(-86400), !post.isPublicSummary else { return false }
      return isResetDayAnnouncement(post.originalText)
    }
    let recent = latest.filter { post in
      !post.isPublicSummary && post.publishedAt.map { $0 <= now && $0 > now.addingTimeInterval(-86400) } == true
    }
    let keywords = recent.filter { containsResetKeyword($0.originalText) }
    let related = recent.filter { relatedCueLabel($0.originalText) != nil }
    var seen = Set<String>()
    return Array(([declaration].compactMap { $0 } + keywords + related + latest)
      .filter { seen.insert($0.id).inserted }.prefix(limit))
  }
}
