import XCTest

@testable import ScreenClipCore

/// Regressions for publishing safety, routing, process handling, and action rules.
final class SafetyTests: XCTestCase {
  func testMostSpecificWebsiteRuleWinsAndSchemeIsCaseInsensitive() {
    let site = Project(name: "Site", path: "/s", origins: ["localhost:3000"])
    let admin = Project(name: "Admin", path: "/a", origins: ["HTTP://localhost:3000/admin"])
    func route(_ url: String) -> UUID? {
      ProjectRouter.infer(CaptureContext(browserURL: url), projects: [site, admin]).projectID
    }
    XCTAssertEqual(route("http://localhost:3000/admin/users"), admin.id)
    XCTAssertEqual(route("http://localhost:3000/pricing"), site.id)
    XCTAssertNil(route("http://localhost:4000/"))
    let twin = Project(name: "Twin", path: "/t", origins: ["localhost:3000"])
    XCTAssertNil(
      ProjectRouter.infer(
        CaptureContext(browserURL: "http://localhost:3000/"), projects: [site, twin]
      ).projectID, "Equally specific rules stay ambiguous")
  }

  func testOnlyRealGitHubRemotesArePublishable() {
    for remote in [
      "https://github.com/owner/repo.git", "git@github.com:owner/repo.git",
      "ssh://git@github.com/owner/repo.git", "https://GitHub.com/owner/repo",
    ] {
      XCTAssertTrue(GitHubService.isGitHubRemote(remote), remote)
    }
    for remote in [
      "https://github.com.evil.example/owner/repo", "https://host.example/github.com/x",
      "git@gitlab.com:owner/repo.git", "github.com", "",
    ] {
      XCTAssertFalse(GitHubService.isGitHubRemote(remote), remote)
    }
  }

  func testValidationCommandSecretsAreRedactedInPRBodies() {
    let redacted = GitHubService.redactSecrets(
      "API_TOKEN=abc123 TOKEN=\"two words\" make test --token ghp_" + String(repeating: "a", count: 36))
    XCTAssertEqual(redacted, "API_TOKEN=… TOKEN=… make test --token …")
    XCTAssertEqual(GitHubService.redactSecrets("swift test"), "swift test")
  }

  func testDeleteIsRefusedWhileAnAgentMayUseTheEvidence() {
    var issue = Issue(
      projectID: UUID(), title: "T",
      capture: Capture(note: "", imagePath: "/x.png", context: CaptureContext()))
    for status in [IssueStatus.queued, .working, .needsYou, .prOpen] {
      issue.status = status
      XCTAssertFalse(issue.canDelete, status.rawValue)
    }
    for status in [IssueStatus.draft, .failed, .canceled, .merged, .verified] {
      issue.status = status
      XCTAssertTrue(issue.canDelete, status.rawValue)
    }
    issue.dispatchUncertain = true
    XCTAssertFalse(issue.canDelete)
  }

  func testAgentEnvironmentDropsCredentialsAndGitRedirects() {
    let base = [
      "PATH": "/usr/bin", "GH_TOKEN": "x", "GITHUB_TOKEN": "y", "GIT_DIR": "/elsewhere",
      "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s", "HOME": "/Users/me",
    ]
    let agent = ProcessEnvironment.agent(base)
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "GIT_DIR", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID"] {
      XCTAssertNil(agent[key], key)
    }
    XCTAssertEqual(agent["HOME"], "/Users/me")
    XCTAssertEqual(agent["GIT_TERMINAL_PROMPT"], "0")
    XCTAssertTrue(agent["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
    // ScreenClip's own tools keep credentials (gh needs them) but not git redirects.
    let tools = ProcessEnvironment.tools(base)
    XCTAssertEqual(tools["GH_TOKEN"], "x")
    XCTAssertNil(tools["GIT_DIR"])
  }

  func testCommandReturnsWhenABackgroundGrandchildKeepsThePipeOpen() async throws {
    let started = Date()
    let result = try await CommandRunner.run(
      "/bin/zsh", ["-c", "sleep 30 & echo done"], timeout: 20)
    XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testTimeoutTerminatesTheWholeProcessTree() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-tree-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    do {
      _ = try await CommandRunner.run(
        "/bin/zsh", ["-c", "(sleep 3; touch '\(marker.path)') & sleep 30"], timeout: 1)
      XCTFail("Expected a timeout")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("timed out"))
    }
    try await Task.sleep(nanoseconds: 3_500_000_000)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: marker.path), "The child kept running after timeout")
  }

  func testNewWorktreesStartFromTheRemoteBaseNotLocalCommits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-base-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = root.appendingPathComponent("remote.git").path
    let repo = root.appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    func git(_ arguments: [String], _ cwd: String) async throws {
      _ = try await CommandRunner.checked(
        "/usr/bin/git",
        ["-c", "user.name=T", "-c", "user.email=t@example.invalid"] + arguments, cwd: cwd)
    }
    try await git(["init", "--bare", "-b", "main", remote], root.path)
    try await git(["init", "-b", "main"], repo)
    try "shared".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["add", "a.txt"], repo)
    try await git(["commit", "-m", "shared"], repo)
    try await git(["remote", "add", "origin", remote], repo)
    try await git(["push", "-u", "origin", "main"], repo)
    try "local only".write(toFile: repo + "/wip.txt", atomically: true, encoding: .utf8)
    try await git(["add", "wip.txt"], repo)
    try await git(["commit", "-m", "unpushed"], repo)
    let project = Project(name: "P", path: repo)
    let workspace = try await GitWorkspace.prepare(
      project: project, issueID: UUID(), root: root.appendingPathComponent("queue"))
    XCTAssertTrue(workspace.branch.hasPrefix("screenclip/"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path + "/a.txt"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: workspace.path + "/wip.txt"),
      "Unpushed local commits must not enter the issue branch")
    let base = await GitWorkspace.baseRef(project: project, path: workspace.path)
    XCTAssertEqual(base, "origin/main")
    let removed = await GitWorkspace.remove(
      path: workspace.path, branch: workspace.branch, repository: repo)
    XCTAssertTrue(removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    let branches = try await CommandRunner.checked("/usr/bin/git", ["branch"], cwd: repo)
    XCTAssertFalse(branches.contains(workspace.branch))
  }
}
