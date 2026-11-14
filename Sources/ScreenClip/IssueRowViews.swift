import ScreenClipCore
import SwiftUI

struct IssueRow: View {
  let issue: Issue
  let project: Project?
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let image = issue.captures.first.flatMap({ NSImage(contentsOfFile: $0.imagePath) }) {
        Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 7))
      } else {
        Image(systemName: "photo").frame(width: 48, height: 48).background(
          .quaternary, in: RoundedRectangle(cornerRadius: 7))
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(issue.referencedTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
          if issue.unread { Circle().fill(.orange).frame(width: 6, height: 6) }
        }
        HStack(spacing: 8) {
          Text(project?.name ?? "Choose project").font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
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
      Text(status.title).font(.caption.weight(.medium))
    }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(
      color.opacity(0.10), in: Capsule())
  }
}
