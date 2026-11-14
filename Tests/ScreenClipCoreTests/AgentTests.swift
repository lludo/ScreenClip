import XCTest

@testable import ScreenClipCore

final class AgentTests: XCTestCase {
  private let schema: JSONValue = .object(["type": .string("object")])

  private func request(resume: Bool, executable: String = "/usr/bin/true", cwd: String = "/tmp")
    -> ClaudeTurnRequest
  {
    ClaudeTurnRequest(
      executable: executable, cwd: cwd, sessionID: "11111111-2222-3333-4444-555555555555",
      resume: resume, name: "ScreenClip: #7 Label clipped", model: "sonnet", prompt: "Fix it",
      images: [Data([1, 2, 3])], schema: schema)
  }

  func testOlderQueuesDecodeAsCodexIssuesAndSettings() throws {
    var issueJSON = try JSONEncoder().encode(
      Issue(
        projectID: nil, title: "Old",
        capture: Capture(note: "", imagePath: "/x.png", context: CaptureContext())))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: issueJSON) as? [String: Any])
    object.removeValue(forKey: "agent")
    issueJSON = try JSONSerialization.data(withJSONObject: object)
    let issue = try JSONDecoder().decode(Issue.self, from: issueJSON)
    XCTAssertNil(issue.agent)
    XCTAssertEqual(issue.resolvedAgent, .codex)

    var settings = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
    for key in ["claudePath", "claudeModel", "defaultAgent"] { settings.removeValue(forKey: key) }
    let decoded = try JSONDecoder().decode(
      AppSettings.self, from: JSONSerialization.data(withJSONObject: settings))
    XCTAssertEqual(decoded.preferredAgent, .codex)
  }

  func testAgentSpecificLinks() {
    var issue = Issue(
      projectID: nil, title: "T",
      capture: Capture(note: "", imagePath: "/x.png", context: CaptureContext()), agent: .claude)
    issue.threadID = "abc"
    issue.worktreePath = "/tmp/it's here"
    XCTAssertNil(issue.codexURL)
    XCTAssertEqual(issue.claudeResumeCommand, "cd '/tmp/it'\\''s here' && claude --resume 'abc'")
    issue.agent = .codex
    XCTAssertNil(issue.claudeResumeCommand)
    XCTAssertEqual(issue.codexURL?.absoluteString, "codex://threads/abc")
  }

  func testArgumentsCreateThenResumeOneSessionWithSandboxAndSchema() throws {
    let created = ClaudeCodeClient.arguments(for: request(resume: false))
    XCTAssertTrue(created.starts(with: ["-p", "--input-format", "stream-json"]))
    XCTAssertEqual(
      created[created.firstIndex(of: "--session-id")! + 1], "11111111-2222-3333-4444-555555555555")
    XCTAssertFalse(created.contains("--resume"))
    XCTAssertEqual(created[created.firstIndex(of: "--model")! + 1], "sonnet")
    XCTAssertEqual(created[created.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
    let settings = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(created[created.firstIndex(of: "--settings")! + 1].utf8))
    XCTAssertEqual(settings["sandbox"]["enabled"].bool, true)
    XCTAssertEqual(settings["sandbox"]["allowUnsandboxedCommands"].bool, false)
    // The variadic tool list must be followed by another flag, not swallow the next value.
    let tools = created.firstIndex(of: "--disallowedTools")!
    XCTAssertEqual(Array(created[(tools + 1)...(tools + 2)]), ClaudeCodeClient.disallowedTools)
    XCTAssertTrue(created[tools + 3].hasPrefix("--"))

    let resumed = ClaudeCodeClient.arguments(for: request(resume: true))
    XCTAssertEqual(
      resumed[resumed.firstIndex(of: "--resume")! + 1], "11111111-2222-3333-4444-555555555555")
    XCTAssertFalse(resumed.contains("--session-id"))
  }

  func testUserMessageCarriesPromptAndScreenshots() {
    let message = ClaudeCodeClient.userMessage(for: request(resume: false))
    XCTAssertEqual(message["type"].string, "user")
    let content = message["message"]["content"].array
    XCTAssertEqual(content.first?["text"].string, "Fix it")
    XCTAssertEqual(content.last?["source"]["data"].string, Data([1, 2, 3]).base64EncodedString())
    XCTAssertEqual(content.last?["source"]["media_type"].string, "image/png")
  }

  func testResultParsingPrefersStructuredOutputAndFallsBackToFencedJSON() throws {
    let structured = ClaudeCodeClient.parseResult(
      .object([
        "type": .string("result"), "subtype": .string("success"), "is_error": .bool(false),
        "result": .string("Done"), "session_id": .string("s"), "total_cost_usd": .number(0.42),
        "usage": .object([
          "input_tokens": .number(10), "cache_read_input_tokens": .number(90),
          "output_tokens": .number(5),
        ]),
        "structured_output": .object([
          "outcome": .string("implemented"), "summary": .string("Fixed"), "question": .string(""),
        ]),
        "permission_denials": .array([
          .object([
            "tool_name": .string("Bash"), "tool_input": .object(["command": .string("npm i")]),
          ])
        ]),
      ]), sessionID: nil)
    XCTAssertFalse(structured.isError)
    XCTAssertEqual(structured.inputTokens, 100)
    XCTAssertEqual(structured.permissionDenials, ["Bash: npm i"])
    XCTAssertEqual(structured.usageSummary, "100 in / 5 out tokens · $0.42")
    let report = try JSONDecoder().decode(
      JSONValue.self, from: Data(try XCTUnwrap(structured.outputJSON).utf8))
    XCTAssertEqual(report["summary"].string, "Fixed")

    let fenced = ClaudeCodeClient.parseResult(
      .object([
        "type": .string("result"),
        "result": .string("```json\n{\"outcome\":\"question\",\"summary\":\"\",\"question\":\"Wrap?\"}\n```"),
      ]), sessionID: "init-session")
    XCTAssertEqual(fenced.sessionID, "init-session")
    XCTAssertTrue(try XCTUnwrap(fenced.outputJSON).contains("Wrap?"))
    XCTAssertNil(
      ClaudeCodeClient.parseResult(
        .object(["result": .string("Not logged in"), "is_error": .bool(true)]), sessionID: nil
      ).outputJSON)
  }

  func testRunStreamsProgressAndReturnsResultFromFakeCLI() async throws {
    let root = try temporaryDirectory()
    let script = try fakeClaude(
      in: root,
      body: """
        line = sys.stdin.readline()
        open(os.path.join(here, 'stdin.json'), 'w').write(line)
        open(os.path.join(here, 'args.json'), 'w').write(json.dumps(sys.argv[1:]))
        send({'type':'system','subtype':'init','session_id':'11111111-2222-3333-4444-555555555555'})
        send({'type':'assistant','message':{'content':[{'type':'text','text':'Looking at the label'},{'type':'tool_use','name':'Read','input':{}}]}})
        send({'type':'result','subtype':'success','is_error':False,'result':'','session_id':'11111111-2222-3333-4444-555555555555','usage':{'input_tokens':3,'output_tokens':4},'structured_output':{'outcome':'implemented','summary':'Wrapped the label','question':''}})
        """)
    let progress = ProgressLog()
    let result = try await ClaudeCodeClient().run(
      request(resume: false, executable: script.path, cwd: root.path)
    ) { await progress.add($0) }
    XCTAssertEqual(result.structured?["summary"].string, "Wrapped the label")
    let messages = await progress.messages
    XCTAssertEqual(messages, ["Looking at the label"])
    let stdin = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("stdin.json")))
    XCTAssertEqual(stdin["message"]["content"].array.count, 2)
  }

  func testRunWithoutResultReportsStderr() async throws {
    let root = try temporaryDirectory()
    let script = try fakeClaude(
      in: root, body: "sys.stdin.readline(); sys.stderr.write('boom happened'); sys.exit(3)")
    do {
      _ = try await ClaudeCodeClient().run(
        request(resume: false, executable: script.path, cwd: root.path)
      ) { _ in }
      XCTFail("Expected an error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("boom happened"))
      XCTAssertTrue(error.localizedDescription.contains("status 3"))
    }
  }

  func testCancelTerminatesTheRunningTurn() async throws {
    let root = try temporaryDirectory()
    let script = try fakeClaude(
      in: root, body: "sys.stdin.readline(); send({'type':'system','subtype':'init'}); time.sleep(30)")
    let client = ClaudeCodeClient()
    let turn = Task {
      try await client.run(request(resume: false, executable: script.path, cwd: root.path)) { _ in }
    }
    let deadline = Date().addingTimeInterval(10)
    while await !client.isRunning(sessionID: "11111111-2222-3333-4444-555555555555"),
      Date() < deadline
    {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    await client.cancel(sessionID: "11111111-2222-3333-4444-555555555555")
    do {
      _ = try await turn.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
  }

  func testDetectsClaudeVersionAndSignInState() async throws {
    let root = try temporaryDirectory()
    let script = try fakeClaude(
      in: root,
      body: """
        if sys.argv[1:] == ['--version']: print('9.9.9 (Claude Code)')
        elif sys.argv[1:] == ['auth','status']: print(json.dumps({'loggedIn': False, 'authMethod': 'none'}))
        """)
    let found = await AgentDetector.detectClaude(path: script.path)
    XCTAssertEqual(found.version, "9.9.9")
    XCTAssertEqual(found.signedIn, false)
    XCTAssertFalse(found.usable)
    XCTAssertEqual(found.label, "Claude Code — signed out")
    let missing = await AgentDetector.detectClaude(path: root.appendingPathComponent("nope").path)
    XCTAssertFalse(missing.installed)
    XCTAssertEqual(missing.label, "Claude Code — not found")
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-agent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func fakeClaude(in root: URL, body: String) throws -> URL {
    let script = root.appendingPathComponent("fake-claude")
    let indented = body.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    " + $0 }.joined(separator: "\n")
    try """
      #!/usr/bin/python3
      import sys, json, os, time
      here = os.path.dirname(os.path.abspath(__file__))
      def send(value): print(json.dumps(value), flush=True)
      def main():
      \(indented)
      main()
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
  }
}

private actor ProgressLog {
  var messages: [String] = []
  func add(_ text: String) { messages.append(text) }
}
