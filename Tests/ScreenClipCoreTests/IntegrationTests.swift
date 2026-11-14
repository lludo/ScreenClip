import XCTest

@testable import ScreenClipCore

final class IntegrationTests: XCTestCase {
  func testBaseAdvanceIsFetchedAndAppliedBeforeRevalidation() async throws {
    let source = try await repo()
    let bare = source.appendingPathComponent("origin.git")
    _ = try await CommandRunner.checked("/usr/bin/git", ["init", "--bare", bare.path])
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["remote", "add", "origin", bare.path], cwd: source.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["push", "-u", "origin", "main"], cwd: source.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["config", "user.name", "ScreenClip Test"], cwd: source.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["config", "user.email", "test@example.invalid"], cwd: source.path)
    let root = source.appendingPathComponent("data")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
    let project = Project(name: "Test", path: source.path)
    let workspace = try await GitWorkspace.prepare(project: project, issueID: UUID(), root: root)
    try Data("base advanced".utf8).write(to: source.appendingPathComponent("base.txt"))
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "base.txt"], cwd: source.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["commit", "-m", "Advance base"], cwd: source.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["push", "origin", "main"], cwd: source.path)
    let updated = try await GitHubService.updateBaseIfNeeded(project: project, path: workspace.path)
    XCTAssertTrue(updated)
    XCTAssertEqual(
      try String(
        contentsOf: URL(fileURLWithPath: workspace.path).appendingPathComponent("base.txt"),
        encoding: .utf8), "base advanced")
    let repeated = try await GitHubService.updateBaseIfNeeded(
      project: project, path: workspace.path)
    XCTAssertFalse(repeated)
  }
  func repo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-git-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    _ = try await CommandRunner.checked("/usr/bin/git", ["init", "-b", "main"], cwd: url.path)
    try Data("initial\n".utf8).write(to: url.appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "source.txt"], cwd: url.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git",
      [
        "-c", "user.name=ScreenClip Test", "-c", "user.email=test@example.invalid", "commit", "-m",
        "initial",
      ], cwd: url.path)
    return url
  }
  func testWorktreePreservesTesterDirtyCheckoutAndIsRecoverable() async throws {
    let source = try await repo()
    let root = source.appendingPathComponent("data")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
    try Data("tester edits\n".utf8).write(to: source.appendingPathComponent("source.txt"))
    let project = Project(name: "Test", path: source.path)
    let id = UUID()
    let first = try await GitWorkspace.prepare(project: project, issueID: id, root: root)
    let second = try await GitWorkspace.prepare(project: project, issueID: id, root: root)
    XCTAssertEqual(first.path, second.path)
    XCTAssertEqual(
      try String(contentsOf: source.appendingPathComponent("source.txt"), encoding: .utf8),
      "tester edits\n")
    XCTAssertEqual(
      try String(
        contentsOf: URL(fileURLWithPath: first.path).appendingPathComponent("source.txt"),
        encoding: .utf8), "initial\n")
  }
  func testFingerprintCoversUntrackedEditsAndDeletions() async throws {
    let url = try await repo()
    let first = try await GitWorkspace.fingerprint(path: url.path)
    try Data("new".utf8).write(to: url.appendingPathComponent("new.txt"))
    let second = try await GitWorkspace.fingerprint(path: url.path)
    XCTAssertNotEqual(first, second)
    try FileManager.default.removeItem(at: url.appendingPathComponent("source.txt"))
    let third = try await GitWorkspace.fingerprint(path: url.path)
    XCTAssertNotEqual(second, third)
  }
  func testValidationRefusesSourceChangesDuringChecks() async throws {
    let url = try await repo()
    let project = Project(
      name: "Test", path: url.path, validationCommand: "printf changed > source.txt")
    do {
      _ = try await GitHubService.validate(project: project, path: url.path)
      XCTFail("Changing source during checks must invalidate validation")
    } catch { XCTAssertTrue(error.localizedDescription.contains("changed during validation")) }
  }
  func testJSONRPCConcurrentRequestsAndTimeout() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-fake-" + UUID().uuidString)
    let script = """
      #!/usr/bin/python3
      import sys,json
      for line in sys.stdin:
          m=json.loads(line)
          if 'id' not in m or m.get('method')=='timeout': continue
          print(json.dumps({'id':m['id'],'result':m.get('params',{})}),flush=True)
      """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let client = CodexClient()
    _ = try await client.connect(path: url.path)
    async let a = client.request("echo", params: .object(["value": .string("first")]))
    async let b = client.request("echo", params: .object(["value": .string("second")]))
    let results = try await (a, b)
    XCTAssertEqual(results.0["value"].string, "first")
    XCTAssertEqual(results.1["value"].string, "second")
    do {
      _ = try await client.request("timeout", timeout: 1)
      XCTFail("Unacknowledged requests must time out")
    } catch { XCTAssertTrue(error.localizedDescription.contains("did not acknowledge")) }
    await client.stop()
  }
}
