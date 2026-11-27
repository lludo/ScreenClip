import XCTest

@testable import ScreenClipCore

final class ExternalFixTests: XCTestCase {
  func testReportNumbersAreWholeNumbersAfterScreenClip() {
    XCTAssertEqual(ExternalFix.reportNumbers(in: "Load the DNA mapping sheet (ScreenClip #153)"), [153])
    XCTAssertEqual(
      ExternalFix.reportNumbers(in: "Swipe the person panel away (ScreenClip #141, #143)"), [141, 143])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip #7 and #8 & #9"), [7, 8, 9])
    // A tester's question copied into a title, and text that explains the convention, fix nothing.
    XCTAssertEqual(ExternalFix.reportNumbers(in: "is the screenclip #98 and #94 fully merged and fixed?"), [])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "Lists like `ScreenClip #141, #143` count too"), [])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "Fix it\n> ScreenClip #5 is still broken\n```\nScreenClip #6\n```"), [])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip #144\n\n**What was wrong**"), [144])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip report: #136\nIssue ID: x"), [136])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip: #12"), [12])
    // Never a prefix of a longer number, another product, or a bare list without the name.
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip #1360"), [1360])
    XCTAssertFalse(ExternalFix.reportNumbers(in: "ScreenClip #1360").contains(136))
    XCTAssertEqual(ExternalFix.reportNumbers(in: "Depend on ScreenClipKit #136"), [])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "Close the gaps the ScreenClip reports found (#34, #136)"), [])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip 136"), [])
    XCTAssertEqual(ExternalFix.reportNumbers(in: "ScreenClip #0"), [])
  }

  func testPullRequestNumberOnlyForTheProjectRepository() {
    XCTAssertEqual(
      ExternalFix.pullRequestNumber("https://github.com/lludo/Genealogy/pull/1850", repo: "lludo/genealogy"),
      1850)
    for url in [
      "https://github.com/someone/Genealogy/pull/1850", "http://github.com/lludo/Genealogy/pull/1850",
      "https://github.com.example.net/lludo/Genealogy/pull/1850",
      "https://github.com/lludo/Genealogy/issues/1850", "https://github.com/lludo/Genealogy/pull/1850/files",
      "https://github.com/lludo/Genealogy/pull/18a", "https://github.com/lludo/Genealogy/pull/1850?x=1",
    ] {
      XCTAssertNil(ExternalFix.pullRequestNumber(url, repo: "lludo/Genealogy"), url)
    }
  }

  private func issue(number: Int, status: IssueStatus) -> Issue {
    var context = CaptureContext()
    context.capturedAt = Date(timeIntervalSince1970: 1000)
    var issue = Issue(
      projectID: UUID(), title: "Report", capture: Capture(note: "x", imagePath: nil, context: context))
    issue.createdAt = Date(timeIntervalSince1970: 1000)
    issue.reportNumber = number
    issue.status = status
    return issue
  }

  private func merged(
    _ number: Int, title: String, body: String = "", repo: String = "lludo/Genealogy",
    base: String = "main", at time: TimeInterval = 2000
  ) -> MergedPullRequest {
    MergedPullRequest(
      url: "https://github.com/\(repo)/pull/\(number)", title: title, body: body,
      headRefName: "claude/fix", baseRefName: base, mergedAt: Date(timeIntervalSince1970: time),
      mergeCommit: "abc")
  }

  func testFixNeedsAMergeIntoTheBaseOfTheSameRepositoryAfterTheLatestEvidence() {
    let report = issue(number: 136, status: .failed)
    let fix = { (prs: [MergedPullRequest]) in
      ExternalFix.fix(for: report, in: prs, repo: "lludo/Genealogy", base: "main")?.url
    }
    XCTAssertEqual(fix([merged(1846, title: "Keep cards apart (ScreenClip #136)")]),
      "https://github.com/lludo/Genealogy/pull/1846")
    XCTAssertEqual(fix([merged(1846, title: "Fix", body: "ScreenClip #136\n\nDetails")]),
      "https://github.com/lludo/Genealogy/pull/1846")
    XCTAssertNil(fix([merged(1, title: "Fix (ScreenClip #1360)")]))
    XCTAssertNil(fix([merged(1, title: "Fix (ScreenClip #13)")]))
    XCTAssertNil(fix([merged(1, title: "Fix (ScreenClip #136)", repo: "someone/Genealogy")]))
    XCTAssertNil(fix([merged(1, title: "Fix (ScreenClip #136)", base: "release")]))
    XCTAssertNil(fix([merged(1, title: "Fix (ScreenClip #136)", at: 500)]), "merged before the evidence")
    // The earliest merge after the evidence is the fix; a later follow-up is not.
    XCTAssertEqual(
      fix([merged(2, title: "Follow-up (ScreenClip #136)", at: 3000), merged(1, title: "Fix (ScreenClip #136)")]),
      "https://github.com/lludo/Genealogy/pull/1")
  }

  func testOnlyStoppedOrQueuedReportsCanBeClosed() {
    let pr = [merged(1846, title: "Fix (ScreenClip #136)")]
    for status in IssueStatus.allCases {
      let found = ExternalFix.fix(
        for: issue(number: 136, status: status), in: pr, repo: "lludo/Genealogy", base: "main")
      XCTAssertEqual(found != nil, [.needsYou, .failed, .queued].contains(status), status.rawValue)
    }
    var archived = issue(number: 136, status: .failed)
    archived.archived = true
    XCTAssertFalse(ExternalFix.canClose(archived))
    var uncertain = issue(number: 136, status: .needsYou)
    uncertain.dispatchUncertain = true
    XCTAssertFalse(ExternalFix.canClose(uncertain))
  }

  func testIssueIDLinesIdentifyTheReportExactly() {
    let id = UUID()
    let body = "Fix\n\nScreenClip report: #12\nIssue ID: \(id.uuidString)\nInput revision: 1"
    XCTAssertEqual(ExternalFix.issueIDs(in: body), [id])
    XCTAssertEqual(ExternalFix.issueIDs(in: "Issue ID: not-a-uuid"), [])
    // Another Mac's ScreenClip PR names its own report #136; only the issue ID decides.
    let report = issue(number: 136, status: .failed)
    let other = merged(9, title: "Fix", body: "ScreenClip report: #136\nIssue ID: \(UUID().uuidString)")
    XCTAssertNil(ExternalFix.fix(for: report, in: [other], repo: "lludo/Genealogy", base: "main"))
    let own = merged(10, title: "Fix", body: "ScreenClip report: #1\nIssue ID: \(report.id.uuidString)")
    XCTAssertNotNil(ExternalFix.fix(for: report, in: [own], repo: "lludo/Genealogy", base: "main"))
  }
}
