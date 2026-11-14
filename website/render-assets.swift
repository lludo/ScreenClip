// Optional macOS-only refresh for the 1200×630 share image.
// Run from the repository root: swift website/render-assets.swift
// Favicons in dist/ are drawn by build.py.
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

let accent = NSColor(srgbRed: 0.722, green: 0.263, blue: 0.039, alpha: 1)
try png(name: "og.png", width: 1200, height: 630) {
  paper.setFill()
  NSRect(x: 0, y: 0, width: 1200, height: 630).fill()
  icon(NSRect(x: 72, y: 492, width: 76, height: 76))
  text("ScreenClip", at: NSPoint(x: 168, y: 514), size: 34, weight: .semibold, color: ink)
  text("File bugs as you go,", at: NSPoint(x: 72, y: 330), size: 68, weight: .bold, color: ink)
  text("without breaking your flow.", at: NSPoint(x: 72, y: 240), size: 68, weight: .bold, color: accent)
  text("Codex  ·  Claude Code  ·  Grok Bot", at: NSPoint(x: 72, y: 150), size: 30, weight: .medium, color: ink.withAlphaComponent(0.72))
  text("Menu bar app for macOS · Coming soon", at: NSPoint(x: 72, y: 78), size: 26, weight: .medium, color: ink.withAlphaComponent(0.72))
  orange.setFill()
  NSRect(x: 1124, y: 0, width: 76, height: 630).fill()
}
print("Generated og.png")
