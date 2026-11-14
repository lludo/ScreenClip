import XCTest

@testable import ScreenClipCore

final class ClaudeCodeClientTests: XCTestCase {
  private func fixture(_ body: String) throws -> ClaudeTurnRequest {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-claude-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fake-claude")
    try ("#!/usr/bin/python3\nimport json,sys,os\nmessage=json.loads(sys.stdin.readline())\n" + body)
      .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return ClaudeTurnRequest(
      executable: executable.path, cwd: root.path, sessionID: UUID().uuidString, resume: false,
      prompt: "Inspect this capture", images: [Data([1, 2, 3])],
      schema: .object(["type": .string("object")]))
  }

  func testTurnSendsEvidenceAndParsesProgressStructuredOutputAndUsage() async throws {
    let request = try fixture("""
      assert message['message']['content'][0]['text']=='Inspect this capture'
      assert message['message']['content'][1]['source']['data']=='AQID'
      assert '--session-id' in sys.argv and '--resume' not in sys.argv
      print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'Inspecting'}]}}),flush=True)
      print(json.dumps({'type':'result','subtype':'success','session_id':'session',
        'structured_output':{'outcome':'question'},'usage':{'input_tokens':2,
        'cache_creation_input_tokens':3,'cache_read_input_tokens':4,'output_tokens':5}}),flush=True)
      """)
    let progress = ProgressLog()
    let result = try await ClaudeCodeClient().run(request) { await progress.append($0) }
    XCTAssertEqual(result.structured?["outcome"].string, "question")
    XCTAssertEqual(result.sessionID, "session")
    XCTAssertEqual(result.inputTokens, 9)
    XCTAssertEqual(result.outputTokens, 5)
    XCTAssertFalse(result.isError)
    let messages = await progress.messages
    XCTAssertEqual(messages, ["Inspecting"])
  }

  func testTurnAcceptsFinalResultWithoutTrailingNewline() async throws {
    let request = try fixture("""
      sys.stdout.write(json.dumps({'type':'result','subtype':'success','result':'{}'}))
      """)
    let result = try await ClaudeCodeClient().run(request) { _ in }
    XCTAssertEqual(result.outputJSON, "{}")
  }

  func testNonzeroExitCannotReturnASuccessfulTurn() async throws {
    let request = try fixture("""
      print(json.dumps({'type':'result','subtype':'success','result':'{}'}),flush=True)
      sys.exit(3)
      """)
    do {
      _ = try await ClaudeCodeClient().run(request) { _ in }
      XCTFail("A failed process must not be reported as a successful turn")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("status 3"))
    }
  }

  func testFailureDrainsStderrBeforeReportingItsFinalMessage() async throws {
    let request = try fixture("""
      sys.stderr.write('x' * 128000 + ' final failure detail')
      sys.exit(3)
      """)
    do {
      _ = try await ClaudeCodeClient().run(request) { _ in }
      XCTFail("Expected a process failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.hasSuffix("final failure detail"))
      XCTAssertTrue(error.localizedDescription.contains("status 3"))
    }
  }

  func testUnstructuredOutputWithReversedBracesHasNoJSON() {
    let result = ClaudeCodeClient.parseResult(.object(["result": .string("} then {")]), sessionID: nil)
    XCTAssertNil(result.outputJSON)
  }

  func testResumeCommandQuotesBothDirectoryAndSession() async throws {
    let request = try fixture("pass\n")
    let directory = URL(fileURLWithPath: request.cwd).appendingPathComponent("a'b")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var issue = Issue(
      projectID: nil, title: "Test",
      capture: Capture(note: "", imagePath: "", context: CaptureContext()), agent: .claude)
    issue.worktreePath = directory.path
    issue.threadID = "session; printf injected"
    let command = try XCTUnwrap(issue.claudeResumeCommand)
    let output = try await CommandRunner.checked(
      "/bin/sh", ["-c", "claude() { printf '%s' \"$2\"; }; " + command])
    XCTAssertEqual(output, issue.threadID)
  }

  // MARK: Claude Desktop hand-off

  private func fakeCLI(version: String, body: String = "") throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-desktop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fake-claude")
    try """
      #!/bin/sh
      if [ "$1" = "--version" ]; then echo "\(version) (Claude Code)"; exit 0; fi
      \(body)
      """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable.path
  }

  func testDesktopSupportClassifiesVersions() {
    XCTAssertEqual(ClaudeDesktopSupport.classify(versionOutput: "2.1.128 (Claude Code)"), .unsupported(version: "2.1.128"))
    XCTAssertEqual(ClaudeDesktopSupport.classify(versionOutput: "2.1.284"), .unsupported(version: "2.1.284"))
    XCTAssertEqual(ClaudeDesktopSupport.classify(versionOutput: "2.1.285"), .supported(version: "2.1.285"))
    XCTAssertEqual(ClaudeDesktopSupport.classify(versionOutput: "2.2.0 (Claude Code)"), .supported(version: "2.2.0"))
    XCTAssertEqual(ClaudeDesktopSupport.classify(versionOutput: "10.0.1"), .supported(version: "10.0.1"))
    XCTAssertEqual(ClaudeDesktopSupport.classify(versionOutput: "garbage"), .unknown)
  }

  func testOpenInDesktopRunsResumeUnderATerminal() async throws {
    let session = UUID().uuidString.lowercased()
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("marker-" + session)
    addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
    // Like the real CLI, refuse when stdout is not a terminal.
    let cli = try fakeCLI(
      version: "2.1.325",
      body: """
        [ -t 1 ] || { echo "--desktop can't run non-interactively" >&2; exit 1; }
        echo "$@" > '\(marker.path)'; pwd >> '\(marker.path)'
        echo "Opening session $3 in Claude Desktop"
        """)
    let cwd = FileManager.default.temporaryDirectory.path
    try await ClaudeCodeClient().openInDesktop(executable: cli, cwd: cwd, sessionID: session)
    let recorded = try String(contentsOf: marker, encoding: .utf8)
    XCTAssertTrue(recorded.hasPrefix("--desktop --resume \(session)\n"))
    XCTAssertTrue(recorded.contains(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().lastPathComponent))
  }

  func testOpenInDesktopRefusesOldCLIWithoutRunningIt() async throws {
    let cli = try fakeCLI(version: "2.1.128", body: "echo ran >&2; exit 9")
    do {
      try await ClaudeCodeClient().openInDesktop(
        executable: cli, cwd: "/tmp", sessionID: UUID().uuidString)
      XCTFail("expected an unsupported-version error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("2.1.285"))
      XCTAssertTrue(error.localizedDescription.contains("Terminal command"))
    }
  }

  func testOpenInDesktopRefusesUnreadableVersionAndBadSession() async throws {
    let cli = try fakeCLI(version: "unknown")
    await XCTAssertThrowsAsync(
      try await ClaudeCodeClient().openInDesktop(executable: cli, cwd: "/tmp", sessionID: UUID().uuidString))
    await XCTAssertThrowsAsync(
      try await ClaudeCodeClient().openInDesktop(executable: cli, cwd: "/tmp", sessionID: "not-a-uuid"))
    await XCTAssertThrowsAsync(
      try await ClaudeCodeClient().openInDesktop(executable: "/nonexistent", cwd: "/tmp", sessionID: UUID().uuidString))
  }

  func testOpenInDesktopSurfacesCLIFailure() async throws {
    let cli = try fakeCLI(version: "2.1.325", body: "echo 'Claude Desktop is not installed' ; exit 1")
    do {
      try await ClaudeCodeClient().openInDesktop(
        executable: cli, cwd: "/tmp", sessionID: UUID().uuidString)
      XCTFail("expected failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("not installed"))
    }
  }

  func testOpenInDesktopRefusesRunningSession() async throws {
    let session = UUID().uuidString.lowercased()
    // A process whose command line carries the session, as a terminal `claude --resume` would.
    let busy = Process()
    busy.executableURL = URL(fileURLWithPath: "/bin/sh")
    busy.arguments = ["-c", "sleep 30; true", "claude", "--resume", session]
    try busy.run()
    addTeardownBlock { busy.terminate() }
    let cli = try fakeCLI(version: "2.1.325", body: "echo 'Opening session x'; exit 0")
    do {
      try await ClaudeCodeClient().openInDesktop(executable: cli, cwd: "/tmp", sessionID: session)
      XCTFail("expected refusal")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("still running"))
    }
  }
}

private func XCTAssertThrowsAsync<T>(
  _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected an error", file: file, line: line)
  } catch {}
}

private actor ProgressLog {
  var messages: [String] = []
  func append(_ text: String) { messages.append(text) }
}
