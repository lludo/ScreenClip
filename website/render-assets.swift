// Optional macOS-only asset generator. Generated PNGs are checked into src/assets.
// Run from the repository root: swift website/render-assets.swift
import AppKit

let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("src/assets")
let orange = NSColor(srgbRed: 0.969, green: 0.408, blue: 0.149, alpha: 1)
let ink = NSColor(srgbRed: 0.153, green: 0.169, blue: 0.149, alpha: 1)
let paper = NSColor(srgbRed: 0.976, green: 0.973, blue: 0.957, alpha: 1)

func icon(_ rect: NSRect) {
  orange.setFill()
  NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.24, yRadius: rect.width * 0.24).fill()
  NSColor.white.setStroke()
  let marks = NSBezierPath()
  marks.lineWidth = rect.width * 0.055
  marks.lineCapStyle = .round
  marks.lineJoinStyle = .round
  for (x, y, dx, dy) in [(0.27, 0.27, 1.0, 1.0), (0.73, 0.27, -1, 1), (0.27, 0.73, 1, -1), (0.73, 0.73, -1, -1)] {
    marks.move(to: NSPoint(x: rect.minX + (x + dx * 0.115) * rect.width, y: rect.minY + y * rect.height))
    marks.line(to: NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height))
    marks.line(to: NSPoint(x: rect.minX + x * rect.width, y: rect.minY + (y + dy * 0.115) * rect.height))
  }
  marks.stroke()
  NSColor.white.setFill()
  NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.width * 0.045, y: rect.midY - rect.height * 0.045, width: rect.width * 0.09, height: rect.height * 0.09)).fill()
}

func png(name: String, width: Int, height: Int, draw: () -> Void) throws {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

func text(_ value: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
  (value as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

try png(name: "social-preview.png", width: 1200, height: 630) {
  paper.setFill()
  NSRect(x: 0, y: 0, width: 1200, height: 630).fill()
  icon(NSRect(x: 70, y: 492, width: 64, height: 64))
  text("ScreenClip", at: NSPoint(x: 152, y: 506), size: 32, weight: .semibold, color: ink)
  text("Capture feedback.", at: NSPoint(x: 64, y: 300), size: 94, weight: .semibold, color: ink)
  text("Keep your flow.", at: NSPoint(x: 64, y: 190), size: 94, weight: .semibold, color: orange)
  text("Notice it. Clip it. Keep going.", at: NSPoint(x: 71, y: 100), size: 28, weight: .regular, color: ink)
  text("QUICK SCREENSHOT FEEDBACK FOR MAC", at: NSPoint(x: 73, y: 50), size: 15, weight: .medium, color: ink.withAlphaComponent(0.6))
  orange.setFill()
  NSRect(x: 1120, y: 0, width: 80, height: 630).fill()
}

try png(name: "apple-touch-icon.png", width: 180, height: 180) {
  paper.setFill()
  NSRect(x: 0, y: 0, width: 180, height: 180).fill()
  icon(NSRect(x: 0, y: 0, width: 180, height: 180))
}
print("Generated social preview and touch icon")
