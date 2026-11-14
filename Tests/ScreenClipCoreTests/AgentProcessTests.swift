import XCTest

@testable import ScreenClipCore

/// A Claude Code turn must always end: cancel, the time limit, and a process that leaves
/// children behind cannot keep ScreenClip waiting.
final class AgentProcessTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-process-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    // Background processes the scripts started write their PIDs here.
    let pids = (try? String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8)) ?? ""
    for pid in pids.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(at: root)
  }

  private func request(
    _ body: String, images: [Data] = [Data([1, 2, 3])], timeout: TimeInterval = 45 * 60
  ) throws -> ClaudeTurnRequest {
    let executable = root.appendingPathComponent("fake-claude-" + UUID().uuidString)
    try ("#!/usr/bin/python3\nimport json,os,signal,subprocess,sys,time\nhere='\(root.path)'\n" + body)
      .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var request = ClaudeTurnRequest(
      executable: executable.path, cwd: root.path, sessionID: UUID().uuidString, resume: false,
      prompt: "Inspect this capture", images: images, schema: .object(["type": .string("object")]))
    request.timeout = timeout
    return request
  }

  func testCancelStopsAClaudeThatIgnoresSIGTERMAlongWithItsChildren() async throws {
    let request = try request("""
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      sys.stdin.readline()
      child=subprocess.Popen(['/bin/sleep','60'])
      open(os.path.join(here,'pids'),'a').write(str(child.pid)+'\\n')
      print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'Working'}]}}),flush=True)
      time.sleep(60)
      """)
    let client = ClaudeCodeClient()
    let progress = Messages()
    let started = Date()
    let run = Task { try await client.run(request) { await progress.append($0) } }
    while await progress.isEmpty, Date().timeIntervalSince(started) < 10 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    await client.cancel(sessionID: request.sessionID)
    do {
      _ = try await run.value
      XCTFail("A canceled turn must not return a result")
    } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    let isRunning = await client.isRunning(sessionID: request.sessionID)
    XCTAssertFalse(isRunning)
  }

  func testTimeLimitStopsAClaudeThatIgnoresSIGTERM() async throws {
    let request = try request(
      """
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      sys.stdin.readline()
      time.sleep(60)
      """, timeout: 1)
    let started = Date()
    do {
      _ = try await ClaudeCodeClient().run(request) { _ in }
      XCTFail("Expected the time limit to stop the turn")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("was stopped"), error.localizedDescription)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 12)
  }

  func testTurnReturnsWhenABackgroundProcessKeepsItsOutputOpen() async throws {
    // The shell exits at once; its background sleep is reparented and still holds the pipes.
    let request = try request("""
      sys.stdin.readline()
      subprocess.run(['/bin/sh','-c','/bin/sleep 60 & echo $! >> "$0"', os.path.join(here,'pids')])
      print(json.dumps({'type':'result','subtype':'success','result':'{}'}),flush=True)
      """)
    let started = Date()
    let result = try await ClaudeCodeClient().run(request) { _ in }
    XCTAssertEqual(result.outputJSON, "{}")
    XCTAssertLessThan(Date().timeIntervalSince(started), 12)
  }

  func testClaudeExitingBeforeReadingLargeEvidenceDoesNotCrashScreenClip() async throws {
    // Without SIGPIPE ignored, writing megabytes to a closed pipe terminates the test runner.
    let request = try request("sys.exit(3)\n", images: [Data(count: 8_000_000)])
    do {
      _ = try await ClaudeCodeClient().run(request) { _ in }
      XCTFail("Expected a process failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("status 3"), error.localizedDescription)
    }
  }

  func testLoginShellPathIsExtractedFromNoisyShellOutput() {
    XCTAssertEqual(
      ProcessEnvironment.extractPath(
        from: "Welcome!\n__M__/Users/x/.nvm/bin:/usr/bin__M__", marker: "__M__"),
      "/Users/x/.nvm/bin:/usr/bin")
    XCTAssertNil(ProcessEnvironment.extractPath(from: "no marker", marker: "__M__"))
  }

  func testSearchPathAddsLoginShellFoldersWithoutDuplicates() {
    let path = ProcessEnvironment.path(
      base: "/usr/bin:/inherited/bin", login: "/login/node/bin:/usr/bin"
    ).split(separator: ":").map(String.init)
    XCTAssertEqual(path.first, "/opt/homebrew/bin")
    XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
    let login = try? XCTUnwrap(path.firstIndex(of: "/login/node/bin"))
    let inherited = try? XCTUnwrap(path.firstIndex(of: "/inherited/bin"))
    XCTAssertNotNil(login)
    XCTAssertNotNil(inherited)
    XCTAssertLessThan(login ?? .max, inherited ?? .max)
  }

  func testSignInErrorsAreRecognized() {
    XCTAssertTrue(AgentDetector.isSignInError("Not logged in · Please run /login"))
    XCTAssertTrue(AgentDetector.isSignInError("Invalid API key · Please run /login"))
    XCTAssertTrue(AgentDetector.isSignInError("unexpected status 401 Unauthorized"))
    XCTAssertFalse(AgentDetector.isSignInError("Tests failed: 3 of 120"))
  }
}

private actor Messages {
  var values: [String] = []
  func append(_ text: String) { values.append(text) }
  var isEmpty: Bool { values.isEmpty }
}
