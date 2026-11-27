import XCTest

@testable import ScreenClip
@testable import ScreenClipCore

/// Report worktrees are freed once nothing needs them, but never at the cost of work: a worktree
/// with uncommitted changes or commits that are not on origin stays, the tester's checkout is
/// never touched, and remote branches are left alone.
@MainActor final class WorkspaceCleanupTests: XCTestCase {
  private var root: URL!
  private var repo: URL!
  private var model: AppModel!
  private var project: Project!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-cleanup-" + UUID().uuidString)
    let origin = root.appendingPathComponent("origin.git")
    repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    try git(["init", "-q", "--bare", "-b", "main"], in: origin)
    try git(["clone", "-q", origin.path, repo.path], in: root)
    try git(["symbolic-ref", "HEAD", "refs/heads/main"], in: repo)
    try git(["commit", "-q", "--allow-empty", "-m", "initial"], in: repo)
    try git(["push", "-q", "origin", "main"], in: repo)
    model = try AppModel(root: root.appendingPathComponent("queue"))
    model.loadExternalAssistant = { .empty }
    try model.commit { $0.settings.paused = true }
    project = Project(name: "Test", path: repo.path, validationCommand: "true")
    try model.saveProject(project)
    project = model.snapshot.projects.first
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Safety rule

  func testOnlyACleanFullyPushedScreenClipWorktreeMayBeRemoved() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id)
    let check = { await GitWorkspace.reasonToKeep(
      path: path, branch: branch, repository: self.repo.path, root: self.model.store.root) }
    let nothingToLose = await check()
    XCTAssertNil(nothingToLose)

    try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
    let untracked = await check()
    XCTAssertEqual(untracked, "uncommitted changes")

    try git(["add", "notes.txt"], in: URL(fileURLWithPath: path))
    try git(["commit", "-q", "-m", "fix"], in: URL(fileURLWithPath: path))
    let unpushed = await check()
    XCTAssertEqual(unpushed, "commits not on origin")

    try git(["push", "-q", "origin", branch], in: URL(fileURLWithPath: path))
    let pushed = await check()
    XCTAssertNil(pushed)

    let checkout = await GitWorkspace.reasonToKeep(
      path: repo.path, branch: "main", repository: repo.path, root: model.store.root)
    XCTAssertEqual(checkout, "not a ScreenClip worktree")
  }

  // MARK: When reports stop needing their worktree

  func testAgentCloseRemovesACleanWorktreeAndKeepsTheRemoteBranch() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id, push: true)
    try model.updateIssue(id) { $0.record("failed", status: .failed) }
    try AgentClosureInbox.write(
      AgentClosure(issueID: id, resolution: .canceled, summary: "Fixed elsewhere."),
      root: model.store.root)
    await model.worker.applyAgentClosures()
    XCTAssertEqual(model.issue(id)?.status, .canceled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    XCTAssertNil(model.issue(id)?.worktreePath)
    XCTAssertFalse(try hasRef("refs/heads/" + branch))
    XCTAssertTrue(try hasRef("refs/heads/" + branch, in: root.appendingPathComponent("origin.git")))
  }

  func testAgentCloseKeepsADirtyWorktree() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id)
    try "work in progress".write(toFile: path + "/fix.swift", atomically: true, encoding: .utf8)
    try model.updateIssue(id) { $0.record("failed", status: .failed) }
    try AgentClosureInbox.write(
      AgentClosure(issueID: id, resolution: .canceled, summary: "No longer applies."),
      root: model.store.root)
    await model.worker.applyAgentClosures()
    XCTAssertEqual(model.issue(id)?.status, .canceled)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/fix.swift"))
    XCTAssertEqual(model.issue(id)?.worktreePath, path)
    XCTAssertTrue(try hasRef("refs/heads/" + branch))
  }

  func testAFixMergedFromAnotherBranchFreesACleanWorktree() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id, push: true)
    try model.updateIssue(id) { $0.record("failed", status: .failed) }
    model.worker.closeAsFixedElsewhere(
      id, url: "https://github.com/o/r/pull/9", commit: "abc", head: "someone-else")
    XCTAssertEqual(model.issue(id)?.status, .merged)
    try await wait { !FileManager.default.fileExists(atPath: path) }
    try await wait { self.model.issue(id)?.worktreePath == nil }
    XCTAssertFalse(try hasRef("refs/heads/" + branch))
    // Another session's pull request may still use the remote branch.
    XCTAssertTrue(try hasRef("refs/heads/" + branch, in: root.appendingPathComponent("origin.git")))
  }

  func testAFixMergedFromAnotherBranchKeepsUnpushedCommits() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id)
    try git(["commit", "-q", "--allow-empty", "-m", "local only"], in: URL(fileURLWithPath: path))
    try model.updateIssue(id) { $0.record("failed", status: .failed) }
    model.worker.closeAsFixedElsewhere(
      id, url: "https://github.com/o/r/pull/9", commit: "abc", head: "someone-else")
    await model.worker.releaseWorkspace(id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertEqual(model.issue(id)?.worktreePath, path)
    XCTAssertTrue(try hasRef("refs/heads/" + branch))
  }

  func testArchivingFreesACleanWorktreeAndKeepsADirtyOne() async throws {
    let clean = try submit()
    let dirty = try submit()
    let (cleanPath, _) = try await prepareWorktree(for: clean)
    let (dirtyPath, _) = try await prepareWorktree(for: dirty)
    try "edit".write(toFile: dirtyPath + "/edit.txt", atomically: true, encoding: .utf8)
    for id in [clean, dirty] {
      try model.updateIssue(id) { $0.record("failed", status: .failed) }
      model.setArchived(id, archived: true)
    }
    try await wait { !FileManager.default.fileExists(atPath: cleanPath) }
    try await wait { self.model.issue(clean)?.worktreePath == nil }
    await model.worker.releaseWorkspace(dirty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath + "/edit.txt"))
    XCTAssertEqual(model.issue(dirty)?.worktreePath, dirtyPath)
  }

  func testNewEvidenceAfterAMergeFreesTheOldWorktree() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id)
    try model.updateIssue(id) { $0.record("Merged", status: .merged) }
    try model.addContext(id, text: "Still clipped on the narrow window")
    XCTAssertNil(model.issue(id)?.worktreePath)
    try await wait { !FileManager.default.fileExists(atPath: path) }
    // The local branch is deleted right after the folder.
    try await wait { (try? self.hasRef("refs/heads/" + branch)) == false }
  }

  func testDeletingAReportFreesItsCleanWorktreeOnly() async throws {
    let clean = try submit()
    let dirty = try submit()
    let (cleanPath, _) = try await prepareWorktree(for: clean)
    let (dirtyPath, _) = try await prepareWorktree(for: dirty)
    try "edit".write(toFile: dirtyPath + "/edit.txt", atomically: true, encoding: .utf8)
    for id in [clean, dirty] {
      try model.updateIssue(id) { $0.record("failed", status: .failed) }
      model.delete(id)
    }
    XCTAssertTrue(model.snapshot.issues.isEmpty)
    try await wait { !FileManager.default.fileExists(atPath: cleanPath) }
    await model.worker.releaseUnneededWorkspaces()
    XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath + "/edit.txt"))
  }

  func testLaunchSweepRemovesOnlyCleanOrphansAndLeavesTheCheckoutAlone() async throws {
    let referenced = try submit()
    let (referencedPath, _) = try await prepareWorktree(for: referenced)
    let cleanOrphan = try await GitWorkspace.prepare(
      project: project, issueID: UUID(), root: model.store.root)
    let dirtyOrphan = try await GitWorkspace.prepare(
      project: project, issueID: UUID(), root: model.store.root)
    try "edit".write(toFile: dirtyOrphan.path + "/edit.txt", atomically: true, encoding: .utf8)
    // A worktree the tester made themselves, outside ScreenClip's folder.
    let own = root.appendingPathComponent("own-worktree").path
    try git(["worktree", "add", "-q", "-b", "mine", own, "main"], in: repo)
    try "tester".write(toFile: repo.path + "/scratch.txt", atomically: true, encoding: .utf8)

    await model.worker.releaseUnneededWorkspaces()

    XCTAssertFalse(FileManager.default.fileExists(atPath: cleanOrphan.path))
    XCTAssertFalse(try hasRef("refs/heads/" + cleanOrphan.branch))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyOrphan.path + "/edit.txt"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: referencedPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: own))
    XCTAssertTrue(try hasRef("refs/heads/mine"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path + "/scratch.txt"))
  }

  func testAFreedBranchContinuesFromOrigin() async throws {
    let id = try submit()
    let (path, branch) = try await prepareWorktree(for: id)
    try git(["commit", "-q", "--allow-empty", "-m", "fix"], in: URL(fileURLWithPath: path))
    try git(["push", "-q", "origin", branch], in: URL(fileURLWithPath: path))
    let head = try git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: path))
    try model.updateIssue(id) { $0.record("failed", status: .failed) }
    model.setArchived(id, archived: true)
    try await wait { self.model.issue(id)?.worktreePath == nil }
    let workspaceID = try XCTUnwrap(model.issue(id)?.workspaceID)
    let again = try await GitWorkspace.prepare(
      project: project, issueID: workspaceID, root: model.store.root)
    XCTAssertEqual(again.branch, branch)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: again.path)), head)
  }

  // MARK: Helpers

  private func submit() throws -> UUID {
    let before = Set(model.snapshot.issues.map(\.id))
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Label clipped",
      context: CaptureContext(appName: "Test"), projectID: project.id, existingID: nil,
      draft: false, agent: .claude)
    return try XCTUnwrap(model.snapshot.issues.first { !before.contains($0.id) }?.id)
  }

  private func prepareWorktree(for id: UUID, push: Bool = false) async throws -> (String, String) {
    let workspaceID = try XCTUnwrap(model.issue(id)?.workspaceID)
    let workspace = try await GitWorkspace.prepare(
      project: project, issueID: workspaceID, root: model.store.root)
    try model.updateIssue(id) {
      $0.worktreePath = workspace.path
      $0.branch = workspace.branch
    }
    if push {
      try git(["push", "-q", "origin", workspace.branch], in: URL(fileURLWithPath: workspace.path))
    }
    return (workspace.path, workspace.branch)
  }

  private func hasRef(_ ref: String, in directory: URL? = nil) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["show-ref", "--verify", "--quiet", ref]
    process.currentDirectoryURL = directory ?? repo
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  @discardableResult
  private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      ["-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw ScreenClipError.message("git \(arguments.joined(separator: " ")): \(text)")
    }
    return text
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else { throw ScreenClipError.message("Cleanup did not reach the expected state") }
  }
}
