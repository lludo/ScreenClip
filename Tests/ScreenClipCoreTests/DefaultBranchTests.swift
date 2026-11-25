import ScreenClipCore
import XCTest

/// Repositories whose default branch is not `main`, like a clone whose origin uses `master`.
final class DefaultBranchTests: XCTestCase {
  private func git(_ arguments: [String], _ cwd: String) async throws {
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["-c", "user.name=T", "-c", "user.email=t@example.invalid"] + arguments, cwd: cwd)
  }

  /// A clone of a `master` repository, with origin/HEAD recorded as a real clone has it.
  private func makeClone(branch: String) async throws -> (root: URL, repo: String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-default-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let seed = root.appendingPathComponent("seed").path
    let remote = root.appendingPathComponent("remote.git").path
    try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
    try await git(["init", "-b", branch], seed)
    try await git(["commit", "--allow-empty", "-m", "initial"], seed)
    try await git(["clone", "--bare", seed, remote], root.path)
    try await git(["clone", remote, "repo"], root.path)
    return (root, root.appendingPathComponent("repo").path)
  }

  func testDetectsTheClonesDefaultBranch() async throws {
    let (_, repo) = try await makeClone(branch: "master")
    let detected = await GitWorkspace.defaultBranch(at: repo)
    XCTAssertEqual(detected, "master")
    let hasMaster = await GitWorkspace.branchExists("master", at: repo)
    let hasMain = await GitWorkspace.branchExists("main", at: repo)
    XCTAssertTrue(hasMaster)
    XCTAssertFalse(hasMain)
  }

  func testWithoutAnOriginTheOnlyCommonBranchWins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-local-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let repo = root.path
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try await git(["init", "-b", "master"], repo)
    try await git(["commit", "--allow-empty", "-m", "initial"], repo)
    try await git(["switch", "-c", "feature"], repo)
    let detected = await GitWorkspace.defaultBranch(at: repo)
    XCTAssertEqual(detected, "master")
    let notARepository = await GitWorkspace.defaultBranch(at: FileManager.default.temporaryDirectory.path)
    XCTAssertNil(notARepository)
  }

  func testAMissingBaseBranchFailsWithTheBranchToUse() async throws {
    let (root, repo) = try await makeClone(branch: "master")
    let project = Project(name: "Quantified", path: repo)  // defaults to "main"
    do {
      _ = try await GitWorkspace.prepare(project: project, issueID: UUID(), root: root.appendingPathComponent("queue"))
      XCTFail("prepare should refuse a base branch the repository does not have")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("Quantified has no branch “main”"), message)
      XCTAssertTrue(message.contains("Its default branch is “master”"), message)
      XCTAssertFalse(message.contains("invalid reference"), message)
    }
    var fixed = project
    fixed.baseBranch = "master"
    let workspace = try await GitWorkspace.prepare(
      project: fixed, issueID: UUID(), root: root.appendingPathComponent("queue"))
    XCTAssertTrue(workspace.branch.hasPrefix("screenclip/"))
  }
}
