// On iOS this module is part of ScreenClipKit and compiles to nothing outside Debug builds.
#if !os(iOS) || DEBUG

import Foundation

// Shared by the macOS app and the iOS SDK. The Codable shape is stored in the macOS queue,
// so field names and enum raw values must not change.

public enum MarkKind: String, Codable, CaseIterable, Sendable {
  case pen, arrow, rectangle, ellipse, text, redact
}
public enum MarkColor: String, Codable, CaseIterable, Sendable {
  case red, orange, yellow, green, blue, white, black
}
public struct MarkPoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public init(_ x: Double, _ y: Double) {
    self.x = x
    self.y = y
  }
}
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var kind: MarkKind
  public var points: [MarkPoint]
  public var text: String
  // Optional style keeps captures from earlier versions readable. Width is a fraction of image width.
  public var color: MarkColor?
  public var lineWidth: Double?
  public init(
    kind: MarkKind, points: [MarkPoint], text: String = "", color: MarkColor? = nil,
    lineWidth: Double? = nil
  ) {
    id = UUID()
    self.kind = kind
    self.points = points
    self.text = text
    self.color = color
    self.lineWidth = lineWidth
  }
}

#endif
