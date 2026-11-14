import AppKit
import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class WorkerTests: XCTestCase {
  func testNativeWorkerGroupsEvidenceAndContinuesQuestionInSameChat() async throws {
    try await exerciseWorker(projectLookupSupported: true)
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
    requestedAgent: AgentKind = .codex
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
    settings.paused = false
    model.saveSettings(settings)
    let context = CaptureContext(appName: "Test")
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "First capture",
      context: context, projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) { $0.agent = requestedAgent }
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
      XCTAssertTrue(model.issue(id)?.lastError?.contains("Claude Code dispatch is not available") == true)
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
    try await wait { model.issue(id)?.status == .needsYou }
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.reportNumber, 1)
    XCTAssertEqual(issue.threadID, "test-thread")
    XCTAssertEqual(issue.questions.count, 1)
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
    XCTAssertEqual(continued.coveredRevision, 2)
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
