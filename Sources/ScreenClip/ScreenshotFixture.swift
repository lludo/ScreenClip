import Foundation
import ScreenClipCore

/// Creates an isolated screenshot queue containing only synthetic preview data.
@MainActor enum ScreenshotFixture {
  static let frozenNow = Date(timeIntervalSinceReferenceDate: 816_381_600)
  static let timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt

  static func materialize() throws -> URL {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("screenclip-screenshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let model = try AppModel(root: destination, recoverInterruptedWork: false)
    try PreviewSupport.seed(model: model)
    return destination
  }

  static func configure(_ model: AppModel) {
    model.applyScreenshotAgentStatus()
    model.loadExternalAssistant = { .empty }
    model.capturePermission.applyScreenshotReady()
    model.banner = nil
    model.selectedIssueID = model.snapshot.issues.first(where: { $0.status == .needsYou })?.id
  }
}
