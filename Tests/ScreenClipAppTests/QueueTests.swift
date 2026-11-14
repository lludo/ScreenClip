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
}
