import ImageIO
import ScreenClipCore
import SwiftUI

/// Capture PNGs are written once under a fresh UUID name, so a path always names the same
/// image. Views re-render on every agent progress line; this keeps them off the disk.
///
/// A decoded capture costs 10-20 MB, so images are downsampled to the size they are drawn at
/// and the cache is capped. Holding full captures here once grew the app past 1 GB.
@MainActor enum CaptureImageCache {
  /// Longest side, in pixels, of a queue-row thumbnail. The row draws a 48 pt square crop, so
  /// this leaves the short side sharp at 2x for captures up to about 2.6:1.
  static let thumbnailPixels = 256
  /// Longest side, in pixels, of a capture in the report detail, which is at most 420 pt tall.
  static let detailPixels = 1680
  static let costLimit = 96 * 1024 * 1024

  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = costLimit
    return cache
  }()

  static func thumbnail(_ path: String) -> NSImage? { image(path, maxPixels: thumbnailPixels) }
  static func image(_ path: String) -> NSImage? { image(path, maxPixels: detailPixels) }

  private static func image(_ path: String, maxPixels: Int) -> NSImage? {
    let key = "\(maxPixels):\(path)" as NSString
    if let hit = cache.object(forKey: key) { return hit }
    guard let decoded = downsampled(path, maxPixels: maxPixels) else { return nil }
    cache.setObject(decoded.image, forKey: key, cost: decoded.bytes)
    return decoded.image
  }

  /// Decodes `path` no larger than `maxPixels` on its longest side, never upscaling.
  nonisolated static func downsampled(_ path: String, maxPixels: Int) -> (image: NSImage, bytes: Int)? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return (
      NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
      image.bytesPerRow * image.height
    )
  }
}

extension View {
  /// The rounded panel used for report sections and question cards.
  func card(_ fill: some ShapeStyle) -> some View {
    padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(fill, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct IssueRow: View {
  let issue: Issue
  let project: Project?
  @Environment(\.locale) private var locale
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let image = issue.captures.first?.imagePath.flatMap(CaptureImageCache.thumbnail) {
        Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 7))
      } else {
        Image(systemName: issue.captures.first?.imagePath == nil ? "text.alignleft" : "photo").frame(width: 48, height: 48).background(
          .quaternary, in: RoundedRectangle(cornerRadius: 7))
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(issue.referencedTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
          if issue.isFromIOS { IOSSourceIcon().font(.system(size: 11)) }
          if issue.unread { Circle().fill(.orange).frame(width: 6, height: 6) }
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label {
            Text(verbatim: project?.name ?? Chrome.text(
              "Choose project", locale: locale, comment: "Shown on a report row that has no project yet."))
              .lineLimit(1)
          } icon: {
            Image(systemName: project?.displaySymbol ?? "questionmark.folder")
          }
          .font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          StatusBadge(status: issue.status).fixedSize()
        }
      }
      Spacer(minLength: 0)
    }.padding(.vertical, 9)
  }
}
struct StatusBadge: View {
  let status: IssueStatus
  @Environment(\.locale) private var locale
  var color: Color {
    switch status {
    case .working: return .blue
    case .needsProject, .needsYou, .failed: return .orange
    case .merged, .verified: return .green
    default: return .secondary
    }
  }
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(verbatim: status.localizedTitle(locale: locale)).font(.caption.weight(.medium))
        .fixedSize(horizontal: true, vertical: true)
    }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(
      color.opacity(0.10), in: Capsule())
  }
}

/// Marks a report captured in an iOS app with ScreenClipKit.
struct IOSSourceIcon: View {
  @Environment(\.locale) private var locale
  var body: some View {
    let label = Chrome.text("Captured on iOS", locale: locale, comment: "Marks a report sent from an iOS app.")
    Image(systemName: "iphone").foregroundStyle(.secondary)
      .help(label).accessibilityLabel(Text(verbatim: label))
  }
}
