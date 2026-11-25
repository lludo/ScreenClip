import AppKit
import ScreenClipCore
import SwiftUI

@MainActor final class AnnotationDocument: ObservableObject {
  @Published var marks: [Annotation] = []
  @Published var tool: MarkKind = .pen
  @Published var color: MarkColor = .red
  @Published var lineWidth: Double = 0.006
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
      if !text.isEmpty {
        document.add(Annotation(kind: .text, points: [p], text: text, color: document.color))
      }
    } else {
      draft = Annotation(
        kind: document.tool, points: [p, p], color: document.color, lineWidth: document.lineWidth)
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
  /// Draws into the current, flipped AppKit context with the renderer shared with the iOS SDK.
  static func draw(_ marks: [Annotation], in rect: CGRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    AnnotationDrawing.draw(marks, in: rect, context: context)
  }
  static func png(image: NSImage, marks: [Annotation]) throws -> Data {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw ScreenClipError.message("Could not render the annotated image.")
    }
    guard let data = AnnotationDrawing.renderPNG(image: source, marks: marks) else {
      throw ScreenClipError.message("Could not encode the screenshot.")
    }
    return data
  }
}
extension MarkColor {
  var nsColor: NSColor { NSColor(cgColor: cgColor) ?? .systemOrange }
}
