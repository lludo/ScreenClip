import Foundation
import ScreenClipCore

/// Loads the checked-in queue snapshot into a temporary directory. Never reads or writes
/// `~/Library/Application Support/ScreenClip`.
enum ScreenshotFixture {
  /// November 14, 2026, 12:40 PM Pacific (20:40 UTC), as seconds since the Apple reference date.
  static let frozenNow = Date(timeIntervalSinceReferenceDate: 816_381_600)
  static let timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
  /// Absolute prefix stored in the fixture. Rewritten only for image paths in the temporary copy.
  static let storedRootPrefix = "/Users/ludo/Library/Application Support/ScreenClip/"

  static func sourceURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/ScreenshotData")
  }

  /// Copies the fixture, rewrites screenshot paths to that copy, and skips crash recovery.
  static func materialize() throws -> URL {
    let source = sourceURL()
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("screenclip-screenshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for name in ["screenclip.sqlite", "assets", "originals", "runs"] {
      let from = source.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: from.path) else { continue }
      try FileManager.default.copyItem(at: from, to: destination.appendingPathComponent(name))
    }
    let model = try AppModel(root: destination, recoverInterruptedWork: false)
    let replacement = destination.path + "/"
    try model.commit { state in
      for issueIndex in state.issues.indices {
        for captureIndex in state.issues[issueIndex].captures.indices {
          state.issues[issueIndex].captures[captureIndex].imagePath = state.issues[issueIndex]
            .captures[captureIndex].imagePath.replacingOccurrences(
              of: storedRootPrefix, with: replacement)
          if let original = state.issues[issueIndex].captures[captureIndex].originalPath {
            state.issues[issueIndex].captures[captureIndex].originalPath = original
              .replacingOccurrences(of: storedRootPrefix, with: replacement)
          }
        }
      }
    }
    return destination
  }

  /// Deterministic chrome for screenshots: Codex connected, Claude Code ready, Grok Bot not configured.
  static func configure(_ model: AppModel) {
    model.applyScreenshotAgentStatus()
    model.loadExternalAssistant = { .empty }
    model.capturePermission.applyScreenshotReady()
    model.banner = nil
    if let report = model.snapshot.issues.first(where: { $0.reportNumber == 26 }) {
      model.selectedIssueID = report.id
    }
  }
}
