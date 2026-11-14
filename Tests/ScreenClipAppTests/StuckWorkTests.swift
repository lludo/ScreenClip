import XCTest

@testable import ScreenClip
@testable import ScreenClipCore

/// Reports must never wait forever: stalled turns stop, signed-out agents hold the queue and
/// resume on their own, a restart continues Claude work, and Grok Bot silence is surfaced.
@MainActor final class StuckWorkTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-stuck-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testStalledCodexTurnIsStoppedAfterTheTimeLimit() async throws {
    let codex = try script(
      "fake-codex",
      """
      #!/usr/bin/python3
      import sys,json,os
      here=os.path.dirname(os.path.abspath(__file__))
      def send(value): print(json.dumps(value),flush=True)
      for line in sys.stdin:
          m=json.loads(line)
          if 'id' not in m: continue
          with open(os.path.join(here,'requests.jsonl'),'a') as log: log.write(line)
          method=m.get('method'); result={}
          if method=='project/list': result={'data':[],'nextCursor':None}
          if method=='thread/start': result={'thread':{'id':'stalled-thread','status':{'type':'idle'}}}
          if method=='turn/start': result={'turn':{'id':'turn-1'}}
          send({'id':m['id'],'result':result})
          # turn/completed never arrives.
      """)
    let model = try makeModel()
    model.worker.turnTimeLimit = 0.5
    try model.commit {
      $0.settings.codexPath = codex
      $0.settings.paused = false
    }
    let id = try submit(model, agent: .codex)
    try await wait { model.issue(id)?.status == .failed }
    XCTAssertTrue(model.issue(id)?.lastError?.contains("did not finish") == true)
    XCTAssertNil(model.issue(id)?.turnID)
    XCTAssertFalse(model.worker.isActive(id))
    try await wait { self.requests().contains { $0["method"].string == "turn/interrupt" } }
    await model.worker.resetConnection()
  }

  func testCodexWatchdogDoesNotExpireImmediatelyAfterAUserReply() async throws {
    let model = try makeModel()
    let id = try submit(model, agent: .codex)
    try model.updateIssue(id) {
      $0.threadID = "thread"
      $0.turnID = "turn"
      $0.record("Working", status: .working)
    }
    model.worker.jobs.insert(id)
    model.worker.turnTimeLimit = 0.6
    model.worker.watchCodexTurn(id, threadID: "thread", turnID: "turn")
    defer { model.worker.codexTurnWatchdogs[id]?.cancel() }
    try await Task.sleep(nanoseconds: 200_000_000)
    try model.updateIssue(id) { $0.record("Waiting", status: .needsYou) }
    try await Task.sleep(nanoseconds: 800_000_000)
    try model.updateIssue(id) { $0.record("Replied", status: .working) }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(model.issue(id)?.status, .working)
    XCTAssertTrue(model.worker.jobs.contains(id))
  }

  func testSignedOutClaudeHoldsTheReportAndResumesAfterSignIn() async throws {
    let claude = try script(
      "fake-claude",
      """
      #!/usr/bin/python3
      import sys,json,os
      here=os.path.dirname(os.path.abspath(__file__))
      if '--version' in sys.argv: print('9.9.9 (Claude Code)'); sys.exit(0)
      if 'auth' in sys.argv: print(json.dumps({'loggedIn':True,'authMethod':'claude.ai'})); sys.exit(0)
      sys.stdin.readline()
      with open(os.path.join(here,'runs'),'a') as log: log.write('run\\n')
      runs=sum(1 for _ in open(os.path.join(here,'runs')))
      def send(value): print(json.dumps(value),flush=True)
      if runs==1:
          send({'type':'result','subtype':'success','is_error':True,'result':'Not logged in · Please run /login'})
          sys.exit(1)
      send({'type':'result','subtype':'success','is_error':False,'result':'','structured_output':{'outcome':'question','summary':'','question':'Which width?'}})
      """)
    let model = try makeModel()
    model.worker.heldRecheckInterval = 0
    try model.commit {
      $0.settings.claudePath = claude
      $0.settings.paused = false
    }
    let id = try submit(model, agent: .claude)
    try await wait {
      model.issue(id)?.status == .queued
        && model.issue(id)?.activities.last?.text.contains("signed out") == true
    }
    XCTAssertEqual(model.detection(.claude)?.signedIn, false)
    XCTAssertNil(model.issue(id)?.lastError)

    // `claude auth status` still says signed in, so the automatic check keeps the hold for a while
    // rather than failing the report again every minute.
    await model.worker.recheckHeldAgents()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(model.issue(id)?.status, .queued)
    XCTAssertEqual(runs(), 1)

    // Detect agents clears the hold and the report runs again.
    await model.refreshAgents()
    try await wait { model.issue(id)?.status == .needsYou }
    XCTAssertEqual(runs(), 2)
    XCTAssertEqual(model.issue(id)?.questions.last?.title, "Which width?")
  }

  func testHeldReportResumesWhenTheAgentAppears() async throws {
    let model = try makeModel()
    model.worker.heldRecheckInterval = 0
    let claude = root.appendingPathComponent("fake-claude").path
    try model.commit {
      $0.settings.claudePath = claude
      $0.settings.paused = false
    }
    model.agents = [
      AgentDetection(kind: .claude, path: claude, version: nil, signedIn: nil, detail: "not found")
    ]
    let id = try submit(model, agent: .claude)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(model.issue(id)?.status, .queued)

    // Installing Claude Code later is noticed without visiting Settings.
    _ = try script(
      "fake-claude",
      """
      #!/usr/bin/python3
      import sys,json
      if '--version' in sys.argv: print('9.9.9 (Claude Code)'); sys.exit(0)
      if 'auth' in sys.argv: print(json.dumps({'loggedIn':True})); sys.exit(0)
      sys.stdin.readline()
      print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':'','structured_output':{'outcome':'question','summary':'','question':'Ready?'}}),flush=True)
      """)
    await model.worker.recheckHeldAgents()
    try await wait { model.issue(id)?.status == .needsYou }
  }

  func testRestartContinuesClaudeWorkUnlessItsSessionIsStillRunning() async throws {
    let queue = root.appendingPathComponent("queue")
    let (idle, busy, busySession) = try prepareInterruptedClaudeWork(queue: queue)
    let survivor = Process()
    survivor.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    survivor.arguments = ["-c", "import time; time.sleep(30)", "--session-id", busySession]
    try survivor.run()
    defer { survivor.terminate() }

    let relaunched = try AppModel(root: queue)
    relaunched.loadExternalAssistant = { .empty }
    XCTAssertEqual(relaunched.issue(idle)?.status, .needsYou)
    await relaunched.worker.recoverClaudeAfterRestart()
    XCTAssertEqual(relaunched.issue(idle)?.status, .queued)
    XCTAssertTrue(
      relaunched.issue(idle)?.activities.last?.text.contains("continuing the same session") == true)
    XCTAssertNotNil(relaunched.issue(idle)?.threadID)
    XCTAssertEqual(relaunched.issue(busy)?.status, .needsYou)
    XCTAssertEqual(relaunched.issue(busy)?.activities.last?.text, AppModel.restartActivity)
  }

  func testStaleWorkingReportDoesNotHoldAParallelSlot() async throws {
    let model = try makeModel()
    try model.commit {
      $0.settings.maxParallelReports = 1
      $0.settings.claudePath = self.root.appendingPathComponent("missing-claude").path
    }
    let stale = try submit(model, agent: .claude)
    try model.updateIssue(stale) { $0.record("Left over", status: .working) }
    let next = try submit(model, agent: .claude)
    try model.commit { $0.settings.paused = false }
    model.worker.pump()
    // It is dispatched (and fails on the missing executable) instead of waiting behind `stale`.
    try await wait { model.issue(next)?.status == .failed }
  }

  func testGrokBotSilenceIsSurfacedAndTheLaterPullRequestIsStillFound() async throws {
    let output = root.appendingPathComponent("gh-output")
    try "[]".write(to: output, atomically: true, encoding: .utf8)
    let gh = try script("fake-gh", "#!/bin/sh\ncat '\(output.path)'\n")
    let model = try makeModel()
    model.loadExternalAssistant = {
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
        testSucceeded: false)
    }
    var project = try XCTUnwrap(model.snapshot.projects.first)
    project.allowExternalScreenshots = true
    try model.saveProject(project)
    try model.commit { $0.settings.ghPath = gh }
    let id = try submit(model, agent: .external)
    let branch = "screenclip/1-report-abc"
    try model.updateIssue(id) {
      $0.branch = branch
      $0.worktreePath = self.root.path
      $0.record(ExternalAssistant.sentActivity, status: .working)
      $0.activities[$0.activities.count - 1].date = Date().addingTimeInterval(-3 * 60 * 60)
    }
    let number = try XCTUnwrap(model.issue(id)?.reportNumber)

    await model.worker.discoverExternalPullRequests()
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertEqual(model.issue(id)?.lastError, ExternalAssistant.noPullRequestActivity)
    XCTAssertEqual(model.issue(id)?.unread, true)

    let pull: [String: String] = [
      "url": "https://github.com/o/r/pull/7", "headRefName": branch,
      "body": "Fixes ScreenClip: #\(number)", "state": "OPEN",
    ]
    try JSONSerialization.data(withJSONObject: [pull]).write(to: output)
    await model.worker.discoverExternalPullRequests()
    XCTAssertEqual(model.issue(id)?.status, .prOpen)
    XCTAssertEqual(model.issue(id)?.prURL, "https://github.com/o/r/pull/7")
    XCTAssertNil(model.issue(id)?.lastError)
  }

  // MARK: - Helpers

  /// Two Claude reports left working when the app quit. The model is released on return.
  private func prepareInterruptedClaudeWork(queue: URL) throws -> (UUID, UUID, String) {
    let model = try makeModel(queue: queue)
    let idle = try submit(model, agent: .claude)
    let busy = try submit(model, agent: .claude)
    let busySession = UUID().uuidString.lowercased()
    try model.updateIssue(idle) {
      $0.threadID = UUID().uuidString.lowercased()
      $0.turnID = "claude:" + ($0.threadID ?? "")
      $0.record("Investigating", status: .working)
    }
    try model.updateIssue(busy) {
      $0.threadID = busySession
      $0.turnID = "claude:" + busySession
      $0.record("Investigating", status: .working)
    }
    return (idle, busy, busySession)
  }

  private func makeModel(queue: URL? = nil) throws -> AppModel {
    let model = try AppModel(root: queue ?? root.appendingPathComponent("queue"))
    model.loadExternalAssistant = { .empty }
    try model.commit {
      $0.settings.paused = true
      $0.settings.codexPath = self.root.appendingPathComponent("missing-codex").path
    }
    if model.snapshot.projects.isEmpty {
      try model.saveProject(Project(name: "Test", path: try makeRepository()))
    }
    return model
  }

  private func submit(_ model: AppModel, agent: AgentKind) throws -> UUID {
    let project = try XCTUnwrap(model.snapshot.projects.first)
    let before = Set(model.snapshot.issues.map(\.id))
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Label clipped",
      context: CaptureContext(appName: "Test"), projectID: project.id, existingID: nil,
      draft: false, agent: agent)
    return try XCTUnwrap(model.snapshot.issues.first { !before.contains($0.id) }?.id)
  }

  private func makeRepository() throws -> String {
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    for arguments in [
      ["init", "-q", "-b", "main"],
      ["-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid", "commit", "-q",
       "--allow-empty", "-m", "initial"],
    ] {
      let git = Process()
      git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      git.arguments = arguments
      git.currentDirectoryURL = repo
      try git.run()
      git.waitUntilExit()
    }
    return repo.path
  }

  @discardableResult private func script(_ name: String, _ source: String) throws -> String {
    let url = root.appendingPathComponent(name)
    try source.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url.path
  }

  private func requests() -> [JSONValue] {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("requests.jsonl")) else {
      return []
    }
    return data.split(separator: 10).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
  }

  private func runs() -> Int {
    ((try? String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8)) ?? "")
      .split(separator: "\n").count
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else { throw ScreenClipError.message("Worker did not reach the expected state") }
  }
}
