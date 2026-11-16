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
}
