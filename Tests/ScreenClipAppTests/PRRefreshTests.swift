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
    // A stand-in `gh` that answers `pr list` with the list the test wrote (empty by default)
    // and every other call with the pull request state the test wrote.
    let gh = root.appendingPathComponent("gh")
    try """
      #!/bin/sh
      dir="$(dirname "$0")"
      if [ "$2" = list ]; then cat "$dir/list.json" 2>/dev/null || echo '[]'; exit 0; fi
      cat "$dir/state.json"

      """.write(
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

  private func mergedList(_ entries: [[String: JSONValue]]) throws {
    try JSONEncoder().encode(JSONValue.array(entries.map(JSONValue.object))).write(
      to: root.appendingPathComponent("list.json"))
  }

  private let failedChecks = JSONValue.array([.object(["conclusion": .string("FAILURE")])])

  func testManualMergeRechecksTheReviewedHeadAndRequiresGitHubConfirmation() async throws {
    try model.commit { $0.projects[0].autoMerge = false }
    let issue = try XCTUnwrap(model.issue(id))
    let repo = try XCTUnwrap(issue.worktreePath)
    // Simulate a reachable base with a local repository. The fake gh only records merge requests.
    _ = try await CommandRunner.checked(GitWorkspace.git, ["remote", "add", "origin", repo], cwd: repo)
    let gh = root.appendingPathComponent("gh")
    try """
      #!/bin/sh
      cd "$(dirname "$0")"
      if [ "$2" = "merge" ]; then
        printf '%s\\n' "$@" >> merge-request
      else
        cat state.json
      fi
      """.write(to: gh, atomically: false, encoding: .utf8)
    let request = root.appendingPathComponent("merge-request")
    let clean: [String: JSONValue] = [
      "mergeable": .string("MERGEABLE"), "mergeStateStatus": .string("CLEAN"),
      "statusCheckRollup": .array([.object(["conclusion": .string("SUCCESS")])]),
    ]
    try pullRequest(clean)
    await model.worker.refreshPR(id)
    XCTAssertNil(model.worker.manualMergeHeads[id], "Checks alone cannot replace local validation.")
    try model.worker.saveReceipt(
      ValidationReceipt(head: "pushed", command: "true", passed: true, date: Date(),
        output: "", fingerprint: "fixture"), for: id, issue: issue)

    for change: [String: JSONValue] in [
      ["headRefOid": .string("another-head")], ["isDraft": .bool(true)], ["state": .string("CLOSED")],
      ["reviewDecision": .string("REVIEW_REQUIRED")], ["baseRefName": .string("different-base")],
      ["statusCheckRollup": .null], ["statusCheckRollup": .array([.object(["status": .string("QUEUED")])])],
      ["statusCheckRollup": .array([]), "mergeStateStatus": .string("BLOCKED")],
    ] {
      try pullRequest(clean)
      await model.worker.refreshPR(id)
      XCTAssertEqual(model.worker.manualMergeHeads[id], "pushed")
      try pullRequest(clean.merging(change) { _, new in new })
      await model.worker.refreshPR(id, mergeReviewedHead: "pushed")
      XCTAssertNil(model.worker.manualMergeHeads[id])
      XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
    }
    try pullRequest(clean.merging(["statusCheckRollup": .array([])]) { _, new in new })
    // Right after a push GitHub reports no checks until CI registers its runs.
    await model.worker.refreshPR(id)
    XCTAssertNil(model.worker.manualMergeHeads[id], "A fresh empty rollup is not \"no checks\".")
    model.worker.emptyRollupGrace = 0
    try model.commit { $0.projects[0].autoMerge = true }
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.worker.manualMergeHeads[id], "pushed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "Automatic merge requires host checks.")
    try model.commit { $0.projects[0].autoMerge = false }
    await model.worker.refreshPR(id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
    await model.worker.refreshPR(id, mergeReviewedHead: "pushed")
    XCTAssertEqual(try String(contentsOf: request, encoding: .utf8).split(separator: "\n"),
      ["pr", "merge", "https://github.com/example/app/pull/1", "--squash", "--match-head-commit", "pushed"])
    XCTAssertEqual(model.issue(id)?.status, .prOpen, "The merge command alone is not confirmation.")
    XCTAssertFalse(model.snapshot.projects[0].autoMerge)
    try model.updateIssue(id) { $0.branch = nil }
    try pullRequest(["state": .string("MERGED"), "mergeCommit": .object(["oid": .string("result")])])
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.issue(id)?.mergeCommit, "result")
    XCTAssertEqual(model.issue(id)?.status, .merged)
  }

  func testManualGrokMergeValidatesOnlyOnRequestAndCoversAFollowUpOnTheSameBranch() async throws {
    try model.commit { $0.projects[0].autoMerge = false }
    let issue = try XCTUnwrap(model.issue(id))
    let path = try XCTUnwrap(issue.worktreePath)
    _ = try await CommandRunner.checked(GitWorkspace.git, ["remote", "add", "origin", path], cwd: path)
    let head = try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: path)
    try model.updateIssue(id) {
      $0.agent = .external
      $0.prRevision = 1
      $0.revision = 2
      $0.coveredRevision = 2
      $0.handoffRevision = 2
      $0.handoffCommit = head
    }
    try pullRequest([
      "headRefOid": .string(head), "mergeable": .string("MERGEABLE"), "mergeStateStatus": .string("CLEAN"),
      "statusCheckRollup": .array([.object(["conclusion": .string("SUCCESS")])]),
    ])
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.issue(id)?.prRevision, 2)
    XCTAssertNil(model.worker.loadReceipt(id, issue: issue))
    XCTAssertEqual(model.worker.manualMergeHeads[id], head)
    await model.worker.refreshPR(id, mergeReviewedHead: head)
    let receipt = try XCTUnwrap(model.worker.loadReceipt(id, issue: issue))
    XCTAssertTrue(receipt.passed)
    XCTAssertEqual(receipt.head, head)
    XCTAssertFalse(model.snapshot.projects[0].autoMerge)
  }

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

  func testAMergeIsRecordedAfterTheWorktreeWasRemoved() async throws {
    // Whoever resolved and merged the pull request also removed the report's worktree, and gh
    // cannot start in a directory that no longer exists.
    try model.updateIssue(id) {
      $0.worktreePath = self.root.appendingPathComponent("worktrees/removed").path
      $0.lastError = "The base branch conflicts with this fix in: App.swift"
      $0.record("The base update needs attention in Claude Code.", status: .needsYou)
    }
    try pullRequest(["state": .string("MERGED"), "mergeCommit": .object(["oid": .string("abc123")])])
    await model.worker.refreshPRs()
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .merged)
    XCTAssertEqual(issue.mergeCommit, "abc123")
    XCTAssertNil(issue.lastError)
  }

  func testAnOpenPullRequestWhoseWorktreeWasRemovedWaitsForAMergeOnGitHub() async throws {
    try model.updateIssue(id) { $0.worktreePath = self.root.appendingPathComponent("worktrees/removed").path }
    try pullRequest(["mergeable": .string("CONFLICTING"), "statusCheckRollup": failedChecks])
    await model.worker.refreshPRs()
    var issue = try XCTUnwrap(model.issue(id))
    // Nothing can be updated, validated, or repaired without the worktree.
    XCTAssertEqual(issue.status, .prOpen)
    XCTAssertEqual(issue.checkSummary, AgentWorker.removedWorktreeSummary)
    XCTAssertNil(issue.repairAttempts)
    XCTAssertNil(issue.lastError)

    try pullRequest(["state": .string("MERGED"), "mergeCommit": .object(["oid": .string("abc123")])])
    await model.worker.refreshPRs()
    issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .merged)
    XCTAssertEqual(issue.mergeCommit, "abc123")
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

  /// Restart recovery failed in a removed worktree before ScreenClip published, and the fix was
  /// pushed and merged by hand from the report's branch.
  private func stopBeforePublishing() throws {
    try model.updateIssue(id) {
      $0.worktreePath = self.root.appendingPathComponent("worktrees/removed").path
      $0.branch = "screenclip/16781790"
      $0.prURL = nil
      $0.prHead = nil
      $0.record("The file doesn't exist.", status: .needsYou, kind: "error")
    }
  }

  func testAMergedPullRequestFromTheReportsBranchCompletesAReportWithoutAPullRequest() async throws {
    try stopBeforePublishing()
    try mergedList([[
      "url": .string("https://github.com/example/app/pull/7"),
      "headRefName": .string("screenclip/16781790"), "baseRefName": .string("main"),
      "isCrossRepository": .bool(false),
    ]])
    try pullRequest([
      "url": .string("https://github.com/example/app/pull/7"), "state": .string("MERGED"),
      "mergeCommit": .object(["oid": .string("abc123")]),
    ])
    await model.worker.refreshPRs()
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .merged)
    XCTAssertEqual(issue.prURL, "https://github.com/example/app/pull/7")
    XCTAssertEqual(issue.mergeCommit, "abc123")
  }

  func testAReportWithoutAPullRequestIgnoresAForkOrAnotherBranch() async throws {
    try stopBeforePublishing()
    try mergedList([
      [
        "url": .string("https://github.com/example/app/pull/8"),
        "headRefName": .string("screenclip/16781790"), "baseRefName": .string("main"),
        "isCrossRepository": .bool(true),
      ],
      [
        "url": .string("https://github.com/example/app/pull/9"),
        "headRefName": .string("screenclip/other"), "baseRefName": .string("main"),
        "isCrossRepository": .bool(false),
      ],
    ])
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNil(model.issue(id)?.prURL)
  }

  func testAReportWithoutAPullRequestWaitsWhileNothingIsMerged() async throws {
    try stopBeforePublishing()
    try pullRequest(["state": .string("MERGED")])
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNil(model.issue(id)?.prURL)
  }
}
