import AppKit
import XCTest

@testable import ScreenClip

@MainActor final class CaptureImageCacheTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func writePNG(width: Int, height: Int) throws -> String {
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let url = directory.appendingPathComponent("\(UUID().uuidString).png")
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    return url.path
  }

  /// A full Retina capture decodes to 10-20 MB. The queue row must not hold that for a 48 pt
  /// thumbnail, and the detail view must not hold more than it can draw.
  func testCapturesAreDownsampledToTheSizeTheyAreDrawnAt() throws {
    let path = try writePNG(width: 3024, height: 1964)

    let thumbnail = try XCTUnwrap(
      CaptureImageCache.downsampled(path, maxPixels: CaptureImageCache.thumbnailPixels))
    XCTAssertEqual(Int(thumbnail.image.size.width), CaptureImageCache.thumbnailPixels)
    XCTAssertLessThan(thumbnail.bytes, 300_000)

    let detail = try XCTUnwrap(
      CaptureImageCache.downsampled(path, maxPixels: CaptureImageCache.detailPixels))
    XCTAssertEqual(Int(detail.image.size.width), CaptureImageCache.detailPixels)
    XCTAssertLessThan(detail.bytes, 3024 * 1964 * 4 / 2)
  }

  func testSmallCapturesAreNotUpscaled() throws {
    let path = try writePNG(width: 120, height: 80)
    let image = try XCTUnwrap(CaptureImageCache.thumbnail(path))
    XCTAssertEqual(image.size, NSSize(width: 120, height: 80))
  }

  func testRowAndDetailSizesAreCachedSeparately() throws {
    let path = try writePNG(width: 2000, height: 1000)
    let thumbnail = try XCTUnwrap(CaptureImageCache.thumbnail(path))
    let detail = try XCTUnwrap(CaptureImageCache.image(path))
    XCTAssertEqual(Int(thumbnail.size.width), CaptureImageCache.thumbnailPixels)
    XCTAssertEqual(Int(detail.size.width), CaptureImageCache.detailPixels)
    XCTAssertTrue(CaptureImageCache.thumbnail(path) === thumbnail)
  }

  func testMissingFileHasNoImage() {
    XCTAssertNil(CaptureImageCache.thumbnail(directory.appendingPathComponent("gone.png").path))
  }
}
