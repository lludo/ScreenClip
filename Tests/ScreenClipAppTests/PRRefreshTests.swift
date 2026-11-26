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
      ["tag", "pushed"],
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

  private let prURL = "https://github.com/example/app/pull/1"

  /// Routes a GitHub-shaped origin to a local bare repository, so fetch and push are real, and
  /// adds a worktree on `branch` from the `release` base. The stand-in gh records a merge in
  /// `merge-request` and the latest pull request body in `body.md`.
  private func remoteWorktree(branch: String) async throws -> (repo: String, worktree: URL) {
    let repo = try XCTUnwrap(model.snapshot.projects.first).path
    let worktree = root.appendingPathComponent("agent")
    let git = GitWorkspace.git, gh = root.appendingPathComponent("gh")
    let transport = root.appendingPathComponent("ssh")
    try """
      #!/bin/sh
      case "$*" in
        *git-upload-pack*) exec git upload-pack "$(dirname "$0")/remote.git" ;;
        *git-receive-pack*) exec git receive-pack "$(dirname "$0")/remote.git" ;;
        *) exit 1 ;;
      esac
      """.write(to: transport, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: transport.path)
    try """
      #!/bin/sh
      dir="$(dirname "$0")"
      prev=
      for arg in "$@"; do [ "$prev" = --body-file ] && cp "$arg" "$dir/body.md"; prev="$arg"; done
      case "$1 $2" in
        'auth status'|'pr edit') ;;
        'pr list') cat "$dir/list.json" 2>/dev/null || echo '[]' ;;
        'pr create') echo '\(prURL)' ;;
        'pr view') cat "$dir/state.json" ;;
        'pr merge') echo "$@" > "$dir/merge-request" ;;
        *) exit 1 ;;
      esac
      """.write(to: gh, atomically: false, encoding: .utf8)
    for args in [
      ["branch", "-m", "release"], ["clone", "--bare", repo, root.appendingPathComponent("remote.git").path],
      ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"],
      ["config", "core.sshCommand", "'\(transport.path)'"],
      ["remote", "add", "origin", "ssh://git@github.com/example/app.git"],
      ["worktree", "add", "-b", branch, worktree.path, "release"],
    ] { _ = try await CommandRunner.checked(git, args, cwd: repo) }
    var project = try XCTUnwrap(model.snapshot.projects.first)
    project.baseBranch = "release"
    try model.saveProject(project)
    return (repo, worktree)
  }

  private func passingChecks(_ head: String) throws {
    try pullRequest(["headRefOid": .string(head), "baseRefName": .string("release"),
      "mergeable": .string("MERGEABLE"), "mergeStateStatus": .string("CLEAN"),
      "statusCheckRollup": .array([.object(["conclusion": .string("SUCCESS")])])])
  }

  func testPublishValidatesTheCurrentBaseAndChecksItAgainBeforeMerge() async throws {
    let branch = "screenclip/validation-test"
    let (repo, worktree) = try await remoteWorktree(branch: branch)
    var project = try XCTUnwrap(model.snapshot.projects.first)
    let git = GitWorkspace.git
    let beforeMerge = root.appendingPathComponent("merge-request")
    let validations = root.appendingPathComponent("validated-bases")
    func advance(_ value: String) async throws {
      try (value + "\n").write(toFile: repo + "/base.txt", atomically: true, encoding: .utf8)
      for args in [["add", "base.txt"], ["commit", "-m", value], ["push", "origin", "release"]] {
        _ = try await CommandRunner.checked(git, args, cwd: repo)
      }
    }

    project.validationCommand = "test -f fix.txt && cat base.txt >> '\(validations.path)'"
    project.autoMerge = true
    try model.saveProject(project)
    try model.updateIssue(id) {
      $0.status = .working; $0.prURL = nil; $0.prHead = nil
      $0.worktreePath = worktree.path; $0.branch = branch; $0.captures[0].imagePath = nil
    }
    try Data("agent edit".utf8).write(to: worktree.appendingPathComponent("fix.txt"))
    try await advance("first")
    await model.worker.publish(id, project: project, summary: "Fixed")
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .prOpen, issue.lastError ?? "")
    let firstHead = try XCTUnwrap(issue.prHead)
    XCTAssertEqual(try String(contentsOf: validations, encoding: .utf8), "first\n")

    try mergedList([["url": .string(prURL), "baseRefName": .string("release"), "isCrossRepository": .bool(false)]])
    try await advance("second")
    try passingChecks(firstHead)
    await model.worker.refreshPR(id)
    let secondHead = try XCTUnwrap(model.issue(id)?.prHead)
    XCTAssertNotEqual(secondHead, firstHead)
    XCTAssertFalse(FileManager.default.fileExists(atPath: beforeMerge.path))
    try passingChecks(secondHead)
    await model.worker.refreshPR(id)
    XCTAssertEqual(try String(contentsOf: validations, encoding: .utf8), "first\nsecond\n")
    XCTAssertTrue(try String(contentsOf: beforeMerge, encoding: .utf8).contains("--match-head-commit " + secondHead))
  }

  /// The description links Before / After images at the commit that added them, while the
  /// pushed head drops `.screenclip/`. A head that still carries evidence (an older pull request)
  /// is never merged: ScreenClip removes the folder, pushes, and merges once checks pass again.
  func testEvidenceNeverReachesTheMergeAndPreviewsKeepTheirCommit() async throws {
    let branch = "screenclip/evidence-test"
    let (_, worktree) = try await remoteWorktree(branch: branch)
    var project = try XCTUnwrap(model.snapshot.projects.first)
    let git = GitWorkspace.git, remote = root.appendingPathComponent("remote.git").path
    let mergeRequest = root.appendingPathComponent("merge-request")
    project.validationCommand = "test -f fix.txt"
    project.autoMerge = true
    try model.saveProject(project)
    let png = Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII=")!
    let capture = root.appendingPathComponent("capture.png")
    try png.write(to: capture)
    try model.updateIssue(id) {
      $0.status = .working; $0.prURL = nil; $0.prHead = nil
      $0.worktreePath = worktree.path; $0.branch = branch; $0.captures[0].imagePath = capture.path
    }
    let issue = try XCTUnwrap(model.issue(id))
    let folder = PRScreenshotEvidence.directory(for: issue)
    let after = worktree.appendingPathComponent(folder + "/after")
    try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
    try png.write(to: after.appendingPathComponent("1.png"))
    try Data("agent edit".utf8).write(to: worktree.appendingPathComponent("fix.txt"))

    await model.worker.publish(id, project: project, summary: "Fixed")
    XCTAssertEqual(model.issue(id)?.status, .prOpen, model.issue(id)?.lastError ?? "")
    let head = try XCTUnwrap(model.issue(id)?.prHead)
    let pushed = try await CommandRunner.checked(git, ["rev-parse", branch], cwd: remote)
    XCTAssertEqual(pushed, head)
    let headPaths = try await GitHubService.listScreenclipPaths(revision: head, cwd: remote)
    XCTAssertEqual(headPaths, [], "The pull request's head carries no evidence")
    let evidence = try await CommandRunner.checked(git, ["rev-parse", head + "^"], cwd: remote)
    let evidencePaths = try await GitHubService.listScreenclipPaths(revision: evidence, cwd: remote)
    XCTAssertEqual(evidencePaths.sorted(), [folder + "/after/1.png", folder + "/before/1.png"])
    let body = try String(contentsOf: root.appendingPathComponent("body.md"), encoding: .utf8)
    XCTAssertTrue(body.contains("![Before 1](https://github.com/example/app/blob/\(evidence)/\(folder)/before/1.png"))
    XCTAssertTrue(body.contains("![After 1](https://github.com/example/app/blob/\(evidence)/\(folder)/after/1.png"))
    XCTAssertFalse(body.contains("/blob/\(head)/"))
    // The in-app preview reads each image at the commit its link names.
    let html = "<p><img src=\"https://github.com/example/app/blob/\(evidence)/\(folder)/after/1.png?raw=true\"></p>"
    let endpoints = PRScreenshotEvidence.imageEndpoints(
      html: html, pullRequest: try XCTUnwrap(URL(string: prURL)), issueID: id)
    XCTAssertEqual(endpoints.count, 1)
    XCTAssertTrue(endpoints[0].hasSuffix("?ref=" + evidence))

    // An older pull request whose head still carries `.screenclip/`.
    try FileManager.default.createDirectory(
      at: worktree.appendingPathComponent(".screenclip/legacy"), withIntermediateDirectories: true)
    try png.write(to: worktree.appendingPathComponent(".screenclip/legacy/1.png"))
    for args in [["add", "--force", ".screenclip"], ["commit", "-q", "-m", "Legacy evidence"], ["push", "-q", "origin", branch]] {
      _ = try await CommandRunner.checked(git, args, cwd: worktree.path)
    }
    let legacy = try await CommandRunner.checked(git, ["rev-parse", "HEAD"], cwd: worktree.path)
    try model.worker.saveReceipt(
      ValidationReceipt(head: legacy, command: project.validationCommand, passed: true, date: Date(),
        output: "", fingerprint: "fixture"), for: id, issue: issue)
    try model.updateIssue(id) { $0.prHead = legacy }
    try passingChecks(legacy)
    // A clean local checkout is no evidence about the remote commit GitHub would merge.
    _ = try await CommandRunner.checked(git, ["switch", "--detach", legacy + "^"], cwd: worktree.path)
    await model.worker.refreshPR(id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: mergeRequest.path))
    _ = try await CommandRunner.checked(git, ["switch", branch], cwd: worktree.path)

    // A rejected cleanup push must preserve both layers of someone else's local edit.
    let edited = worktree.appendingPathComponent("fix.txt")
    try Data("staged".utf8).write(to: edited)
    _ = try await CommandRunner.checked(git, ["add", "--", "fix.txt"], cwd: worktree.path)
    try Data("still editing".utf8).write(to: edited)
    let hook = root.appendingPathComponent("remote.git/hooks/pre-receive")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    await model.worker.refreshPR(id)
    let staged = try await CommandRunner.checked(git, ["show", ":fix.txt"], cwd: worktree.path)
    XCTAssertEqual(staged, "staged")
    XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "still editing")
    XCTAssertEqual(model.issue(id)?.prHead, legacy)
    try FileManager.default.removeItem(at: hook)
    await model.worker.refreshPR(id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: mergeRequest.path), "Never merged with .screenclip/")
    let stripped = try XCTUnwrap(model.issue(id)?.prHead)
    XCTAssertNotEqual(stripped, legacy)
    let remoteHead = try await CommandRunner.checked(git, ["rev-parse", branch], cwd: remote)
    XCTAssertEqual(remoteHead, stripped)
    let strippedPaths = try await GitHubService.listScreenclipPaths(revision: stripped, cwd: remote)
    XCTAssertEqual(strippedPaths, [])
    let subject = try await CommandRunner.checked(git, ["log", "-1", "--format=%s", stripped], cwd: remote)
    XCTAssertEqual(subject, PRScreenshotEvidence.removalCommitMessage)
    XCTAssertEqual(model.worker.loadReceipt(id, issue: issue)?.head, stripped)
    XCTAssertEqual(model.issue(id)?.checkSummary, PRScreenshotEvidence.removedBeforeMergeSummary)

    // Checks still report the old head: nothing merges until they cover the new one.
    await model.worker.refreshPR(id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: mergeRequest.path))
    try passingChecks(stripped)
    await model.worker.refreshPR(id)
    XCTAssertTrue(try String(contentsOf: mergeRequest, encoding: .utf8).contains("--match-head-commit " + stripped))
  }

  /// Grok Bot's last commit deletes its hand-off folder, which is how ScreenClip knows the routine
  /// finished. Any other `.screenclip/` file ScreenClip removes itself instead of waiting.
  func testGrokBotPullRequestWaitsForItsHandoffAndLeftoverEvidenceIsRemoved() async throws {
    let number = try XCTUnwrap(model.issue(id)?.reportNumber)
    let branch = "screenclip/\(number)-grok"
    let (_, worktree) = try await remoteWorktree(branch: branch)
    let git = GitWorkspace.git, remote = root.appendingPathComponent("remote.git").path
    try model.commit {
      $0.projects[0].autoMerge = true
      $0.projects[0].validationCommand = "true"
    }
    func commit(_ message: String, add: [String] = [], remove: [String] = []) async throws -> String {
      for path in add {
        let file = worktree.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: file)
        _ = try await CommandRunner.checked(git, ["add", "--force", path], cwd: worktree.path)
      }
      for path in remove { _ = try await CommandRunner.checked(git, ["rm", "-r", "-q", path], cwd: worktree.path) }
      for args in [["commit", "-q", "-m", message], ["push", "-q", "origin", branch]] {
        _ = try await CommandRunner.checked(git, args, cwd: worktree.path)
      }
      return try await CommandRunner.checked(git, ["rev-parse", "HEAD"], cwd: worktree.path)
    }
    let handoff = try await commit(
      "ScreenClip: #\(number) evidence revision 1",
      add: [".screenclip/\(number)/report.json", ".screenclip/pr/old/revision-1/before/1.png"])
    try model.updateIssue(id) {
      $0.agent = .external
      $0.worktreePath = worktree.path
      $0.branch = branch
      $0.prRevision = $0.revision
      $0.handoffRevision = $0.revision
      $0.handoffCommit = handoff
      $0.prHead = handoff
    }
    let working = try await commit("Fix", add: ["fix.txt"])
    try passingChecks(working)
    await model.worker.refreshPR(id)
    XCTAssertEqual(model.issue(id)?.checkSummary, ExternalAssistant.evidenceStillPresentSummary)
    var pushed = try await CommandRunner.checked(git, ["rev-parse", branch], cwd: remote)
    XCTAssertEqual(pushed, working, "ScreenClip does not touch the branch while Grok Bot works")

    let finished = try await commit("Remove hand-off", remove: [".screenclip/\(number)"])
    try passingChecks(finished)
    await model.worker.refreshPR(id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("merge-request").path))
    pushed = try await CommandRunner.checked(git, ["rev-parse", branch], cwd: remote)
    XCTAssertNotEqual(pushed, finished)
    let left = try await GitHubService.listScreenclipPaths(revision: pushed, cwd: remote)
    XCTAssertEqual(left, [])
    XCTAssertEqual(model.issue(id)?.prHead, pushed)
    XCTAssertEqual(model.issue(id)?.checkSummary, PRScreenshotEvidence.removedBeforeMergeSummary)
    try passingChecks(pushed)
    await model.worker.refreshPR(id)
    XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("merge-request"), encoding: .utf8)
      .contains("--match-head-commit " + pushed))
  }

  func testFailedInitialFetchPreservesTheFixAndSkipsValidation() async throws {
    var project = try XCTUnwrap(model.snapshot.projects.first)
    let marker = root.appendingPathComponent("validation-ran")
    project.validationCommand = "touch '\(marker.path)'"
    let fix = URL(fileURLWithPath: project.path).appendingPathComponent("fix.txt")
    try Data("local fix".utf8).write(to: fix)
    try model.updateIssue(id) {
      $0.status = .working; $0.prURL = nil; $0.prHead = nil; $0.captures[0].imagePath = nil
    }
    await model.worker.publish(id, project: project, summary: "Fixed")
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNil(model.issue(id)?.prURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(try String(contentsOf: fix, encoding: .utf8), "local fix")
  }

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
      // A closed pull request moves the report to Needs you; each case starts from PR open.
      try model.updateIssue(id) {
        $0.status = .prOpen
        $0.prURL = "https://github.com/example/app/pull/1"
        $0.prHead = "pushed"
      }
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

  func testAPullRequestClosedWithoutMergingMovesTheReportToNeedsYou() async throws {
    try pullRequest(["state": .string("CLOSED")])
    await model.worker.refreshPR(id)
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .needsYou)
    XCTAssertNil(issue.mergeCommit)
    XCTAssertNil(issue.checkSummary)
    XCTAssertTrue(issue.unread)
    XCTAssertNil(issue.prURL, "Continue opens a new pull request; the closed one is in the activity.")
    XCTAssertTrue(model.canMove(issue))
    XCTAssertEqual(issue.activities.last?.text, AgentWorker.closedPullRequestActivity)
    // It then waits for the tester; a closed pull request is never taken for a merge.
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNil(model.issue(id)?.mergeCommit)
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

  private func mergedFromTheReportsBranch() throws {
    try mergedList([[
      "url": .string("https://github.com/example/app/pull/7"),
      "headRefName": .string("screenclip/16781790"), "baseRefName": .string("main"),
      "isCrossRepository": .bool(false),
    ]])
    try pullRequest([
      "url": .string("https://github.com/example/app/pull/7"), "state": .string("MERGED"),
      "mergeCommit": .object(["oid": .string("abc123")]),
    ])
  }

  func testABranchMergeWithNewerEvidenceQueuesIt() async throws {
    try stopBeforePublishing()
    try model.updateIssue(id) { $0.revision = $0.coveredRevision + 1 }
    try mergedFromTheReportsBranch()
    await model.worker.refreshPRs()
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .queued)
    XCTAssertNil(issue.prURL)
    XCTAssertNil(issue.branch)
  }

  func testABranchMergeIsIgnoredWhileTheWorktreeExists() async throws {
    // The worktree may hold commits made after the merged push; removing it would lose them.
    try stopBeforePublishing()
    try model.updateIssue(id) { $0.worktreePath = self.root.appendingPathComponent("repo").path }
    try mergedFromTheReportsBranch()
    await model.worker.refreshPRs()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNil(model.issue(id)?.prURL)
  }

  func testABranchMergeIsIgnoredForGrokBot() async throws {
    // Grok Bot reuses its branch across revisions; only discovery, which checks the report in
    // the pull request body, links its pull requests.
    try stopBeforePublishing()
    try model.updateIssue(id) { $0.agent = .external }
    try mergedFromTheReportsBranch()
    await model.worker.refreshPRs()
    XCTAssertNotEqual(model.issue(id)?.status, .merged)
    XCTAssertNil(model.issue(id)?.prURL)
  }
}
