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
    let updated = try await GitWorkspace.updateBaseIfNeeded(project: project, path: workspace.path)
    XCTAssertTrue(updated)
    XCTAssertEqual(
      try String(
        contentsOf: URL(fileURLWithPath: workspace.path).appendingPathComponent("base.txt"),
        encoding: .utf8), "base advanced")
    let repeated = try await GitWorkspace.updateBaseIfNeeded(
      project: project, path: workspace.path)
    XCTAssertFalse(repeated)
  }
  /// A conflicting base is left mid-merge for the agent, whose file edits alone let the next
  /// commit conclude it; without `keepConflicts` the worktree is restored.
  func testConflictingBaseIsKeptForTheAgentAndConcludedByTheNextCommit() async throws {
    let git = "/usr/bin/git"
    let source = try await repo()
    let bare = source.appendingPathComponent("origin.git")
    _ = try await CommandRunner.checked(git, ["init", "--bare", bare.path])
    for arguments in [
      ["remote", "add", "origin", bare.path], ["push", "-u", "origin", "main"],
      ["config", "user.name", "ScreenClip Test"], ["config", "user.email", "test@example.invalid"],
    ] { _ = try await CommandRunner.checked(git, arguments, cwd: source.path) }
    let root = source.appendingPathComponent("data")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
    let project = Project(name: "Test", path: source.path)
    let workspace = try await GitWorkspace.prepare(project: project, issueID: UUID(), root: root)
    let fixed = URL(fileURLWithPath: workspace.path).appendingPathComponent("source.txt")
    try Data("fix\n".utf8).write(to: fixed)
    _ = try await CommandRunner.checked(git, ["commit", "-am", "Fix"], cwd: workspace.path)
    try Data("base\n".utf8).write(to: source.appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked(git, ["commit", "-am", "Advance base"], cwd: source.path)
    _ = try await CommandRunner.checked(git, ["push", "origin", "main"], cwd: source.path)

    do {
      _ = try await GitWorkspace.updateBaseIfNeeded(project: project, path: workspace.path)
      XCTFail("A conflicting base must not merge")
    } catch let conflict as GitWorkspace.BaseConflict {
      XCTAssertEqual(conflict.files, ["source.txt"])
      XCTAssertFalse(conflict.kept)
    }
    let aborted = await GitWorkspace.mergeInProgress(path: workspace.path)
    XCTAssertFalse(aborted)
    XCTAssertEqual(try String(contentsOf: fixed, encoding: .utf8), "fix\n")

    for _ in 1...2 {
      // The second pass finds the merge still in progress and reports it again.
      do {
        _ = try await GitWorkspace.updateBaseIfNeeded(
          project: project, path: workspace.path, keepConflicts: true)
        XCTFail("A conflicting base must not merge")
      } catch let conflict as GitWorkspace.BaseConflict {
        XCTAssertEqual(conflict.files, ["source.txt"])
        XCTAssertTrue(conflict.kept)
        XCTAssertTrue(conflict.agentInstructions.contains("- source.txt"))
      }
    }
    let unresolved = try await GitWorkspace.unresolvedConflicts(path: workspace.path)
    XCTAssertEqual(unresolved, ["source.txt"])
    // The agent only edits the file; ScreenClip's publish adds the paths and commits.
    try Data("base and fix\n".utf8).write(to: fixed)
    let resolved = try await GitWorkspace.unresolvedConflicts(path: workspace.path)
    XCTAssertEqual(resolved, [])
    _ = try await CommandRunner.checked(git, ["add", "--", "source.txt"], cwd: workspace.path)
    _ = try await CommandRunner.checked(git, ["commit", "-m", "Fix: merged"], cwd: workspace.path)
    let concluded = await GitWorkspace.mergeInProgress(path: workspace.path)
    XCTAssertFalse(concluded)
    let parents = try await CommandRunner.checked(
      git, ["rev-list", "--parents", "-n", "1", "HEAD"], cwd: workspace.path)
    XCTAssertEqual(parents.split(separator: " ").count, 3)
    let current = try await GitWorkspace.updateBaseIfNeeded(
      project: project, path: workspace.path, keepConflicts: true)
    XCTAssertFalse(current)
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
    let alias = source.appendingPathExtension("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    addTeardownBlock { try? FileManager.default.removeItem(at: alias) }
    let aliasedProject = Project(name: "Test", path: alias.path)
    let second = try await GitWorkspace.prepare(project: aliasedProject, issueID: id, root: root)
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
      _ = try await GitWorkspace.validate(project: project, path: url.path)
      XCTFail("Changing source during checks must invalidate validation")
    } catch { XCTAssertTrue(error.localizedDescription.contains("changed during validation")) }
  }
  func testFingerprintCoversLeadingSpaceNamesExecutableModesAndDanglingSymlinks() async throws {
    let url = try await repo()
    let spaced = url.appendingPathComponent(" leading-space.txt")
    try Data("first".utf8).write(to: spaced)
    let first = try await GitWorkspace.fingerprint(path: url.path)
    try Data("changed".utf8).write(to: spaced)
    let changed = try await GitWorkspace.fingerprint(path: url.path)
    XCTAssertNotEqual(first, changed)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spaced.path)
    let executable = try await GitWorkspace.fingerprint(path: url.path)
    XCTAssertNotEqual(changed, executable)
    let link = url.appendingPathComponent("broken-link")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "missing-one")
    let broken = try await GitWorkspace.fingerprint(path: url.path)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "missing-two")
    let redirected = try await GitWorkspace.fingerprint(path: url.path)
    XCTAssertNotEqual(broken, redirected)
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
  func testCodexProjectLookupUsesCanonicalRepositoryRootsAndPagination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-project-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
    let script = root.appendingPathComponent("fake-codex")
    try """
    #!/usr/bin/python3
    import sys,json,os
    root=os.path.dirname(__file__)
    scenario='paged'
    def project(id,path): return {'id':id,'name':'Test','roots':[{'path':path}]}
    for line in sys.stdin:
        m=json.loads(line); method=m.get('method'); p=m.get('params',{})
        if 'id' not in m: continue
        result={}
        if method=='scenario': scenario=p['value']
        if method=='project/list':
            if scenario=='unsupported':
                print(json.dumps({'id':m['id'],'error':{'code':-32601,'message':'Method not found'}}),flush=True)
                continue
            result={'data':[project('wrong',os.path.join(root,'repo-other'))],'nextCursor':'page-2'}
            if p.get('cursor'): result={'data':[project('right',os.path.join(root,'alias'))],'nextCursor':None}
            if scenario=='ambiguous': result={'data':[project('one',os.path.join(root,'repo')),project('two',os.path.join(root,'repo'))],'nextCursor':None}
            if scenario=='loop': result={'data':[],'nextCursor':'same-page'}
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let client = CodexClient()
    _ = try await client.connect(path: script.path)
    let match = try await client.projectID(forRepositoryPath: repo.path)
    XCTAssertEqual(match, "right")
    let missing = try await client.projectID(
      forRepositoryPath: root.appendingPathComponent("other").path)
    XCTAssertNil(missing)
    for scenario in ["ambiguous", "loop", "unsupported"] {
      _ = try await client.request("scenario", params: .object(["value": .string(scenario)]))
      do {
        _ = try await client.projectID(forRepositoryPath: repo.path)
        XCTFail("Project lookup must reject \(scenario)")
      } catch {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
    }
    await client.stop()
  }
  func testArchivedThreadCanResumeWithoutRepeatedlyAcquiringWriter() async throws {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-resume-" + UUID().uuidString)
    try """
      #!/usr/bin/python3
      import json,sys
      archived=True
      owned=False
      for line in sys.stdin:
          m=json.loads(line)
          if 'id' not in m: continue
          method=m.get('method'); result={}
          if method=='thread/unarchive': archived=False
          if method=='thread/resume':
              if archived or owned:
                  message='session is archived' if archived else 'already has an active writer'
                  print(json.dumps({'id':m['id'],'error':{'code':-1,'message':message}}),flush=True)
                  continue
              owned=True
          if method in ['thread/read','thread/resume']:
              result={'thread':{'id':'saved','status':{'type':'idle'}}}
          print(json.dumps({'id':m['id'],'result':result}),flush=True)
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    defer { try? FileManager.default.removeItem(at: script) }
    let client = CodexClient()
    _ = try await client.connect(path: script.path)
    let restored = try await client.resumeThread("saved", params: [:])
    XCTAssertEqual(restored["thread"]["id"].string, "saved")
    let repeated = try await client.resumeThread("saved", params: [:])
    XCTAssertEqual(repeated["thread"]["id"].string, "saved")
    await client.stop()
  }
}
