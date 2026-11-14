import AppKit
import ScreenClipCore
import SwiftUI

@MainActor final class AnnotationDocument: ObservableObject {
  @Published var marks: [Annotation] = []
  @Published var tool: MarkKind = .arrow
  @Published var text = ""
  private var redoMarks: [Annotation] = []
  func add(_ mark: Annotation) {
    marks.append(mark)
    redoMarks.removeAll()
  }
  func undo() { if let mark = marks.popLast() { redoMarks.append(mark) } }
  func redo() { if let mark = redoMarks.popLast() { marks.append(mark) } }
  var canRedo: Bool { !redoMarks.isEmpty }
}
struct AnnotationCanvas: NSViewRepresentable {
  let image: NSImage
  @ObservedObject var document: AnnotationDocument
  func makeNSView(context: Context) -> AnnotationView {
    let view = AnnotationView()
    view.image = image
    view.document = document
    return view
  }
  func updateNSView(_ view: AnnotationView, context: Context) {
    view.document = document
    view.needsDisplay = true
  }
}
final class AnnotationView: NSView {
  var image = NSImage()
  weak var document: AnnotationDocument?
  private var draft: Annotation?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  var imageRect: CGRect {
    guard image.size.width > 0, image.size.height > 0 else { return bounds }
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
      height: size.height)
  }
  private func point(_ event: NSEvent) -> MarkPoint {
    let p = convert(event.locationInWindow, from: nil)
    let rect = imageRect
    return MarkPoint(
      max(0, min(1, (p.x - rect.minX) / rect.width)),
      max(0, min(1, (p.y - rect.minY) / rect.height)))
  }
  override func mouseDown(with event: NSEvent) {
    guard let document, imageRect.contains(convert(event.locationInWindow, from: nil)) else {
      return
    }
    let p = point(event)
    if document.tool == .text {
      let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { document.add(Annotation(kind: .text, points: [p], text: text)) }
    } else {
      draft = Annotation(kind: document.tool, points: [p, p])
    }
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard var mark = draft else { return }
    if mark.kind == .pen { mark.points.append(point(event)) } else { mark.points[1] = point(event) }
    draft = mark
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    if let draft { document?.add(draft) }
    draft = nil
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    bounds.fill()
    image.draw(
      in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: nil)
    AnnotationRenderer.draw((document?.marks ?? []) + (draft.map { [$0] } ?? []), in: imageRect)
  }
}
enum AnnotationRenderer {
  static func draw(_ marks: [Annotation], in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: rect).addClip()
    defer { NSGraphicsContext.restoreGraphicsState() }
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
      NSColor.systemOrange.setStroke()
      NSColor.systemOrange.setFill()
      let path = NSBezierPath()
      path.lineWidth = max(2, rect.width / 350)
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      switch mark.kind {
      case .redact:
        NSColor.black.setFill()
        box.integral.fill()
      case .rectangle:
        path.appendRect(box)
        path.stroke()
      case .pen:
        path.move(to: start)
        for point in mark.points.dropFirst() { path.line(to: p(point)) }
        path.stroke()
      case .arrow:
        path.move(to: start)
        path.line(to: end)
        path.stroke()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(12, rect.width / 40)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(
          to: CGPoint(x: end.x - length * cos(angle - 0.45), y: end.y - length * sin(angle - 0.45)))
        head.line(
          to: CGPoint(x: end.x - length * cos(angle + 0.45), y: end.y - length * sin(angle + 0.45)))
        head.close()
        head.fill()
      case .text:
        let font = NSFont.systemFont(ofSize: max(16, rect.width / 40), weight: .semibold)
        mark.text.draw(
          at: start,
          withAttributes: [
            .font: font, .foregroundColor: NSColor.systemOrange,
            .backgroundColor: NSColor.black.withAlphaComponent(0.8),
          ])
      }
    }
  }
  static func png(image: NSImage, marks: [Annotation]) throws -> Data {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let graphics = CGContext(
        data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
        bytesPerRow: source.width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ScreenClipError.message("Could not render the annotated image.") }
    NSGraphicsContext.saveGraphicsState()
    let size = CGSize(width: source.width, height: source.height)
    graphics.draw(source, in: CGRect(origin: .zero, size: size))
    graphics.translateBy(x: 0, y: size.height)
    graphics.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: true)
    draw(marks, in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = graphics.makeImage(),
      let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    else { throw ScreenClipError.message("Could not encode the screenshot.") }
    return data
  }
}
