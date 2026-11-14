import AppKit
import ScreenClipCore
import XCTest

@testable import ScreenClip

final class AnnotationTests: XCTestCase {
  func image() throws -> NSImage {
    var bytes = [UInt8]()
    for y in 0..<100 {
      for _ in 0..<100 { bytes += y < 50 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    let cg = try XCTUnwrap(
      CGImage(
        width: 100, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 400,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return NSImage(cgImage: cg, size: NSSize(width: 100, height: 100))
  }
  func testPNGRenderPreservesImageOrientation() throws {
    let rep = try XCTUnwrap(
      NSBitmapImageRep(data: AnnotationRenderer.png(image: image(), marks: [])))
    let top = try XCTUnwrap(rep.colorAt(x: 50, y: 10)?.usingColorSpace(.deviceRGB))
    let bottom = try XCTUnwrap(rep.colorAt(x: 50, y: 90)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(top.redComponent, 0.9)
    XCTAssertLessThan(top.blueComponent, 0.1)
    XCTAssertGreaterThan(bottom.blueComponent, 0.9)
    XCTAssertLessThan(bottom.redComponent, 0.1)
  }
  func testRedactionIsOpaqueAndUsesTopLeftCoordinates() throws {
    let mark = Annotation(kind: .redact, points: [MarkPoint(0.1, 0.1), MarkPoint(0.4, 0.3)])
    let rep = try XCTUnwrap(
      NSBitmapImageRep(data: AnnotationRenderer.png(image: image(), marks: [mark])))
    let redacted = try XCTUnwrap(rep.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
    let untouched = try XCTUnwrap(rep.colorAt(x: 20, y: 80)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(redacted.alphaComponent, 1, accuracy: 0.001)
    XCTAssertLessThan(redacted.redComponent, 0.01)
    XCTAssertLessThan(redacted.greenComponent, 0.01)
    XCTAssertLessThan(redacted.blueComponent, 0.01)
    XCTAssertGreaterThan(untouched.blueComponent, 0.9)
  }
}
