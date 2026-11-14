import AppKit
import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class WorkerTests: XCTestCase {
  func testNativeWorkerGroupsEvidenceAndContinuesQuestionInSameChat() async throws {
    try await exerciseWorker(projectLookupSupported: true)
  }
  func testContextAddedDuringWorkIsIncludedInANewTurnBeforeAcceptingTheResult() async throws {
    try await exerciseWorker(projectLookupSupported: true, contextDuringTurn: true)
  }
  func testNativeWorkerIncludesRepositoryContextWhenProjectAPIIsUnavailable() async throws {
    try await exerciseWorker(projectLookupSupported: false)
  }
  func testCancelDuringProjectLookupDoesNotCreateAChat() async throws {
    try await exerciseWorker(projectLookupSupported: true, cancelDuring: "project/list")
  }
  func testCancelBeforeTurnAcknowledgementInterruptsTheAcknowledgedTurn() async throws {
    try await exerciseWorker(projectLookupSupported: true, cancelDuring: "turn/start")
  }
  func testRetryDuringCanceledProjectLookupWaitsForTheOriginalDispatch() async throws {
    try await exerciseWorker(
      projectLookupSupported: true, cancelDuring: "project/list", retryAfterCancel: true)
  }
  func testClaudeIssueIsNotSilentlyDispatchedToCodex() async throws {
    try await exerciseWorker(projectLookupSupported: true, requestedAgent: .claude)
  }
  private func exerciseWorker(
    projectLookupSupported: Bool, cancelDuring: String? = nil, retryAfterCancel: Bool = false,
    requestedAgent: AgentKind = .codex, contextDuringTurn: Bool = false
  )
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-worker-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await CommandRunner.checked("/usr/bin/git", ["init", "-b", "main"], cwd: repo.path)
    try Data("original".utf8).write(to: repo.appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "source.txt"], cwd: repo.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git",
      [
        "-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid", "commit", "-m",
        "initial",
      ], cwd: repo.path)
    let script = root.appendingPathComponent("fake-codex")
    let source = """
      #!/usr/bin/python3
      import sys,json,os,time
      def send(value): print(json.dumps(value),flush=True)
      for line in sys.stdin:
          m=json.loads(line); method=m.get('method')
          if 'id' not in m: continue
          with open(os.path.join(os.path.dirname(__file__),'requests.jsonl'),'a') as log: log.write(line)
          if method=='\(cancelDuring ?? "")': time.sleep(0.3)
          result={}
          if method=='project/list':
              if not \(projectLookupSupported ? "True" : "False"):
                  send({'id':m['id'],'error':{'code':-32601,'message':'Method not found'}})
                  continue
              result={'data':[{'id':'saved-project','name':'Different display name','roots':[{'path':os.path.join(os.path.dirname(__file__),'repo')}]}],'nextCursor':None}

          if method=='thread/resume':
              send({'id':m['id'],'error':{'code':-1,'message':'thread test-thread already has an active writer'}})
              continue
          if method in ['thread/start','thread/read']: result={'thread':{'id':'test-thread','status':{'type':'idle'}}}
          if method=='turn/start': result={'turn':{'id':'turn-1'}}
          send({'id':m['id'],'result':result})
          if method=='turn/start':
              if \(contextDuringTurn ? "True" : "False"): time.sleep(0.3)
              send({'method':'item/completed','params':{'threadId':'test-thread','item':{'type':'agentMessage','phase':'final_answer','text':json.dumps({'outcome':'question','summary':'Need context','question':'Should this label wrap?'})}}})
              send({'method':'turn/completed','params':{'threadId':'test-thread','turn':{'id':'turn-1','status':'completed'}}})
      """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path)
    try model.saveProject(project)
    var settings = model.snapshot.settings
    settings.codexPath = script.path
    settings.claudePath = root.appendingPathComponent("missing-claude").path
    settings.paused = false
    model.saveSettings(settings)
    let context = CaptureContext(appName: "Test")
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "First capture",
      context: context, projectID: project.id, existingID: nil, draft: false, agent: requestedAgent)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    func recordedRequests() throws -> [JSONValue] {
      guard let data = try? Data(contentsOf: root.appendingPathComponent("requests.jsonl")) else {
        return []
      }
      return try data.split(separator: 10).map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0))
      }
    }
    if requestedAgent == .claude {
      try await wait { model.issue(id)?.status == .failed }
      XCTAssertTrue(model.issue(id)?.lastError?.contains("working Claude Code executable") == true)
      XCTAssertFalse(try recordedRequests().contains { $0["method"].string == "thread/start" })
      await model.worker.resetConnection()
      return
    }
    if let cancelDuring {
      try await wait {
        (try? recordedRequests().contains { $0["method"].string == cancelDuring }) == true
      }
      await model.worker.cancel(id)
      if retryAfterCancel {
        model.retry(id)
        try await wait { model.issue(id)?.status == .needsYou }
        _ = try await model.worker.client.request("test/barrier")
        let requests = try recordedRequests()
        XCTAssertEqual(requests.filter { $0["method"].string == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"].string == "turn/start" }.count, 1)
        XCTAssertEqual(model.issue(id)?.questions.count, 1)
        await model.worker.resetConnection()
        return
      }
      _ = try await model.worker.client.request("test/barrier")
      if cancelDuring == "turn/start" {
        try await wait {
          (try? recordedRequests().contains { $0["method"].string == "turn/interrupt" }) == true
        }
        let interrupt = try XCTUnwrap(
          recordedRequests().first { $0["method"].string == "turn/interrupt" })
        XCTAssertEqual(interrupt["params"]["threadId"].string, "test-thread")
        XCTAssertEqual(interrupt["params"]["turnId"].string, "turn-1")
      } else {
        XCTAssertFalse(try recordedRequests().contains { $0["method"].string == "thread/start" })
        XCTAssertNil(model.issue(id)?.threadID)
      }
      XCTAssertEqual(model.issue(id)?.status, .canceled)
      await model.worker.resetConnection()
      return
    }
    if contextDuringTurn {
      try await wait { model.issue(id)?.turnID != nil }
      try model.addContext(id, text: "Context added while the agent was working")
    }
    try await wait { model.issue(id)?.status == .needsYou }
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.reportNumber, 1)
    XCTAssertEqual(issue.threadID, "test-thread")
    XCTAssertEqual(issue.questions.count, 1)
    if contextDuringTurn {
      let turns = try recordedRequests().filter { $0["method"].string == "turn/start" }
      XCTAssertEqual(turns.count, 2)
      XCTAssertFalse(
        turns[0]["params"]["input"].array[0]["text"].string?.contains(
          "Context added while the agent was working") == true)
      XCTAssertTrue(
        turns[1]["params"]["input"].array[0]["text"].string?.contains(
          "Context added while the agent was working") == true)
    }
    try model.addContext(id, text: "Extra context without a screenshot")
    try model.submit(
      imageData: Data([2]), originalData: nil, annotations: [], note: "More detail",
      context: context, projectID: project.id, existingID: id, draft: false)
    await model.worker.reply(
      issueID: id, questionID: issue.questions[0].id, answers: ["reply": "Yes, wrap it"])
    try await wait { model.issue(id)?.questions.count == 2 }
    let continued = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(model.snapshot.issues.count, 1)
    XCTAssertEqual(continued.threadID, "test-thread")
    XCTAssertEqual(continued.captures.count, 2)
    XCTAssertEqual(continued.reportNumber, issue.reportNumber)
    XCTAssertEqual(continued.questions[0].reply, "Yes, wrap it")
    XCTAssertEqual(continued.coveredRevision, contextDuringTurn ? 4 : 3)
    let requests = try String(
      contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8
    )
    .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let start = try XCTUnwrap(requests.first { $0["method"].string == "thread/start" })
    XCTAssertEqual(
      start["params"]["projectId"].string, projectLookupSupported ? "saved-project" : nil)
    XCTAssertEqual(start["params"]["cwd"].string, issue.worktreePath)
    XCTAssertNotEqual(start["params"]["cwd"].string, project.path)
    let turn = try XCTUnwrap(requests.first { $0["method"].string == "turn/start" })
    let prompt = try XCTUnwrap(turn["params"]["input"].array.first?["text"].string)
    XCTAssertTrue(prompt.contains("Report number: #1."))
    let lastTurn = try XCTUnwrap(requests.last { $0["method"].string == "turn/start" })
    let lastPrompt = try XCTUnwrap(lastTurn["params"]["input"].array.first?["text"].string)
    XCTAssertTrue(lastPrompt.contains("<additional_context>"))
    XCTAssertTrue(lastPrompt.contains("Extra context without a screenshot"))
    XCTAssertEqual(lastTurn["params"]["threadId"].string, issue.threadID)
    let name = requests.first { $0["method"].string == "thread/name/set" }
    XCTAssertEqual(name?["params"]["name"].string, "ScreenClip: #1 First capture")
    XCTAssertTrue(prompt.contains("Repository (tester's original checkout): \(project.path)"))
    XCTAssertTrue(
      prompt.contains(
        "Isolated worktree (working directory for all edits and checks): \(try XCTUnwrap(issue.worktreePath))"
      ))
    XCTAssertTrue(
      prompt.contains("Issue branch: \(try XCTUnwrap(issue.branch)); base branch: main."))
    let link = requests.first { $0["method"].string == "thread/metadata/update" }
    if projectLookupSupported {
      XCTAssertEqual(link?["params"]["threadId"].string, "test-thread")
      XCTAssertEqual(link?["params"]["projectId"].string, "saved-project")
    } else {
      XCTAssertNil(link)
      XCTAssertTrue(
        continued.activities.contains { $0.text.contains("Codex project link unavailable") })
    }
    XCTAssertEqual(
      try String(contentsOf: repo.appendingPathComponent("source.txt"), encoding: .utf8), "original"
    )
    await model.worker.resetConnection()
  }
  func testClaudeIssueAsksQuestionThenResumesTheSameSession() async throws {
    try await exerciseClaudeWorker()
  }
  func testClaudeRestartsWhenResumedSessionIsMissingOnStderr() async throws {
    try await exerciseClaudeWorker(missingSession: true)
  }
  func testCodexDisconnectDoesNotInterruptClaudeWork() async throws {
    try await exerciseClaudeWorker(disconnectCodex: true)
  }
  private func exerciseClaudeWorker(
    missingSession: Bool = false, disconnectCodex: Bool = false
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-claude-worker-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await CommandRunner.checked("/usr/bin/git", ["init", "-b", "main"], cwd: repo.path)
    try Data("original".utf8).write(to: repo.appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "source.txt"], cwd: repo.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git",
      [
        "-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid", "commit", "-m",
        "initial",
      ], cwd: repo.path)
    let script = root.appendingPathComponent("fake-claude")
    try """
      #!/usr/bin/python3
      import sys,json,os,time
      here=os.path.dirname(os.path.abspath(__file__))
      message=json.loads(sys.stdin.readline())
      with open(os.path.join(here,'runs.jsonl'),'a') as log:
          log.write(json.dumps({'args':sys.argv[1:],'cwd':os.getcwd(),'content':message['message']['content']})+'\\n')
      runs=sum(1 for _ in open(os.path.join(here,'runs.jsonl')))
      if \(missingSession ? "True" : "False") and runs==2:
          sys.stderr.write('No conversation found with session ID')
          sys.exit(1)
      if \(disconnectCodex ? "True" : "False") and runs==1:
          while not os.path.exists(os.path.join(here,'continue-claude')): time.sleep(0.02)
      def send(value): print(json.dumps(value),flush=True)
      send({'type':'system','subtype':'init','session_id':'x'})
      send({'type':'assistant','message':{'content':[{'type':'text','text':'Inspecting the screenshot'}]}})
      report={'outcome':'question','summary':'','question':'Should this label wrap?' if runs==1 else 'Which width?'}
      send({'type':'result','subtype':'success','is_error':False,'result':'','usage':{'input_tokens':1,'output_tokens':2},'total_cost_usd':0.01,'structured_output':report})
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path)
    try model.saveProject(project)
    var settings = model.snapshot.settings
    settings.claudePath = script.path
    settings.defaultAgent = .codex
    settings.paused = false
    model.saveSettings(settings)
    // The per-report choice overrides the default agent.
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Label clipped",
      context: CaptureContext(appName: "Test"), projectID: project.id, existingID: nil,
      draft: false, agent: .claude)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    XCTAssertEqual(model.issue(id)?.agent, .claude)
    if disconnectCodex {
      try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.jsonl").path) }
      let codex = root.appendingPathComponent("fake-codex")
      try """
        #!/usr/bin/python3
        import sys,json
        for line in sys.stdin:
            message=json.loads(line)
            if 'id' not in message: continue
            print(json.dumps({'id':message['id'],'result':{}}),flush=True)
            if message.get('method')=='test/disconnect': break
        """.write(to: codex, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
      try model.commit { $0.settings.codexPath = codex.path }
      await model.worker.checkConnection()
      _ = try await model.worker.client.request("test/disconnect")
      try await wait { model.connection == "Codex disconnected" }
      XCTAssertEqual(model.issue(id)?.status, .working)
      try Data().write(to: root.appendingPathComponent("continue-claude"))
    }
    try await wait { model.issue(id)?.status == .needsYou }
    let first = try XCTUnwrap(model.issue(id))
    let session = try XCTUnwrap(first.threadID)
    XCTAssertNotNil(UUID(uuidString: session))
    XCTAssertEqual(first.questions.first?.title, "Should this label wrap?")
    XCTAssertTrue(first.activities.contains { $0.text == "Inspecting the screenshot" })
    XCTAssertTrue(first.activities.contains { $0.kind == "usage" && $0.text.contains("$0.01") })
    XCTAssertNil(first.codexURL)
    XCTAssertNotNil(first.claudeResumeCommand)
    // A follow-up capture keeps the issue's agent even if another one is requested.
    try model.submit(
      imageData: Data([2]), originalData: nil, annotations: [], note: "More detail",
      context: CaptureContext(appName: "Test"), projectID: project.id, existingID: id,
      draft: false, agent: .codex)
    await model.worker.reply(
      issueID: id, questionID: first.questions[0].id, answers: ["reply": "Yes, wrap it"])
    try await wait { model.issue(id)?.questions.count == 2 }
    let continued = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(continued.agent, .claude)
    if missingSession {
      XCTAssertNotEqual(continued.threadID, session)
      XCTAssertTrue(continued.activities.contains { $0.text.contains("starting a new session") })
    } else {
      XCTAssertEqual(continued.threadID, session)
    }
    let runs = try String(contentsOf: root.appendingPathComponent("runs.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    XCTAssertEqual(runs.count, missingSession ? 3 : 2)
    let firstArgs = runs[0]["args"].array.compactMap(\.string)
    let secondArgs = runs[1]["args"].array.compactMap(\.string)
    XCTAssertEqual(firstArgs[firstArgs.firstIndex(of: "--session-id")! + 1], session)
    XCTAssertEqual(secondArgs[secondArgs.firstIndex(of: "--resume")! + 1], session)
    if missingSession {
      let freshArgs = runs[2]["args"].array.compactMap(\.string)
      XCTAssertEqual(freshArgs[freshArgs.firstIndex(of: "--session-id")! + 1], continued.threadID)
      XCTAssertFalse(freshArgs.contains("--resume"))
    }
    XCTAssertEqual(
      URL(fileURLWithPath: runs[0]["cwd"].string ?? "").resolvingSymlinksInPath().path,
      URL(fileURLWithPath: first.worktreePath ?? "").resolvingSymlinksInPath().path)
    let secondContent = runs[1]["content"].array
    XCTAssertEqual(secondContent.filter { $0["type"].string == "image" }.count, 2)
    XCTAssertTrue(secondContent.first?["text"].string?.contains("User reply: Yes, wrap it") == true)
    XCTAssertEqual(
      try String(contentsOf: repo.appendingPathComponent("source.txt"), encoding: .utf8), "original")
    await model.worker.resetConnection()
  }
  func testSignedOutAgentHoldsQueuedWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-held-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.settings.paused = false }
    model.agents = [
      AgentDetection(kind: .claude, path: "/x", version: "1", signedIn: false, detail: "signed out")
    ]
    try model.saveProject(Project(name: "P", path: try makeRepo(root)))
    let project = try XCTUnwrap(model.snapshot.projects.first)
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Held",
      context: CaptureContext(), projectID: project.id, existingID: nil, draft: false,
      agent: .claude)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(model.snapshot.issues.first?.status, .queued)
    XCTAssertNil(model.snapshot.issues.first?.worktreePath)
    // Detection lists installed agents plus the default, which stays selectable.
    XCTAssertEqual(model.availableAgents, [.codex, .claude, .external])
    model.agents[0].version = nil
    XCTAssertEqual(model.availableAgents, [.codex, .external])
  }
  func testReconcileRefusesClaudeSessionRunningOutsideTheWorker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-external-claude-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    let session = UUID().uuidString.lowercased()
    let script = root.appendingPathComponent("external-claude.py")
    try "import time; time.sleep(30)".write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path, "--session-id", session]
    try process.run()
    defer { process.terminate(); process.waitUntilExit() }
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Recovered",
      context: CaptureContext(), projectID: nil, existingID: nil, draft: true, agent: .claude)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) {
      $0.threadID = session
      $0.status = .needsYou
      $0.lastError = "Interrupted run"
    }
    await model.worker.reconcile(id)
    XCTAssertTrue(model.banner?.contains("still running") == true)
    XCTAssertEqual(model.issue(id)?.lastError, "Interrupted run")
  }
  private func makeRepo(_ root: URL) throws -> String {
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    return repo.path
  }
  func testDraftCanBeAssignedAProjectBeforeSubmission() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-draft-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.settings.paused = true }
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Draft",
      context: CaptureContext(), projectID: nil, existingID: nil, draft: true)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    XCTAssertEqual(model.issue(id)?.reportNumber, 1)
    let project = UUID()
    try model.submit(
      imageData: Data([2]), originalData: nil, annotations: [], note: "Ready",
      context: CaptureContext(), projectID: project, existingID: id, draft: false)
    XCTAssertEqual(model.issue(id)?.projectID, project)
    XCTAssertEqual(model.issue(id)?.captures.count, 1)
    XCTAssertEqual(model.issue(id)?.status, .queued)
    XCTAssertEqual(model.issue(id)?.reportNumber, 1)
  }
  func testReconcileRecoversCompletedFixWithoutAnotherModelTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-recover-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await CommandRunner.checked("/usr/bin/git", ["init", "-b", "main"], cwd: repo.path)
    try Data("source".utf8).write(to: repo.appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "source.txt"], cwd: repo.path)
    _ = try await CommandRunner.checked("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"], cwd: repo.path)
    let script = root.appendingPathComponent("fake-codex")
    try """
      #!/usr/bin/python3
      import json,sys,os
      for line in sys.stdin:
          m=json.loads(line)
          if 'id' not in m: continue
          method=m.get('method'); result={}
          with open(os.path.join(os.path.dirname(__file__),'requests'),'a') as f: f.write(method+'\\n')
          if method=='thread/read': result={'thread':{'cwd':os.path.join(os.path.dirname(__file__),'repo'),'status':{'type':'idle'}}}
          if method=='thread/turns/list': result={'data':[{'status':'completed','items':[{'type':'agentMessage','phase':'final_answer','text':json.dumps({'outcome':'implemented','summary':'Recovered fix','question':''})}]}]}
          print(json.dumps({'id':m['id'],'result':result}),flush=True)
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path, validationCommand: "true")
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true; $0.settings.codexPath = script.path; $0.settings.ghPath = "/usr/bin/true" }
    try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(), projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) { $0.threadID = "saved"; $0.worktreePath = repo.path; $0.branch = "main"; $0.coveredRevision = $0.revision; $0.status = .needsYou }
    await model.worker.reconcile(id)
    XCTAssertEqual(model.issue(id)?.resultSummary, "Recovered fix")
    XCTAssertEqual(model.issue(id)?.status, .needsYou)
    XCTAssertNotNil(model.issue(id)?.lastError) // No origin: validation cannot silently claim publication.
    let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
    XCTAssertFalse(requests.contains("turn/start"))
    await model.worker.resetConnection()
  }
  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else {
      throw ScreenClipError.message("Worker did not reach the expected state")
    }
  }
}
