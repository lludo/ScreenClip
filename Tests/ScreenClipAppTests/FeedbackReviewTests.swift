import AppKit
import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class FeedbackReviewTests: XCTestCase {
  func testImageOnlyQueuedReportAcceptsDurableSearchableContextWithoutAnotherCapture() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    let issue = Issue(
      projectID: UUID(), title: "Observation in Test",
      capture: Capture(note: "", imagePath: "/tmp/test.png", context: CaptureContext()))
    try model.commit {
      $0.settings.paused = true
      $0.issues = [issue]
    }
    let original = try XCTUnwrap(model.issue(issue.id))
    try model.addContext(issue.id, text: "  The button is clipped.\nOnly at narrow widths.  ")
    try model.addContext(issue.id, text: "It also happens in the settings window.")
    let saved = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(
      saved.contextNotes?.map(\.text),
      [
        "The button is clipped.\nOnly at narrow widths.",
        "It also happens in the settings window.",
      ])
    XCTAssertEqual(saved.status, .queued)
    XCTAssertEqual(saved.revision, original.revision + 2)
    XCTAssertEqual(saved.coveredRevision, original.coveredRevision)
    XCTAssertEqual(saved.reportNumber, original.reportNumber)
    XCTAssertEqual(saved.captures, original.captures)
    XCTAssertEqual(saved.workspaceID, original.workspaceID)
    XCTAssertEqual(model.snapshot.issues.count, 1)
    XCTAssertTrue(QueueFilter.active.includes(saved, search: "NARROW WIDTHS"))
    XCTAssertEqual(try model.store.load().issues[0], saved)
    var withLongActivity = saved
    for _ in 0..<501 { withLongActivity.record("Progress") }
    XCTAssertEqual(withLongActivity.contextNotes, saved.contextNotes)
  }

  func testContextImagePersistsAndIsDeliveredWithFollowUpEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    var issue = Issue(
      projectID: UUID(), title: "Report",
      capture: Capture(note: "", imagePath: "/tmp/test.png", context: CaptureContext()))
    issue.status = .working
    issue.threadID = "existing-chat"
    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "existing-chat")
    try model.commit {
      $0.settings.paused = true
      $0.issues = [issue]
    }
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2,
        pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try model.addContext(issue.id, text: "", images: [data])
    let saved = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(saved.status, .working)
    XCTAssertEqual(saved.revision, issue.revision + 1)
    XCTAssertEqual(saved.captures.count, 2)
    let attachment = try XCTUnwrap(saved.captures.last)
    XCTAssertNotNil(NSImage(contentsOfFile: try XCTUnwrap(attachment.imagePath)))
    XCTAssertEqual(attachment.context.selection, [0, 0, 2, 2])
    XCTAssertEqual(try model.store.load().issues.first, saved)
    let project = Project(name: "Test", path: root.path)
    let turn = AgentPrompt.turn(for: saved, project: project, threadID: "existing-chat")
    XCTAssertEqual(turn.captures.map(\.id), [attachment.id])

    let assets = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("assets").path)
    XCTAssertThrowsError(
      try model.addContext(issue.id, text: "Bad", images: [data, Data("invalid".utf8)]))
    XCTAssertThrowsError(try model.addContext(UUID(), text: "Missing", images: [data]))
    XCTAssertEqual(model.issue(issue.id), saved)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("assets").path), assets)
  }

  func testDraftSubmissionKeepsContextAttachments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2,
        pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let original = try model.store.writeAsset(data)
    let issue = Issue(
      projectID: nil, title: "Draft",
      capture: Capture(note: "", imagePath: original, context: CaptureContext()), draft: true)
    try model.commit {
      $0.settings.paused = true
      $0.issues = [issue]
    }
    try model.addContext(issue.id, text: "", images: [data])
    let attachment = try XCTUnwrap(model.issue(issue.id)?.captures.last)
    XCTAssertEqual(model.issue(issue.id)?.status, .draft)
    try model.submit(
      imageData: data, originalData: nil, annotations: [], note: "Submit",
      context: CaptureContext(), projectID: nil, existingID: issue.id, draft: false)
    let saved = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(saved.captures.count, 2)
    XCTAssertEqual(saved.captures.last, attachment)
    XCTAssertNotNil(NSImage(contentsOfFile: try XCTUnwrap(attachment.imagePath)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original))
  }

  func testContextRejectsEmptyTextAndMissingReportsWithoutChangingTheQueue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    let issue = Issue(
      projectID: nil, title: "Report",
      capture: Capture(note: "", imagePath: "/tmp/test.png", context: CaptureContext()))
    try model.commit { $0.issues = [issue] }
    let original = model.snapshot.issues
    XCTAssertThrowsError(try model.addContext(issue.id, text: " \n\t "))
    XCTAssertThrowsError(try model.addContext(UUID(), text: "Missing report"))
    XCTAssertEqual(model.snapshot.issues, original)
    XCTAssertEqual(try model.store.load().issues, original)
  }

  func testLegacyReportsCanAddContextAndPreserveActiveWorkAndPendingQuestions() throws {
    let original = Issue(
      projectID: UUID(), title: "Report",
      capture: Capture(note: "", imagePath: "/tmp/test.png", context: CaptureContext()))
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "contextNotes")
    let legacy = try JSONDecoder().decode(
      Issue.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(legacy.contextNotes)
    for status in [IssueStatus.draft, .queued, .working, .needsYou, .needsProject] {
      var issue = legacy
      issue.status = status
      if status == .needsProject { issue.projectID = nil }
      issue.threadID = "existing-chat"
      issue.turnID = "active-turn"
      issue.coveredRevision = 1
      issue.dispatchUncertain = true
      issue.questions = [PendingQuestion(title: "Allow?", requestID: .number(12))]
      issue.addContext("Forgotten details")
      XCTAssertEqual(issue.status, status)
      XCTAssertEqual(issue.threadID, "existing-chat")
      XCTAssertEqual(issue.turnID, "active-turn")
      XCTAssertEqual(issue.coveredRevision, 1)
      XCTAssertEqual(issue.revision, 2)
      XCTAssertTrue(issue.dispatchUncertain)
      XCTAssertNil(issue.questions[0].reply)
      XCTAssertEqual(issue.contextNotes?.first?.text, "Forgotten details")
    }
  }

  func testContextReopensCompletedReportsWithFreshWorkspaceAndSameConversation() {
    for status in [IssueStatus.merged, .verified] {
      var issue = Issue(
        projectID: UUID(), title: "Report",
        capture: Capture(note: "", imagePath: "/tmp/test.png", context: CaptureContext()))
      let workspaceID = issue.workspaceID
      issue.status = status
      issue.archived = true
      issue.threadID = "existing-chat"
      issue.prURL = "https://github.com/example/repo/pull/1"
      issue.worktreePath = "/tmp/previous-workspace"
      issue.addContext("Another detail")
      XCTAssertEqual(issue.status, .queued)
      XCTAssertFalse(issue.archived)
      XCTAssertEqual(issue.threadID, "existing-chat")
      XCTAssertNotEqual(issue.workspaceID, workspaceID)
      XCTAssertNil(issue.worktreePath)
      XCTAssertNil(issue.prURL)
      XCTAssertTrue(issue.activities.contains { $0.text.contains("Previous fix:") })
    }
  }

  func testFeedbackSearchIncludesFollowupsRepliesResultsAndActivity() {
    var issue = Issue(
      projectID: nil, title: "Capture layout",
      capture: Capture(
        note: "Original feedback", imagePath: "/tmp/test.png", context: CaptureContext()))
    issue.captures.append(
      Capture(note: "Followup alignment", imagePath: "/tmp/second.png", context: CaptureContext()))
    var question = PendingQuestion(title: "Should the toolbar wrap?")
    question.reply = "Keep the controls together"
    issue.questions = [question]
    issue.resultSummary = "Removed the translucent strip"
    issue.record("Validated the compact layout")
    for query in [
      " CAPTURE ", "original feedback", "FOLLOWUP ALIGNMENT", "toolbar wrap",
      "controls together", "translucent strip", "compact layout", "  ",
    ] {
      XCTAssertTrue(issue.matchesFeedback(query), query)
    }
    XCTAssertFalse(issue.matchesFeedback("unrelated text"))
  }

  func testArchivePreservesEvidenceAndStatusAndCanBeRestored() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    var issue = Issue(
      projectID: nil, title: "Verified report",
      capture: Capture(
        note: "Keep this feedback", imagePath: "/tmp/test.png", context: CaptureContext()))
    issue.status = .verified
    issue.prURL = "https://github.com/example/repo/pull/1"
    issue.mergeCommit = "tested-merge"
    try model.commit { $0.issues = [issue] }
    model.setArchived(issue.id, archived: true)
    let archived = try XCTUnwrap(model.issue(issue.id))
    XCTAssertTrue(archived.archived)
    XCTAssertEqual(archived.captures, issue.captures)
    XCTAssertEqual(archived.status, .verified)
    XCTAssertEqual(archived.prURL, issue.prURL)
    XCTAssertEqual(archived.mergeCommit, issue.mergeCommit)
    XCTAssertFalse(QueueFilter.active.includes(archived))
    XCTAssertTrue(QueueFilter.archived.includes(archived))
    XCTAssertTrue(try model.store.load().issues[0].archived)
    model.setArchived(issue.id, archived: false)
    XCTAssertFalse(try XCTUnwrap(model.issue(issue.id)).archived)
    XCTAssertFalse(try model.store.load().issues[0].archived)
  }

  func testActiveWorkAndOutstandingRequestsCannotBeHiddenInArchive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    var issue = Issue(
      projectID: nil, title: "Active report",
      capture: Capture(note: "Feedback", imagePath: "/tmp/test.png", context: CaptureContext()))
    for status in [IssueStatus.queued, .working, .prOpen] {
      issue.status = status
      try model.commit { $0.issues = [issue] }
      model.setArchived(issue.id, archived: true)
      XCTAssertFalse(try XCTUnwrap(model.issue(issue.id)).archived)
      XCTAssertNotNil(model.banner)
    }
    issue.status = .needsYou
    issue.questions = [PendingQuestion(title: "Permission?", requestID: .number(1))]
    XCTAssertFalse(issue.canArchive)
    issue.questions[0].reply = "Answered"
    XCTAssertTrue(issue.canArchive)
    issue.dispatchUncertain = true
    XCTAssertFalse(issue.canArchive)
  }
}
