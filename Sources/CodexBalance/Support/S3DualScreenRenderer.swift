import AppKit
import CodexBalanceCore

@MainActor
enum S3DualScreenRenderer {
  static func png(_ layout: S3DualScreenLayout) throws -> Data {
    let p = layout.profile
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: p.width, pixelsHigh: p.height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
      bytesPerRow: 0, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw S3SandboxError.invalidImage }
    let previous = NSGraphicsContext.current; NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = previous }
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: p.width, height: p.height).fill()
    for c in layout.commands {
      let color = c.accent ? NSColor(red: 192.0/255, green: 0, blue: 0, alpha: 1) : .black
      switch c.kind {
      case .text:
        let font = NSFont.systemFont(ofSize: c.fontSize, weight: c.bold ? .bold : .regular)
        let baseline = Double(p.height)-c.points[1]
        (c.text as NSString).draw(at: NSPoint(x: c.points[0], y: baseline+font.descender), withAttributes: [.font: font, .foregroundColor: color])
      case .line, .polyline:
        let path = NSBezierPath(); path.lineWidth = 2; color.setStroke()
        path.move(to: .init(x: c.points[0], y: Double(p.height)-c.points[1]))
        for i in stride(from: 2, to: c.points.count, by: 2) { path.line(to: .init(x: c.points[i], y: Double(p.height)-c.points[i+1])) }
        path.stroke()
      }
    }
    // Quantize to the documented black/white/red palette; no antialiasing greys reach the panel.
    guard let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: p.width, pixelsHigh: p.height,
      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .calibratedRGB,
      bytesPerRow: 0, bitsPerPixel: 24), let destination = opaque.bitmapData else { throw S3SandboxError.invalidImage }
    if let bytes = bitmap.bitmapData {
      for y in 0..<p.height { for x in 0..<p.width {
        let i = y*bitmap.bytesPerRow+x*4, j = y*opaque.bytesPerRow+x*3
        let r = bytes[i], g = bytes[i+1], b = bytes[i+2]
        if !p.monochrome && r > 120 && g < 110 && b < 110 { destination[j] = 192; destination[j+1] = 0; destination[j+2] = 0 }
        else { let v: UInt8 = Int(r)+Int(g)+Int(b) > 480 ? 255 : 0; destination[j] = v; destination[j+1] = v; destination[j+2] = v }
      } }
    }
    guard let data = opaque.representation(using: .png, properties: [:]) else { throw S3SandboxError.invalidImage }
    return data
  }
}
