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
}

private actor ProgressLog {
  var messages: [String] = []
  func append(_ text: String) { messages.append(text) }
}
