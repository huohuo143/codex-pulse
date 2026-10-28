import AppKit
import CodexBalanceCore

/// Native, opaque, binary PNGs at exactly the image region's pixel dimensions.
@MainActor
enum EInkRenderer {
  static func render(_ value: EInkPresentation, profile: EInkScreenProfile) throws -> Data {
    guard profile.isValid else { throw XiaowuCloudError.invalidImage }
    let canvas = try EInkCanvas(width: profile.width, height: profile.imageHeight)
    let w = Double(profile.width), h = Double(profile.imageHeight)
    let k = min(w / 400, h / 230), p = 10 * k, split = w * 0.52
    canvas.text("Codex 脉动", x: p, y: 5*k, width: w*0.45, size: 16*k, bold: true)
    canvas.text("\(value.isSample ? "示例 · " : "生成于 ")\(EInkFormat.date(value.generatedAt, full: true))", x: w*0.46, y: 9*k, width: w*0.54-p, size: 10*k, align: .right)
    let top = 32*k
    canvas.text("算力总览 · 7天额度", x: p, y: top, width: split-p*2, size: 11*k, bold: true)
    let cx = p+30*k, cy = top+45*k, radius = 28*k
    canvas.circle(x: cx, y: cy, radius: radius, width: 2*k)
    if let percent = value.remainingPercent {
      canvas.arc(x: cx, y: cy, radius: radius, fraction: percent/100, width: 5*k)
    }
    canvas.text(value.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "—", x: cx-radius+2*k, y: cy-11*k, width: radius*2-4*k, size: 19*k, bold: true, align: .center)
    let tx = p+72*k, tw = split-tx-6*k
    canvas.text("24h  \(EInkFormat.tokens(value.tokens24h))", x: tx, y: top+19*k, width: tw, size: 12*k, bold: true)
    canvas.text("Full reset  \(value.resetCredits.map { "\($0)次" } ?? "—")", x: tx, y: top+38*k, width: tw, size: 11*k)
    canvas.text("距重置 \(EInkFormat.duration(until: value.resetsAt, at: value.generatedAt))", x: tx, y: top+56*k, width: tw, size: 10*k)
    canvas.text(value.quotaState.label, x: p, y: top+79*k, width: split-p*2, size: 10*k)

    canvas.line(x1: split, y1: top, x2: split, y2: top+91*k, width: k)
    let rx = split+12*k, rw = w-rx-p
    canvas.text("Tibo 重置预告", x: rx, y: top, width: rw, size: 11*k, bold: true)
    canvas.text(value.radarState, x: rx, y: top+18*k, width: rw, size: 19*k, bold: true)
    let timing: String
    if let until = value.completionUntil {
      timing = "生成时展示剩余 \(EInkFormat.duration(until: until, at: value.generatedAt))"
    } else if let deadline = value.radarDeadline {
      timing = "最晚 \(EInkFormat.date(deadline, full: true)) 北京时间"
    } else { timing = "期限待确认 · 每10分钟检查" }
    canvas.text(timing, x: rx, y: top+47*k, width: rw, size: 11*k, bold: true)
    canvas.text(value.radarHealthy ? "末次检查正常" : "等待刷新或分析", x: rx, y: top+66*k, width: rw, size: 10*k)
    canvas.text("检查 \(EInkFormat.date(value.radarCheckedAt, full: true))", x: rx, y: top+80*k, width: rw, size: 10*k)

    let hy = top+103*k
    canvas.line(x1: p, y1: hy-6*k, x2: w-p, y2: hy-6*k, width: k)
    canvas.text("官方额度历史 · 近7天", x: p, y: hy, width: w*0.65, size: 11*k, bold: true)
    let latest = value.history.last
    canvas.text(latest.map { String(format: "%.1f%% · ", $0.remainingPercent)+EInkFormat.date($0.recordedAt, full: true) } ?? "暂无采样", x: w*0.60, y: hy+2*k, width: w*0.40-p, size: 9*k, align: .right)
    let gx = p+25*k, gy = hy+21*k, gw = w-gx-p, gh = max(10, h-gy-29*k)
    for percent in [0, 50, 100] {
      let y = gy+gh*(1-Double(percent)/100)
      canvas.text("\(percent)%", x: p-2*k, y: y-5*k, width: 24*k, size: 8*k, align: .right)
      canvas.line(x1: gx, y1: y, x2: gx+gw, y2: y, width: percent == 50 ? 0.5*k : k, dashed: percent == 50)
    }
    if value.history.isEmpty {
      canvas.text("暂无官方额度样本", x: gx, y: gy+gh/2-7*k, width: gw, size: 12*k, align: .center)
    } else {
      let cutoff = value.generatedAt.addingTimeInterval(-7*86400)
      var previous: CodexWidgetQuotaPoint?
      var previousXY: (Double, Double)?
      for point in value.history {
        let x = gx+gw*min(1, max(0, point.recordedAt.timeIntervalSince(cutoff)/(7*86400)))
        let y = gy+gh*(1-point.remainingPercent/100)
        if previous?.segment == point.segment, let (px, py) = previousXY {
          canvas.line(x1: px, y1: py, x2: x, y2: y, width: max(1.5, 1.5*k))
        }
        canvas.dot(x: x, y: y, radius: max(1, k))
        previous = point; previousXY = (x, y)
      }
    }
    for (fraction, age) in [(0.0, -7.0), (0.5, -3.5), (1.0, 0.0)] {
      let formatter = DateFormatter(); formatter.dateFormat = "M/d"; formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
      let label = formatter.string(from: value.generatedAt.addingTimeInterval(age*86400))
      let labelX = min(w-p-40*k, max(p, gx+gw*fraction-20*k))
      canvas.text(label, x: labelX, y: gy+gh+2*k, width: 40*k, size: 8*k, align: .center)
    }
    let stamp = "数据截至：额度 \(EInkFormat.date(value.quotaSampledAt)) · 用量 \(EInkFormat.date(value.usageSampledAt)) · 预告 \(EInkFormat.date(value.radarCheckedAt))（北京）"
    canvas.text(stamp, x: p, y: h-12*k, width: w-p*2, size: 9*k)
    return try canvas.png()
  }

  static func devicePreview(_ board: Data, profile: EInkScreenProfile) throws -> Data {
    guard profile.isValid, let image = NSImage(data: board) else { throw XiaowuCloudError.invalidImage }
    let canvas = try EInkCanvas(width: profile.width, height: profile.height)
    let k = Double(profile.width)/400
    canvas.text("小悟页眉区域 · 时间 / 天气 / 电量", x: 10*k, y: 8*k, width: Double(profile.width)-20*k, size: 10*k)
    canvas.image(image, x: 0, y: Double(profile.headerHeight), width: Double(profile.width), height: Double(profile.imageHeight))
    canvas.text("小悟页脚区域 · Codex 脉动", x: 10*k, y: Double(profile.height-profile.footerHeight)+5, width: Double(profile.width)-20*k, size: 9*k)
    return try canvas.png()
  }
}

@MainActor
private final class EInkCanvas {
  private let bitmap: NSBitmapImageRep
  private let previous: NSGraphicsContext?
  private let height: Double
  init(width: Int, height: Int) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .calibratedWhite,
      bytesPerRow: 0, bitsPerPixel: 8), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      throw XiaowuCloudError.invalidImage
    }
    self.bitmap = bitmap; self.height = Double(height); previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
  }
  private func rect(_ x: Double, _ y: Double, _ width: Double, _ h: Double) -> NSRect {
    NSRect(x: x, y: height-y-h, width: width, height: h)
  }
  func text(_ value: String, x: Double, y: Double, width: Double, size: Double, bold: Bool = false, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = align; paragraph.lineBreakMode = .byTruncatingTail
    var actual = size
    while actual > size*0.75, (value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: actual, weight: bold ? .bold : .regular)]).width > width {
      actual -= 0.5
    }
    (value as NSString).draw(in: rect(x, y, width, size*1.6), withAttributes: [
      .font: NSFont.systemFont(ofSize: actual, weight: bold ? .bold : .regular),
      .foregroundColor: NSColor.black, .paragraphStyle: paragraph
    ])
  }
  func line(x1: Double, y1: Double, x2: Double, y2: Double, width: Double, dashed: Bool = false) {
    NSColor.black.setStroke(); let path = NSBezierPath(); path.lineWidth = width
    if dashed { path.setLineDash([2, 3], count: 2, phase: 0) }
    path.move(to: NSPoint(x: x1, y: height-y1)); path.line(to: NSPoint(x: x2, y: height-y2)); path.stroke()
  }
  func circle(x: Double, y: Double, radius: Double, width: Double) {
    NSColor.black.setStroke(); let path = NSBezierPath(ovalIn: rect(x-radius, y-radius, radius*2, radius*2)); path.lineWidth = width; path.stroke()
  }
  func arc(x: Double, y: Double, radius: Double, fraction: Double, width: Double) {
    guard fraction > 0 else { return }
    NSColor.black.setStroke(); let path = NSBezierPath(); path.lineWidth = width
    path.appendArc(withCenter: NSPoint(x: x, y: height-y), radius: radius,
      startAngle: 90, endAngle: 90-360*fraction, clockwise: true); path.stroke()
  }
  func dot(x: Double, y: Double, radius: Double) {
    NSColor.black.setFill(); NSBezierPath(ovalIn: rect(x-radius, y-radius, radius*2, radius*2)).fill()
  }
  func image(_ value: NSImage, x: Double, y: Double, width: Double, height: Double) {
    value.draw(in: rect(x, y, width, height))
  }
  func png() throws -> Data {
    defer { NSGraphicsContext.current = previous }
    if let bytes = bitmap.bitmapData {
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide { bytes[y*bitmap.bytesPerRow+x] = bytes[y*bitmap.bytesPerRow+x] > 160 ? 255 : 0 }
      }
    }
    guard let result = bitmap.representation(using: .png, properties: [:]) else { throw XiaowuCloudError.invalidImage }
    return result
  }
}
