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
          if method=='thread/start': result={'thread':{'id':'stalled-thread','status':{'type':'idle'}},'approvalsReviewer':m['params'].get('approvalsReviewer','user')}
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
      if '--help' in sys.argv: sys.exit(0)
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
      if '--help' in sys.argv: sys.exit(0)
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

  /// The fix was carried on by hand and the worktree deleted; then a restart continued the session.
  func testWorkDoesNotStartInAWorktreeRemovedOutsideScreenClip() async throws {
    let claude = try script(
      "fake-claude",
      """
      #!/usr/bin/python3
      import sys,json,os
      here=os.path.dirname(os.path.abspath(__file__))
      text=json.loads(sys.stdin.readline())['message']['content'][0]['text']
      with open(os.path.join(here,'runs'),'a') as log:
          log.write(('full' if 'Resolve this ScreenClip issue' in text else 'follow-up')+'\\n')
      def send(value): print(json.dumps(value),flush=True)
      send({'type':'system','subtype':'init','session_id':'x'})
      report={'outcome':'question','summary':'','question':'Which width?'}
      send({'type':'result','subtype':'success','is_error':False,'result':'','usage':{'input_tokens':1,'output_tokens':2},'total_cost_usd':0.01,'structured_output':report})
      """)
    let model = try makeModel()
    try model.commit { $0.settings.claudePath = claude }
    let id = try submit(model, agent: .claude)
    let project = try XCTUnwrap(model.snapshot.projects.first)
    let workspace = try await GitWorkspace.prepare(
      project: project, issueID: try XCTUnwrap(model.issue(id)?.workspaceID), root: model.store.root)
    try FileManager.default.removeItem(atPath: workspace.path)
    let session = UUID().uuidString.lowercased()
    try model.updateIssue(id) {
      $0.worktreePath = workspace.path
      $0.branch = workspace.branch
      $0.threadID = session
      $0.coveredRevision = $0.revision
      $0.deliveredContext = AgentPrompt.delivered($0, threadID: session)
      $0.record("No Claude Code process survived the restart; continuing the same session", status: .queued)
    }
    try model.commit { $0.settings.paused = false }
    model.worker.pump()
    try await wait { model.issue(id)?.status == .failed }
    let stopped = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(stopped.lastError, AgentWorker.removedWorktreeError)
    XCTAssertNil(stopped.worktreePath)
    XCTAssertEqual(runs(), 0, "Nothing runs before the tester decides; the fix may already be merged.")

    // Continue checks the branch out in a new worktree, and the session gets the full prompt.
    model.retry(id)
    try await wait { model.issue(id)?.questions.count == 1 }
    let continued = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(continued.worktreePath, workspace.path)
    XCTAssertEqual(continued.branch, workspace.branch)
    XCTAssertEqual(continued.threadID, session)
    XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8), "full\n")
  }

  func testRestartReconcilesAcknowledgedCodexWorkWithoutReplayingUncertainOrManualWork() async throws {
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let codex = try script("recover-codex", """
      #!/usr/bin/python3
      import sys,json,os
      for line in sys.stdin:
          m=json.loads(line)
          if 'id' not in m: continue
          result={}
          if m.get('method')=='thread/read': result={'thread':{'cwd':os.path.join(os.path.dirname(__file__),'repo'),'status':{'type':'idle'}}}
          if m.get('method')=='thread/turns/list': result={'data':[{'status':'interrupted'}]}
          print(json.dumps({'id':m['id'],'result':result}),flush=True)
      """)
    let automatic = Project(name: "Automatic", path: repo.path)
    var manual = Project(name: "Manual", path: repo.path)
    manual.codexApprovalMode = .ask
    func interrupted(_ projectID: UUID, thread: String) -> Issue {
      var issue = Issue(projectID: projectID, title: "Interrupted", capture: Capture(
        note: "", imagePath: "/unused", context: CaptureContext()), agent: .codex)
      issue.status = .working
      issue.threadID = thread
      issue.turnID = "turn"
      issue.worktreePath = repo.path
      return issue
    }
    let acknowledged = interrupted(automatic.id, thread: "acknowledged")
    var uncertain = interrupted(automatic.id, thread: "uncertain")
    uncertain.dispatchUncertain = true
    var question = interrupted(automatic.id, thread: "question")
    question.questions = [PendingQuestion(title: "Which layout do you want?")]
    let asks = interrupted(manual.id, thread: "manual")
    let queue = root.appendingPathComponent("codex-queue")
    do {
      let store = try IssueStore(root: queue)
      var snapshot = StoreSnapshot()
      snapshot.projects = [automatic, manual]
      snapshot.issues = [acknowledged, uncertain, question, asks]
      snapshot.settings.codexPath = codex
      snapshot.settings.paused = true
      try store.save(snapshot)
    }
    let model = try AppModel(root: queue)
    model.agents = [AgentDetection(kind: .codex, path: "/missing", version: nil, signedIn: nil, detail: "Missing")]
    await model.worker.recoverCodexAfterRestart()
    XCTAssertEqual(model.issue(acknowledged.id)?.status, .needsYou, "A paused queue stays paused")
    try model.commit { $0.settings.paused = false }
    await model.worker.recoverCodexAfterRestart()
    XCTAssertEqual(model.issue(acknowledged.id)?.status, .queued)
    for id in [uncertain.id, question.id, asks.id] {
      XCTAssertEqual(model.issue(id)?.status, .needsYou)
    }
    XCTAssertTrue(model.issue(uncertain.id)?.dispatchUncertain == true)
    XCTAssertNil(model.issue(question.id)?.questions.first?.reply)
    await model.worker.resetConnection()
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
    // Still found after the evidence worktree was removed: gh then runs in the project.
    try model.updateIssue(id) { $0.worktreePath = self.root.appendingPathComponent("removed").path }
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

  /// The runs file records each run's `--model`, so a test can check which model ran.
  private func limitedClaude(limitedModels: [String]) throws -> String {
    let limited = limitedModels.map { "'\($0)'" }.joined(separator: ",")
    return try script(
      "fake-claude",
      """
      #!/usr/bin/python3
      import sys,json,os
      here=os.path.dirname(os.path.abspath(__file__))
      if '--version' in sys.argv: print('9.9.9 (Claude Code)'); sys.exit(0)
      if '--help' in sys.argv: sys.exit(0)
      if 'auth' in sys.argv: print(json.dumps({'loggedIn':True,'authMethod':'claude.ai'})); sys.exit(0)
      sys.stdin.readline()
      model=sys.argv[sys.argv.index('--model')+1] if '--model' in sys.argv else 'default'
      with open(os.path.join(here,'runs'),'a') as log: log.write(model+'\\n')
      def send(value): print(json.dumps(value),flush=True)
      if model in [\(limited)]:
          send({'type':'result','subtype':'success','is_error':True,'result':"You've reached your "+model+" limit."})
          sys.exit(1)
      send({'type':'result','subtype':'success','is_error':False,'result':'','structured_output':{'outcome':'question','summary':'','question':'Which width?'}})
      """)
  }

  private func runModels() -> [String] {
    ((try? String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  func testUsedUpModelFallsBackToTheNextModelInsteadOfFailing() async throws {
    let claude = try limitedClaude(limitedModels: ["fable"])
    let model = try makeModel()
    try model.commit {
      $0.settings.claudePath = claude
      $0.settings.claudeModel = "fable"
      $0.settings.paused = false
    }
    let id = try submit(model, agent: .claude)
    try await wait { model.issue(id)?.status == .needsYou }
    XCTAssertEqual(runModels(), ["fable", "opus"])
    XCTAssertEqual(model.issue(id)?.questions.last?.title, "Which width?")
    XCTAssertTrue(
      model.issue(id)?.activities.contains {
        $0.text == "Fable is at its usage limit; continuing with Opus"
      } == true)
  }

  func testEveryModelUsedUpHoldsTheReportAndStartsAgainLater() async throws {
    let claude = try limitedClaude(limitedModels: ["fable", "opus", "sonnet"])
    let model = try makeModel()
    model.worker.usageLimitWait = 0.5
    try model.commit {
      $0.settings.claudePath = claude
      $0.settings.claudeModel = "fable"
      $0.settings.paused = false
    }
    let id = try submit(model, agent: .claude)
    try await wait {
      model.issue(id)?.status == .queued
        && model.issue(id)?.activities.last?.text.contains("usage limit") == true
    }
    XCTAssertEqual(runModels(), ["fable", "opus", "sonnet"])
    XCTAssertNil(model.issue(id)?.lastError)
    XCTAssertTrue(model.worker.isHeld(.claude))

    // Once the wait is over the queue picks the report up again by itself.
    try await Task.sleep(nanoseconds: 600_000_000)
    model.worker.pump()
    try await wait { self.runModels().count > 3 }
  }

  func testReportsFailedByAUsedUpModelStartAgainOnLaunch() throws {
    let model = try makeModel()
    let limited = try submit(model, agent: .claude)
    let real = try submit(model, agent: .claude)
    let ignored = try submit(model, agent: .claude)
    try model.updateIssue(limited) {
      $0.lastError = "You've reached your Fable limit. Switch to another model."
      $0.record("limit", status: .failed)
    }
    try model.updateIssue(real) {
      $0.lastError = "Validation failed after two repair attempts."
      $0.record("failed", status: .failed)
    }
    try model.updateIssue(ignored) {
      $0.lastError =
        "The following paths are ignored by one of your .gitignore files:\n.screenclip\n"
      $0.record("publish", status: .needsYou)
    }
    model.worker.recoverTransientFailures()
    XCTAssertEqual(model.issue(limited)?.status, .queued)
    XCTAssertEqual(model.issue(ignored)?.status, .queued)
    XCTAssertEqual(model.issue(real)?.status, .failed)
  }

  func testOutOfQuotaAgentHandsTheReportAndItsWorkToTheNextAgent() throws {
    let model = try makeModel()
    model.agents = [
      AgentDetection(kind: .claude, path: "/c", version: "1", signedIn: true, detail: ""),
      AgentDetection(kind: .codex, path: "/x", version: "1", signedIn: true, detail: ""),
    ]
    let id = try submit(model, agent: .claude)
    try model.updateIssue(id) {
      $0.threadID = "claude-session"
      $0.agentModel = "fable"
      $0.record("Found the clipping in PersonCard; fixing the frame", status: .working)
    }
    model.worker.holdForUsageLimit(id, agent: .claude, detail: "You've reached your Sonnet limit.")
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.status, .queued)
    XCTAssertEqual(issue.agent, .codex)
    XCTAssertNil(issue.threadID)
    XCTAssertNil(issue.agentModel)
    XCTAssertTrue(issue.handover?.contains("Found the clipping in PersonCard") == true)
    XCTAssertTrue(model.worker.isHeld(.claude))
    let project = try XCTUnwrap(model.snapshot.projects.first)
    let prompt = AgentPrompt.turn(for: issue, project: project, threadID: nil).text
    XCTAssertTrue(prompt.contains("<handover>"))
    XCTAssertTrue(prompt.contains("git diff"))
  }

  func testRotationOffKeepsTheReportWithItsAgent() throws {
    let model = try makeModel()
    try model.commit { $0.settings.rotateAgentsOnQuota = false }
    model.agents = [
      AgentDetection(kind: .codex, path: "/x", version: "1", signedIn: true, detail: "")
    ]
    let id = try submit(model, agent: .claude)
    model.worker.holdForUsageLimit(id, agent: .claude, detail: "You've reached your limit.")
    XCTAssertEqual(model.issue(id)?.agent, .claude)
    XCTAssertEqual(model.issue(id)?.status, .queued)
    XCTAssertNil(model.issue(id)?.handover)
  }

  func testAgentCloseRequestClosesTheReport() async throws {
    let model = try makeModel()
    let done = try submit(model, agent: .claude)
    let duplicate = try submit(model, agent: .claude)
    try model.updateIssue(done) { $0.record("failed", status: .failed) }
    try model.updateIssue(duplicate) { $0.record("waiting", status: .needsYou) }
    try AgentClosureInbox.write(
      AgentClosure(
        issueID: done, resolution: .done, commit: "abc1234",
        summary: "Fixed in my own commit.", closer: "claude-code"), root: model.store.root)
    try AgentClosureInbox.write(
      AgentClosure(issueID: duplicate, resolution: .canceled, summary: "Duplicate."),
      root: model.store.root)
    await model.worker.applyAgentClosures()
    XCTAssertEqual(model.issue(done)?.status, .merged)
    // A commit is recorded as given; a pull request is checked with GitHub (PRRefreshTests).
    XCTAssertEqual(model.issue(done)?.mergeCommit, "abc1234")
    XCTAssertTrue(model.issue(done)?.activities.last?.text.contains("Closed by claude-code") == true)
    XCTAssertEqual(model.issue(duplicate)?.status, .canceled)
    XCTAssertTrue(AgentClosureInbox.load(root: model.store.root).isEmpty)
  }

  func testDoneCloseRequestWithoutEvidenceIsIgnored() async throws {
    let model = try makeModel()
    let id = try submit(model, agent: .claude)
    try model.updateIssue(id) { $0.record("failed", status: .failed) }
    try AgentClosureInbox.write(
      AgentClosure(issueID: id, resolution: .done, summary: "Trust me."), root: model.store.root)
    await model.worker.applyAgentClosures()
    XCTAssertEqual(model.issue(id)?.status, .failed)
  }

  func testUsageLimitFallbackChain() {
    XCTAssertEqual(AgentModelCatalog.claudeFallbacks(after: "fable"), ["opus", "sonnet"])
    XCTAssertEqual(AgentModelCatalog.claudeFallbacks(after: "opus"), ["sonnet"])
    XCTAssertEqual(AgentModelCatalog.claudeFallbacks(after: "sonnet"), [])
    XCTAssertEqual(AgentModelCatalog.claudeFallbacks(after: nil), ["opus", "sonnet"])
    XCTAssertTrue(AgentDetector.isUsageLimitError(
      "You've reached your Fable limit. Switch to another model, or manage usage credits"))
    XCTAssertFalse(AgentDetector.isUsageLimitError("Tests failed: 3 of 120"))
    XCTAssertFalse(AgentDetector.isSignInError("You've reached your Fable limit."))
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
