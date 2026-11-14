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

  func testSavingSettingsKeepsDonationChoicesMadeWhileTheFormWasOpen() throws {
    let (model, _) = try makeModel()
    let launched = try XCTUnwrap(model.snapshot.settings.firstLaunchedAt)
    var form = model.snapshot.settings
    model.optOutOfDonationPrompt()
    form.sessionName = "Beta"
    model.saveSettings(form)
    XCTAssertEqual(model.snapshot.settings.donationOptOut, true)
    XCTAssertEqual(model.snapshot.settings.firstLaunchedAt, launched)
    XCTAssertEqual(model.snapshot.settings.sessionName, "Beta")
    XCTAssertFalse(model.shouldShowDonationPrompt())
  }

  func testThreeMergedFixesShowTheDonationPromptBeforeTheFirstWeek() throws {
    let (model, _) = try makeModel()
    let launched = try XCTUnwrap(model.snapshot.settings.firstLaunchedAt)
    XCTAssertFalse(model.shouldShowDonationPrompt(at: launched))
    for index in 0..<3 {
      try model.submit(
        imageData: Data([UInt8(index)]), originalData: nil, annotations: [], note: "Clipped",
        context: CaptureContext(), projectID: UUID(), existingID: nil, draft: false)
      let id = try XCTUnwrap(model.snapshot.issues.last?.id)
      try model.updateIssue(id) { $0.record("Merged", status: .merged) }
    }
    XCTAssertEqual(model.mergedFixCount(), 3)
    XCTAssertTrue(model.shouldShowDonationPrompt(at: launched))
    model.snoozeDonationPrompt(from: launched)
    XCTAssertFalse(model.shouldShowDonationPrompt(at: launched.addingTimeInterval(24 * 60 * 60)))
    XCTAssertTrue(
      model.shouldShowDonationPrompt(
        at: launched.addingTimeInterval(DonationPromptPolicy.snoozeInterval)))
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

  func testMovingAReportToAnotherProject() throws {
    let (model, root) = try makeModel()
    let wrong = Project(name: "ScreenClip", path: "/repos/ScreenClip")
    let right = Project(name: "Genealogy", path: "/repos/Genealogy")
    try model.commit { $0.projects = [wrong, right] }
    let image = root.appendingPathComponent("shot.png")
    try Data([1, 2, 3]).write(to: image)
    // Before agent work: the report is reassigned in place.
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Fresh",
      context: CaptureContext(), projectID: wrong.id, existingID: nil, draft: false)
    let fresh = try XCTUnwrap(model.snapshot.issues.last?.id)
    XCTAssertEqual(try model.moveToProject(fresh, projectID: right.id), fresh)
    XCTAssertEqual(model.issue(fresh)?.projectID, right.id)
    // After agent work started: canceled, and a copy carries the work under the new project.
    try model.submit(
      imageData: Data([4]), originalData: Data([5]), annotations: [], note: "Started",
      context: CaptureContext(appName: "Genealogy"), projectID: wrong.id, existingID: nil,
      draft: false)
    let started = try XCTUnwrap(model.snapshot.issues.last?.id)
    try model.addContext(started, text: "Extra detail")
    try model.updateIssue(started) {
      $0.threadID = "thread"
      $0.worktreePath = "/tmp/wt"
      $0.record("Question", status: .needsYou)
    }
    let movedID = try model.moveToProject(started, projectID: right.id)
    XCTAssertNotEqual(movedID, started)
    let old = try XCTUnwrap(model.issue(started))
    let moved = try XCTUnwrap(model.issue(movedID))
    XCTAssertEqual(old.status, .canceled)
    XCTAssertEqual(old.projectID, wrong.id)
    XCTAssertEqual(moved.projectID, right.id)
    XCTAssertEqual(moved.status, .queued)
    XCTAssertNil(moved.threadID)
    XCTAssertNil(moved.worktreePath)
    XCTAssertEqual(moved.title, old.title)
    XCTAssertEqual(moved.contextNotes?.map(\.text), ["Extra detail"])
    XCTAssertEqual(moved.captures.count, 1)
    XCTAssertNotEqual(moved.captures[0].imagePath, old.captures[0].imagePath)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: moved.captures[0].imagePath)), Data([4]))
    XCTAssertNotNil(moved.reportNumber)
    XCTAssertTrue(old.activities.contains { $0.text.hasPrefix("Moved to Genealogy as #") })
    XCTAssertEqual(model.selectedIssueID, movedID)
    // Active work must be canceled first.
    try model.updateIssue(movedID) { $0.record("Working", status: .working) }
    XCTAssertThrowsError(try model.moveToProject(movedID, projectID: wrong.id))
    // A report whose pull request is still in the old repository cannot move.
    try model.updateIssue(movedID) {
      $0.prURL = "https://github.com/owner/repo/pull/9"
      $0.record("CI still fails", status: .needsYou)
    }
    XCTAssertFalse(model.canMove(try XCTUnwrap(model.issue(movedID))))
    XCTAssertThrowsError(try model.moveToProject(movedID, projectID: wrong.id))
    XCTAssertEqual(model.issue(movedID)?.projectID, right.id)
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
