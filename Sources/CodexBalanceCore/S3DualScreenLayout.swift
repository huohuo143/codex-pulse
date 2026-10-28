import Foundation

public struct S3ScreenProfile: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var monochrome: Bool
  public init(width: Int = 400, height: Int = 300, monochrome: Bool = false) { self.width = width; self.height = height; self.monochrome = monochrome }
  public var isValid: Bool { (400...1600).contains(width) && (300...1200).contains(height) }
}

public struct S3DrawCommand: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case text, line, polyline }
  public let kind: Kind
  public let points: [Double]
  public let text: String
  public let fontSize: Double
  public let bold: Bool
  public let accent: Bool
}

/// A single geometry source drives editable SVG and native PNG; fonts never auto-shrink.
public struct S3DualScreenLayout: Codable, Equatable, Sendable {
  public let profile: S3ScreenProfile
  public let screen: S3Screen
  public let commands: [S3DrawCommand]
  public init(sample: EInkPresentation, screen: S3Screen, profile: S3ScreenProfile) throws {
    guard profile.isValid, sample.isSample else { throw S3SandboxError.invalidConfiguration }
    self.profile = profile; self.screen = screen
    let scale = min(Double(profile.width)/400, Double(profile.height)/300)
    let offsetX = (Double(profile.width)-400*scale)/2, offsetY = (Double(profile.height)-300*scale)/2
    var output: [S3DrawCommand] = []
    func text(_ value: String, _ x: Double, _ baseline: Double, _ size: Double = 18, bold: Bool = false, accent: Bool = false) {
      output.append(.init(kind: .text, points: [offsetX+x*scale, offsetY+baseline*scale], text: value, fontSize: max(18, size*scale), bold: bold, accent: accent && !profile.monochrome))
    }
    func line(_ x: Double, _ y: Double, _ xx: Double, _ yy: Double) {
      output.append(.init(kind: .line, points: [offsetX+x*scale, offsetY+y*scale, offsetX+xx*scale, offsetY+yy*scale], text: "", fontSize: 0, bold: false, accent: false))
    }
    text(screen == .a ? "Codex 脉动" : "重置预告", 18, 34, 24, bold: true)
    text("示例", 338, 32, 18, bold: true, accent: screen == .b)
    line(18, 45, 382, 45)
    if screen == .a {
      text(sample.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "—", 18, 110, 58, bold: true)
      text("7 天剩余额度", 18, 138)
      text("24h Token", 224, 78)
      text(EInkFormat.tokens(sample.tokens24h), 224, 113, 30, bold: true)
      line(18, 153, 382, 153)
      text("Full reset", 18, 182); text("\(sample.resetCredits ?? 0) 次", 254, 182, 22, bold: true)
      text("周期重置", 18, 216); text(EInkFormat.duration(until: sample.resetsAt, at: sample.generatedAt), 254, 216, 20, bold: true)
      text("更新 " + EInkFormat.date(sample.generatedAt, full: true), 18, 260)
      text("截至生成时刻 · 北京时间", 18, 289)
    } else {
      text(sample.radarState, 18, 84, 28, bold: true, accent: true)
      text("展示剩余 " + EInkFormat.duration(until: sample.completionUntil, at: sample.generatedAt), 18, 116)
      text("官方额度历史 · 近 7 天", 18, 151, 18, bold: true)
      let gx = 62.0, gy = 169.0, gw = 320.0, gh = 70.0
      text("100", 18, gy+7); text("0", 38, gy+gh+5)
      line(gx, gy, gx, gy+gh); line(gx, gy+gh, gx+gw, gy+gh)
      let cutoff = sample.generatedAt.addingTimeInterval(-7*86400)
      var segment: Int?, points: [Double] = []
      func flush() {
        if points.count >= 4 { output.append(.init(kind: .polyline, points: points, text: "", fontSize: 0, bold: false, accent: false)) }
        points = []
      }
      for point in sample.history {
        if point.segment != segment { flush(); segment = point.segment }
        let x = gx + gw * min(1, max(0, point.recordedAt.timeIntervalSince(cutoff)/(7*86400)))
        let y = gy + gh * (1-point.remainingPercent/100)
        points += [offsetX+x*scale, offsetY+y*scale]
      }
      flush()
      let formatter = DateFormatter(); formatter.dateFormat = "MM/dd"; formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
      text(formatter.string(from: cutoff), gx, 263); text(formatter.string(from: sample.generatedAt), 330, 263)
      text("更新 " + EInkFormat.date(sample.generatedAt, full: true), 18, 289)
    }
    commands = output
  }
  public func svg() -> Data {
    func escape(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    var lines = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(profile.width)\" height=\"\(profile.height)\" viewBox=\"0 0 \(profile.width) \(profile.height)\">", "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>"]
    for c in commands {
      let color = c.accent ? "#C00000" : "#000000"
      switch c.kind {
      case .text: lines.append("<text x=\"\(c.points[0])\" y=\"\(c.points[1])\" font-family=\"PingFang SC, sans-serif\" font-size=\"\(c.fontSize)\" font-weight=\"\(c.bold ? 700 : 400)\" fill=\"\(color)\">\(escape(c.text))</text>")
      case .line: lines.append("<line x1=\"\(c.points[0])\" y1=\"\(c.points[1])\" x2=\"\(c.points[2])\" y2=\"\(c.points[3])\" stroke=\"black\" stroke-width=\"2\"/>")
      case .polyline:
        let pairs = stride(from: 0, to: c.points.count, by: 2).map { "\(c.points[$0]),\(c.points[$0+1])" }.joined(separator: " ")
        lines.append("<polyline points=\"\(pairs)\" fill=\"none\" stroke=\"black\" stroke-width=\"2\"/>")
      }
    }
    lines.append("</svg>"); return Data(lines.joined(separator: "\n").utf8)
  }
}
