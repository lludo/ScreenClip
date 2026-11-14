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

  func testFollowUpReopensAMergedReportWithTheFeedback() throws {
    let (model, _) = try makeModel()
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Clipped",
      context: CaptureContext(), projectID: UUID(), existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    let firstWorkspace = try XCTUnwrap(model.issue(id)?.workspaceID)
    try model.updateIssue(id) {
      $0.prURL = "https://github.com/o/r/pull/1"
      $0.record("Merged", status: .merged)
    }
    try model.addContext(id, text: "Still clipped at narrow widths", followUp: true)
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .queued)
    XCTAssertNotEqual(issue.workspaceID, firstWorkspace, "A follow-up gets a fresh worktree")
    XCTAssertNil(issue.prURL)
    XCTAssertEqual(issue.contextNotes?.last?.text, "Still clipped at narrow widths")
    XCTAssertTrue(issue.activities.contains { $0.text == "Tester requested a follow-up" })
  }

  func testSidebarCountsFollowTheProjectFilter() throws {
    let (model, _) = try makeModel()
    let mine = UUID()
    let other = UUID()
    for project in [mine, other] {
      try model.submit(
        imageData: Data([1]), originalData: nil, annotations: [], note: "R",
        context: CaptureContext(), projectID: project, existingID: nil, draft: false)
    }
    let otherID = try XCTUnwrap(model.snapshot.issues.first { $0.projectID == other }?.id)
    try model.updateIssue(otherID) { $0.record("Merged", status: .merged) }
    XCTAssertEqual(model.snapshot.issues.filter { QueueFilter.retest.includes($0) }.count, 1)
    XCTAssertEqual(
      model.snapshot.issues.filter { QueueFilter.retest.includes($0, projectID: mine) }.count, 0)
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
