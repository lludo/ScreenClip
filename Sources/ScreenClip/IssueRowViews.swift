import ScreenClipCore
import SwiftUI

/// Capture PNGs are written once under a fresh UUID name, so a path always names the same
/// image. Views re-render on every agent progress line; this keeps them off the disk.
@MainActor enum CaptureImageCache {
  private static let cache = NSCache<NSString, NSImage>()
  static func image(_ path: String) -> NSImage? {
    if let hit = cache.object(forKey: path as NSString) { return hit }
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    cache.setObject(image, forKey: path as NSString)
    return image
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
      if let image = issue.captures.first?.imagePath.flatMap(CaptureImageCache.image) {
        Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 7))
      } else {
        Image(systemName: issue.captures.first?.imagePath == nil ? "text.alignleft" : "photo").frame(width: 48, height: 48).background(
          .quaternary, in: RoundedRectangle(cornerRadius: 7))
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(issue.referencedTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
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
