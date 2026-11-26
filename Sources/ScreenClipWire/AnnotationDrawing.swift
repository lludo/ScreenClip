// On iOS this module is part of ScreenClipKit and compiles to nothing outside Debug builds.
#if !os(iOS) || DEBUG

import CoreGraphics
import CoreText
import Foundation

/// Draws annotation marks with Core Graphics so macOS and iOS produce the same image.
///
/// The context must use top-left origin coordinates (y grows downward), as a flipped `NSView`,
/// UIKit, and SwiftUI `Canvas` do. Points are fractions of `rect`.
public enum AnnotationDrawing {
  public static func draw(_ marks: [Annotation], in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.clip(to: rect)
    defer { context.restoreGState() }
    // Redactions are opaque and rendered underneath all visible marks.
    for mark in marks.sorted(by: { $0.kind == .redact && $1.kind != .redact }) {
      guard let first = mark.points.first else { continue }
      func p(_ point: MarkPoint) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
      }
      let start = p(first)
      let end = p(mark.points.last ?? first)
      let box = CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
        height: abs(end.y - start.y))
      let color = (mark.color ?? .orange).cgColor
      let lineWidth =
        mark.lineWidth.map { max(0.5, rect.width * min(0.04, max(0.0005, $0))) }
        ?? max(2, rect.width / 350)
      context.saveGState()
      context.setStrokeColor(color)
      context.setFillColor(color)
      context.setLineWidth(lineWidth)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      switch mark.kind {
      case .redact:
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(box.integral)
      case .rectangle:
        context.stroke(box)
      case .ellipse:
        context.strokeEllipse(in: box)
      case .pen:
        context.move(to: start)
        for point in mark.points.dropFirst() { context.addLine(to: p(point)) }
        context.strokePath()
      case .arrow:
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(lineWidth * 3, rect.width / 40)
        context.move(to: end)
        context.addLine(
          to: CGPoint(x: end.x - length * cos(angle - 0.45), y: end.y - length * sin(angle - 0.45)))
        context.addLine(
          to: CGPoint(x: end.x - length * cos(angle + 0.45), y: end.y - length * sin(angle + 0.45)))
        context.closePath()
        context.fillPath()
      case .text:
        drawText(mark.text, at: start, size: max(16, rect.width / 40), color: color, in: context)
      }
      context.restoreGState()
    }
  }

  /// Text with a dark backing box. `point` is the top-left corner of the text.
  static func drawText(
    _ text: String, at point: CGPoint, size: CGFloat, color: CGColor, in context: CGContext
  ) {
    guard !text.isEmpty else { return }
    let font = CTFontCreateUIFontForLanguage(.system, size, nil)
      ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): bold,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let ascent = CTFontGetAscent(bold)
    let descent = CTFontGetDescent(bold)
    let leading = CTFontGetLeading(bold)
    let lineHeight = ascent + descent + leading
    var y = point.y
    for line in text.components(separatedBy: "\n") {
      let ctLine = CTLineCreateWithAttributedString(
        NSAttributedString(string: line, attributes: attributes))
      let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
      context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8))
      context.fill(CGRect(x: point.x, y: y, width: width, height: lineHeight))
      context.saveGState()
      // Core Text draws in a y-up space; flip around the baseline.
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: point.x, y: y + ascent)
      CTLineDraw(ctLine, context)
      context.restoreGState()
      y += lineHeight
    }
  }

  /// The annotated image as PNG data, drawn at the source image's pixel size.
  /// An optional outline uses source pixels measured from the top-left corner.
  public static func renderPNG(image source: CGImage, marks: [Annotation], outline: CGPath? = nil) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let graphics = CGContext(
        data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
        bytesPerRow: source.width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    graphics.draw(source, in: bounds)
    graphics.translateBy(x: 0, y: bounds.height)
    graphics.scaleBy(x: 1, y: -1)
    draw(marks, in: bounds, context: graphics)
    if let outline {
      // Clear the exterior once, after flattening, so even edge redactions cover the source.
      graphics.setBlendMode(.clear)
      graphics.addRect(bounds)
      graphics.addPath(outline)
      graphics.drawPath(using: .eoFill)
    }
    guard let rendered = graphics.makeImage() else { return nil }
    return PNG.encode(rendered)
  }
}

extension MarkColor {
  public var cgColor: CGColor {
    switch self {
    case .red: return CGColor(srgbRed: 1, green: 0.22, blue: 0.1, alpha: 1)
    case .orange: return CGColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 1)
    case .yellow: return CGColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
    case .green: return CGColor(srgbRed: 0.2, green: 0.8, blue: 0.35, alpha: 1)
    case .blue: return CGColor(srgbRed: 0.1, green: 0.5, blue: 1, alpha: 1)
    case .white: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    case .black: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }
  }
}

#endif
