import ScreenClipCore
import XCTest

@testable import ScreenClip

final class QueueTests: XCTestCase {
  func testNumberSearchFindsReportsOutsideCurrentProjectAndStatusFilters() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-number-search-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try IssueStore(root: root)
    var state = StoreSnapshot()
    var issue = Issue(
      projectID: UUID(), title: "Clipped label",
      capture: Capture(note: "Details", imagePath: "/tmp/test.png", context: CaptureContext()))
    issue.archived = true
    issue.status = .verified
    state.issues = [issue]
    issue = try store.save(state).issues[0]
    let otherProject = UUID()
    XCTAssertFalse(QueueFilter.active.includes(issue))
    for filter in QueueFilter.allCases {
      XCTAssertTrue(filter.includes(issue, projectID: otherProject, search: "#1"))
      XCTAssertTrue(filter.includes(issue, projectID: otherProject, search: "1"))
      XCTAssertFalse(filter.includes(issue, projectID: otherProject, search: "#11"))
    }
    XCTAssertFalse(QueueFilter.active.includes(issue, search: "label"))
    XCTAssertFalse(QueueFilter.archived.includes(issue, projectID: otherProject, search: "label"))
    XCTAssertTrue(QueueFilter.archived.includes(issue, search: "label"))
  }

  func testProjectAndAgentFiltersCombine() {
    let project = UUID()
    let other = UUID()
    var issue = Issue(
      projectID: project, title: "Clipped label",
      capture: Capture(note: "Details", imagePath: "/tmp/test.png", context: CaptureContext()))
    issue.status = .needsYou
    issue.agent = .claude
    XCTAssertTrue(QueueFilter.active.includes(issue))
    XCTAssertTrue(QueueFilter.active.includes(issue, projectID: project))
    XCTAssertTrue(QueueFilter.active.includes(issue, agent: .claude))
    XCTAssertTrue(QueueFilter.active.includes(issue, projectID: project, agent: .claude))
    XCTAssertFalse(QueueFilter.active.includes(issue, agent: .codex))
    XCTAssertFalse(QueueFilter.active.includes(issue, projectID: other, agent: .claude))
    // Reports without a recorded agent count as Codex, matching how they are shown.
    issue.agent = nil
    XCTAssertTrue(QueueFilter.active.includes(issue, agent: .codex))
  }

  func testOpenReportPicksAListThatShowsIt() {
    let project = UUID()
    var issue = Issue(
      projectID: project, title: "DNA matches",
      capture: Capture(note: "Details", imagePath: "/tmp/test.png", context: CaptureContext()))
    issue.status = .needsYou
    XCTAssertEqual(QueueFilter.showing(issue), .active)
    // A merged report opened from a notification belongs in To retest, not All open.
    issue.status = .merged
    XCTAssertEqual(QueueFilter.showing(issue), .retest)
    XCTAssertEqual(QueueFilter.showing(issue, projectID: project), .retest)
    issue.status = .draft
    XCTAssertEqual(QueueFilter.showing(issue), .drafts)
    issue.status = .canceled
    XCTAssertEqual(QueueFilter.showing(issue), .history)
    issue.archived = true
    XCTAssertEqual(QueueFilter.showing(issue), .archived)
    // No status list shows it under another project's filter or a search that misses it.
    XCTAssertNil(QueueFilter.showing(issue, projectID: UUID()))
    XCTAssertNil(QueueFilter.showing(issue, search: "nothing like it"))
  }

  func testMenuBarCountsMatchTheQueueLists() {
    var state = StoreSnapshot()
    for status in IssueStatus.allCases {
      for archived in [false, true] {
        var issue = Issue(
          projectID: UUID(), title: "\(status)",
          capture: Capture(note: "Details", imagePath: "/tmp/test.png", context: CaptureContext()))
        issue.status = status
        issue.archived = archived
        state.issues.append(issue)
      }
    }
    // The menu bar badge and the popover use these counts; the sidebar counts its lists.
    XCTAssertEqual(state.issues.filter { QueueFilter.active.includes($0) }.count, state.activeCount)
    XCTAssertEqual(
      state.issues.filter { QueueFilter.attention.includes($0) }.count, state.attentionCount)
  }
}
