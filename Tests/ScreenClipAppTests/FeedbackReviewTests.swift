import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class FeedbackReviewTests: XCTestCase {
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
