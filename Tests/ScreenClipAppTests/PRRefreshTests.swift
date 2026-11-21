import XCTest

@testable import ScreenClip
@testable import ScreenClipCore

/// Watching an open pull request must not start agent work on evidence that is not about the
/// fix in the worktree: checks for another head, a failed fetch, or a report that has moved on.
@MainActor final class PRRefreshTests: XCTestCase {
  private var root: URL!
  private var model: AppModel!
  private var id: UUID!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-refresh-" + UUID().uuidString)
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    // A repository without an `origin`, so every fetch fails the way a dropped network does.
    for arguments in [
      ["init", "-q", "-b", "main"],
      ["-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid", "commit", "-q",
       "--allow-empty", "-m", "initial"],
    ] {
      let git = Process()
      git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      git.arguments = arguments
      git.currentDirectoryURL = repo
      try git.run()
      git.waitUntilExit()
    }
    // A stand-in `gh` that answers every call with the pull request state the test wrote.
    let gh = root.appendingPathComponent("gh")
    try "#!/bin/sh\ncat \"$(dirname \"$0\")/state.json\"\n".write(
      to: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path, validationCommand: "true")
    try model.saveProject(project)
    try model.commit {
      $0.settings.paused = true
      $0.settings.ghPath = gh.path
    }
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(),
      projectID: project.id, existingID: nil, draft: false)
    id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.commit { $0.settings.paused = false }
    try model.updateIssue(id) {
      $0.agent = .claude
      $0.status = .prOpen
      $0.coveredRevision = $0.revision
      $0.worktreePath = repo.path
      $0.branch = "main"
      $0.prURL = "https://github.com/example/app/pull/1"
      $0.prHead = "pushed"
    }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func pullRequest(_ fields: [String: JSONValue]) throws {
    var state: [String: JSONValue] = [
      "url": .string("https://github.com/example/app/pull/1"), "headRefOid": .string("pushed"),
      "baseRefName": .string("main"), "state": .string("OPEN"),
    ]
    state.merge(fields) { _, new in new }
    try JSONEncoder().encode(JSONValue.object(state)).write(
      to: root.appendingPathComponent("state.json"))
  }

  private let failedChecks = JSONValue.array([.object(["conclusion": .string("FAILURE")])])

  func testFailedChecksForAnotherHeadDoNotStartARepair() async throws {
    try pullRequest(["headRefOid": .string("someone-else"), "statusCheckRollup": failedChecks])
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.issue(id)?.status, .prOpen)
    XCTAssertNil(model.issue(id)?.repairAttempts)
    XCTAssertEqual(
      model.issue(id)?.checkSummary, "The PR changed; run validation again before merging.")

    // Control: the same failure on the head ScreenClip pushed is handed back to the agent.
    try pullRequest(["statusCheckRollup": failedChecks])
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.issue(id)?.status, .queued)
    XCTAssertEqual(model.issue(id)?.repairAttempts, 1)
  }

  func testAFailedFetchLeavesTheReportOpenForTheNextRefresh() async throws {
    try pullRequest(["mergeable": .string("CONFLICTING")])
    await model.worker.refreshPR(id)
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .prOpen)
    XCTAssertNil(issue.repairAttempts)
    XCTAssertNil(issue.validationFeedback)
    XCTAssertNotNil(issue.lastError)
  }

  func testAReportThatLeftPROpenIsNotRefreshed() async throws {
    try pullRequest(["state": .string("MERGED")])
    try model.updateIssue(id) { $0.record("Canceled", status: .canceled) }
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.issue(id)?.status, .canceled)
    XCTAssertNil(model.issue(id)?.mergeCommit)
  }

  func testAPullRequestMergedOnGitHubCompletesAReportThatNeedsYou() async throws {
    // Stopped on a base conflict; the tester resolved and merged the pull request by hand.
    try model.updateIssue(id) {
      $0.worktreePath = nil
      $0.checkSummary = "The base branch conflicts with this fix."
      $0.lastError = "The base branch conflicts with this fix in: App.swift"
      $0.questions.append(PendingQuestion(title: "Resolve the conflict?"))
      $0.record("The base update needs attention in Claude Code.", status: .needsYou)
    }
    try pullRequest(["state": .string("OPEN"), "mergeable": .string("CONFLICTING")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)

    try pullRequest(["state": .string("MERGED"), "mergeCommit": .object(["oid": .string("abc123")])])
    await model.worker.refreshPRs()
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .merged)
    XCTAssertEqual(issue.mergeCommit, "abc123")
    XCTAssertNil(issue.lastError)
    XCTAssertFalse(issue.questions.contains { $0.reply == nil })
  }

  func testAMergedPullRequestDoesNotOverrideNewerEvidence() async throws {
    try model.updateIssue(id) {
      $0.worktreePath = nil
      $0.revision = $0.coveredRevision + 1
      $0.record("Needs attention", status: .needsYou)
    }
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    // The merged revision is done; the newer evidence goes back to the queue for a new fix.
    XCTAssertEqual(model.issue(id)?.status, .queued)
    XCTAssertNil(model.issue(id)?.prURL)
  }

  func testAMergedPullRequestForAnOlderRevisionQueuesTheNewerEvidence() async throws {
    // Revision 2 was dispatched (raising coveredRevision) but stopped before reaching the PR,
    // which still holds the revision 1 fix.
    try model.updateIssue(id) {
      $0.worktreePath = nil
      $0.prRevision = $0.revision
      $0.revision += 1
      $0.coveredRevision = $0.revision
      $0.questions.append(PendingQuestion(title: "Which layout do you want?"))
      $0.record("Needs attention", status: .needsYou)
    }
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertNotEqual(issue.status, .merged)
    XCTAssertNil(issue.prURL)
    XCTAssertNil(issue.prRevision)
  }

  func testAnUncertainDispatchIsNotMarkedMerged() async throws {
    try model.updateIssue(id) {
      $0.dispatchUncertain = true
      $0.record("Needs attention", status: .needsYou)
    }
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNotNil(model.issue(id)?.prURL)
  }

  func testAClosedPullRequestLeavesTheReportWaiting() async throws {
    try model.updateIssue(id) { $0.record("Needs attention", status: .needsYou) }
    try pullRequest(["state": .string("CLOSED")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNil(model.issue(id)?.mergeCommit)
  }

  func testAFailedReportWhosePullRequestMergedIsMerged() async throws {
    try model.updateIssue(id) {
      $0.worktreePath = nil
      $0.record("Failed", status: .failed)
    }
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .merged)
  }

  func testAnArchivedReportIsNotWatched() async throws {
    try model.updateIssue(id) {
      $0.archived = true
      $0.record("Needs attention", status: .needsYou)
    }
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
  }
}
