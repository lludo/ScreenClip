import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class AppModelTests: XCTestCase {
  private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-model-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.settings.paused = true }
    return (model, root)
  }

  func testSavingTheSettingsFormKeepsTheCurrentPauseState() throws {
    let (model, _) = try makeModel()
    var form = model.snapshot.settings
    form.paused = true
    model.togglePaused()  // Resumed from the popover while Settings was open.
    XCTAssertFalse(model.snapshot.settings.paused)
    form.sessionName = "Beta"
    model.saveSettings(form)
    XCTAssertFalse(model.snapshot.settings.paused, "The stale form must not re-pause processing")
    XCTAssertEqual(model.snapshot.settings.sessionName, "Beta")
    model.togglePaused()
  }

  func testADraftCannotBeAddedToASubmittedIssue() throws {
    let (model, _) = try makeModel()
    let project = UUID()
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Submitted",
      context: CaptureContext(), projectID: project, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    XCTAssertThrowsError(
      try model.submit(
        imageData: Data([2]), originalData: nil, annotations: [], note: "Draft?",
        context: CaptureContext(), projectID: project, existingID: id, draft: true))
    XCTAssertEqual(model.issue(id)?.captures.count, 1)
    XCTAssertEqual(model.issue(id)?.revision, 1)
  }

  func testQueuedEvidenceCannotBeDeleted() throws {
    let (model, _) = try makeModel()
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Queued",
      context: CaptureContext(), projectID: UUID(), existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    XCTAssertEqual(model.issue(id)?.status, .queued)
    model.delete(id)
    XCTAssertNotNil(model.issue(id))
    XCTAssertNotNil(model.banner)
  }
}
