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
  func testProjectCanSwitchFromFullAccessToManualApprovalInTheSameChat() async throws {
    try await exerciseWorker(projectLookupSupported: true, initialMode: .fullAccess, continuedMode: .ask)
  }
  func testAutomaticReviewIsAppliedWhenContinuingAnOwnedChat() async throws {
    try await exerciseWorker(projectLookupSupported: true, initialMode: .ask, continuedMode: .automaticReview)
  }
  func testAllowAndAutomateUpdatesTheLiveTurnAndApprovesOnlyThePendingRequest() async throws {
    try await exerciseApprovalAutomation()
  }
  func testUnsupportedAutomaticReviewKeepsTheApprovalPending() async throws {
    try await exerciseApprovalAutomation(unsupported: true)
  }
  func testTypedCodexUserInputRetainsItsAnswerResponseFormat() async throws {
    try await exerciseApprovalAutomation(userInput: true)
  }
  func testUnansweredQuestionIsAnsweredForAnAbsentTesterAndFreesItsSlot() async throws {
    try await exerciseApprovalAutomation(userInput: true, unattended: true)
  }
  func testUnansweredApprovalIsDeclinedForAnAbsentTester() async throws {
    try await exerciseApprovalAutomation(unattended: true)
  }
  func testApprovalThatCanOnlyBeCanceledKeepsWaitingWithoutASlot() async throws {
    try await exerciseApprovalAutomation(unattended: true, declineOffered: false)
  }
  func testOlderRuntimeCannotSilentlyFallBackToManualReviewOnRetry() async throws {
    try await exerciseWorker(projectLookupSupported: true, reviewerSupported: false)
  }
  func testRelaunchResumesAReportStrandedOnPermissionApproval() async throws {
    try await exerciseApprovalAutomation(recovery: .automaticReview)
  }
  func testRelaunchPreservesManualApprovalAndGenuineQuestions() async throws {
    try await exerciseApprovalAutomation(recovery: .ask)
    try await exerciseApprovalAutomation(recovery: .automaticReview, genuineQuestion: true)
  }
  func testRelaunchDoesNotCompeteWithAnActiveCodexChat() async throws {
    try await exerciseApprovalAutomation(recovery: .automaticReview, activeChat: true)
  }
  func testCancelDuringApprovalRecoveryIsNotOverwrittenByReconciliation() async throws {
    try await exerciseApprovalAutomation(recovery: .automaticReview, cancelDuringRecovery: true)
  }
  private func exerciseApprovalAutomation(
    unsupported: Bool = false, recovery: CodexApprovalMode? = nil,
    genuineQuestion: Bool = false, activeChat: Bool = false, cancelDuringRecovery: Bool = false,
    userInput: Bool = false, unattended: Bool = false, declineOffered: Bool = true
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-approvals-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fake-codex")
    try """
      #!/usr/bin/python3
      import sys,json,os,time
      for line in sys.stdin:
          m=json.loads(line)
          with open(os.path.join(os.path.dirname(__file__),'requests.jsonl'),'a') as log: log.write(line)
          if 'method' not in m or 'id' not in m: continue
          if m['method']=='thread/turns/list' and \(cancelDuringRecovery ? "True" : "False"): time.sleep(0.3)
          if m['method']=='turn/settings/update' and \(unsupported ? "True" : "False"):
              print(json.dumps({'id':m['id'],'error':{'code':-32601,'message':'Method not found'}}),flush=True)
          else:
              result={'status':'applied'}
              if m['method']=='thread/read': result={'thread':{'cwd':os.path.join(os.path.dirname(__file__),'repo'),'status':{'type':'\(activeChat ? "active" : "idle")'}}}
              if m['method']=='thread/turns/list': result={'data':[{'status':'interrupted'}]}
              print(json.dumps({'id':m['id'],'result':result}),flush=True)
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    var project = Project(name: "Test", path: root.appendingPathComponent("repo").path)
    project.codexApprovalMode = .ask
    var issue = Issue(projectID: project.id, title: "Test", capture: Capture(note: "", imagePath: "/unused", context: CaptureContext()))
    issue.threadID = "approval-thread"
    issue.turnID = "approval-turn"
    issue.worktreePath = project.path
    issue.status = .working
    try model.commit {
      $0.projects = [project]
      $0.issues = [issue]
      $0.settings.codexPath = script.path
      $0.settings.paused = true
    }
    try await model.worker.connect()
    model.worker.jobs.insert(issue.id)
    let request: JSONValue = .object([
      "id": .string("pending-build"),
      "method": .string(userInput ? "item/tool/requestUserInput" : "item/commandExecution/requestApproval"),
      "params": .object([
        "threadId": .string("approval-thread"), "turnId": .string("approval-turn"),
        "reason": .string("Run local tests"), "command": .string("xcodebuild test"),
        "availableDecisions": .array([.string("accept"), .string(declineOffered ? "decline" : "cancel")]),
        "questions": .array([.object([
          "id": .string("layout"), "question": .string("Which layout?"),
        ])]),
      ]),
    ])
    await model.worker.handle(request)
    let question = try XCTUnwrap(model.issue(issue.id)?.questions.first)
    // Merely receiving an approval never grants permission, even in automatic mode.
    XCTAssertEqual(model.issue(issue.id)?.status, .needsYou)
    func requests() throws -> [JSONValue] {
      try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
    if unattended {
      // Waiting for the tester does not hold the project's run slot.
      XCTAssertNil(model.worker.occupiedSlots()[project.id])
      let asked = try XCTUnwrap(question.askedAt)
      await model.worker.answerUnattendedQuestions(now: asked.addingTimeInterval(599))
      XCTAssertNil(model.issue(issue.id)?.questions.first?.reply)
      // A card whose request id now belongs to another report, as after a Codex restart,
      // answers nothing.
      let key = try XCTUnwrap(question.requestID).data.base64EncodedString()
      XCTAssertEqual(model.worker.requestOwners[key], issue.id)
      model.worker.requestOwners[key] = UUID()
      await model.worker.reply(issueID: issue.id, questionID: question.id, answers: [:], allow: true)
      XCTAssertNil(model.issue(issue.id)?.questions.first?.reply)
      XCTAssertFalse((try? requests().contains { $0["id"].string == "pending-build" }) ?? false)
      model.worker.requestOwners[key] = issue.id
      model.banner = nil
      // The wait is a setting; Never leaves the request for the tester.
      try model.commit { $0.settings.unattendedAnswerMinutes = 0 }
      await model.worker.answerUnattendedQuestions(now: asked.addingTimeInterval(7200))
      XCTAssertNil(model.issue(issue.id)?.questions.first?.reply)
      try model.commit { $0.settings.unattendedAnswerMinutes = 30 }
      await model.worker.answerUnattendedQuestions(now: asked.addingTimeInterval(1799))
      XCTAssertNil(model.issue(issue.id)?.questions.first?.reply)
      try model.commit { $0.settings.unattendedAnswerMinutes = nil }
      await model.worker.answerUnattendedQuestions(now: asked.addingTimeInterval(601))
      if declineOffered {
        try await wait { (try? requests().contains { $0["id"].string == "pending-build" }) == true }
        let response = try XCTUnwrap(requests().first { $0["id"].string == "pending-build" })
        if userInput {
          XCTAssertEqual(
            response["result"]["answers"]["layout"]["answers"],
            .array([.string(AgentWorker.unattendedAnswer)]))
        } else {
          XCTAssertEqual(response["result"]["decision"], .string("decline"))
        }
        XCTAssertEqual(model.issue(issue.id)?.status, .working)
        XCTAssertEqual(model.worker.occupiedSlots()[project.id], 1)
        XCTAssertNotNil(model.issue(issue.id)?.questions.first?.reply)
        // The consumed request is never answered twice.
        await model.worker.answerUnattendedQuestions(now: asked.addingTimeInterval(1200))
        XCTAssertEqual(try requests().filter { $0["id"].string == "pending-build" }.count, 1)
      } else {
        XCTAssertEqual(model.issue(issue.id)?.status, .needsYou)
        XCTAssertNil(model.issue(issue.id)?.questions.first?.reply)
        XCTAssertFalse(try requests().contains { $0["id"].string == "pending-build" })
      }
      model.worker.jobs.remove(issue.id)
      await model.worker.resetConnection()
      return
    }
    if userInput {
      await model.worker.reply(issueID: issue.id, questionID: question.id, answers: ["layout": "Compact"])
      try await wait { (try? requests().contains { $0["id"].string == "pending-build" }) == true }
      let response = try XCTUnwrap(requests().first { $0["id"].string == "pending-build" })
      XCTAssertEqual(response["result"]["answers"]["layout"]["answers"], .array([.string("Compact")]))
      XCTAssertEqual(model.issue(issue.id)?.status, .working)
      XCTAssertEqual(model.issue(issue.id)?.questions.first?.reply, "Compact")
      XCTAssertEqual(model.project(project.id)?.codexApprovalMode, .ask)
      model.worker.jobs.remove(issue.id)
      await model.worker.resetConnection()
      return
    }
    if let recovery {
      project.codexApprovalMode = recovery
      try model.saveProject(project)
      try model.commit { $0.settings.paused = false }
      // Hold dispatch, so the assertion observes the durable queued state after recovery.
      model.agents = [AgentDetection(kind: .codex, path: "/missing", version: nil, signedIn: nil, detail: "Missing")]
      if genuineQuestion {
        try model.updateIssue(issue.id) { $0.questions.append(PendingQuestion(title: "Which layout do you want?")) }
      }
      model.worker.requestOwners.removeAll()
      model.worker.jobs.remove(issue.id)
      let recovering = Task { await model.worker.recoverCodexAfterRestart() }
      if cancelDuringRecovery {
        try await wait { (try? requests().contains { $0["method"].string == "thread/turns/list" }) == true }
        await model.worker.cancel(issue.id)
      }
      await recovering.value
      if cancelDuringRecovery {
        XCTAssertEqual(model.issue(issue.id)?.status, .canceled)
        // Cancel expires the request card itself; reconciliation must add nothing after it.
        XCTAssertEqual(
          model.issue(issue.id)?.questions.first?.reply,
          "Expired request; continue the issue to ask again")
        XCTAssertEqual(
          model.issue(issue.id)?.activities.last?.text, "Canceled; existing workspace and PR retained")
        await model.worker.resetConnection()
        return
      }
      let resumes = recovery != .ask && !genuineQuestion && !activeChat
      XCTAssertEqual(model.issue(issue.id)?.status, resumes ? .queued : .needsYou)
      XCTAssertEqual(model.issue(issue.id)?.questions.first?.reply != nil, resumes)
      XCTAssertFalse(try requests().contains { $0["id"].string == "pending-build" })
      await model.worker.resetConnection()
      return
    }
    await model.worker.allowAndAutomate(issueID: issue.id, questionID: question.id)
    if unsupported {
      XCTAssertEqual(model.issue(issue.id)?.status, .needsYou)
      XCTAssertNil(model.issue(issue.id)?.questions.first?.reply)
      XCTAssertEqual(model.project(project.id)?.codexApprovalMode, .ask)
      XCTAssertFalse(try requests().contains { $0["id"].string == "pending-build" })
      XCTAssertNotNil(model.banner)
    } else {
      try await wait { (try? requests().contains { $0["id"].string == "pending-build" }) == true }
      XCTAssertEqual(model.issue(issue.id)?.status, .working)
      XCTAssertEqual(model.project(project.id)?.codexApprovalMode, .automaticReview)
      let recorded = try requests()
      XCTAssertEqual(recorded.first { $0["method"].string == "turn/settings/update" }?["params"]["approvalsReviewer"].string, "auto_review")
      XCTAssertEqual(recorded.first { $0["method"].string == "thread/settings/update" }?["params"]["approvalsReviewer"].string, "auto_review")
      let response = try XCTUnwrap(recorded.first { $0["id"].string == "pending-build" })
      XCTAssertEqual(response["result"]["decision"], .string("accept"))
      XCTAssertFalse(recorded.contains { $0["params"]["sandboxPolicy"] != .null })
      // A second click cannot approve again after the pending request has been consumed.
      await model.worker.allowAndAutomate(issueID: issue.id, questionID: question.id)
      XCTAssertEqual(try requests().filter { $0["id"].string == "pending-build" }.count, 1)
    }
    model.worker.jobs.remove(issue.id)
    await model.worker.resetConnection()
  }
  private func exerciseWorker(
    projectLookupSupported: Bool, cancelDuring: String? = nil, retryAfterCancel: Bool = false,
    requestedAgent: AgentKind = .codex, contextDuringTurn: Bool = false,
    initialMode: CodexApprovalMode = .automaticReview, continuedMode: CodexApprovalMode? = nil,
    reviewerSupported: Bool = true
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
          if method=='thread/start' and \(reviewerSupported ? "True" : "False"): result['approvalsReviewer']=m['params'].get('approvalsReviewer','user')
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
    var project = Project(name: "Test", path: repo.path)
    project.codexApprovalMode = initialMode
    try model.saveProject(project)
    var settings = model.snapshot.settings
    settings.codexPath = script.path
    settings.defaultPromptAddOn = "Include accessibility checks."
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
    if !reviewerSupported {
      try await wait { model.issue(id)?.status == .failed }
      XCTAssertTrue(model.issue(id)?.lastError?.contains("automatic approval review") == true)
      model.retry(id)
      try await wait { model.issue(id)?.status == .failed && !model.worker.isActive(id) }
      XCTAssertFalse(try recordedRequests().contains { $0["method"].string == "turn/start" })
      XCTAssertEqual(try recordedRequests().filter { $0["method"].string == "thread/start" }.count, 1)
      await model.worker.resetConnection()
      return
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
    settings.defaultPromptAddOn = "Explain the validation result."
    model.saveSettings(settings)
    try model.addContext(id, text: "Extra context without a screenshot")
    try model.submit(
      imageData: Data([2]), originalData: nil, annotations: [], note: "More detail",
      context: context, projectID: project.id, existingID: id, draft: false)
    if let continuedMode {
      project.codexApprovalMode = continuedMode
      try model.saveProject(project)
    }
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
    XCTAssertEqual(start["params"]["approvalPolicy"].string, initialMode.approvalPolicy)
    XCTAssertEqual(start["params"]["approvalsReviewer"].string, initialMode.reviewer)
    XCTAssertEqual(start["params"]["sandbox"].string, initialMode.sandbox)
    let turn = try XCTUnwrap(requests.first { $0["method"].string == "turn/start" })
    XCTAssertEqual(turn["params"]["sandboxPolicy"], initialMode.sandboxPolicy)
    let prompt = try XCTUnwrap(turn["params"]["input"].array.first?["text"].string)
    XCTAssertTrue(prompt.contains("Report number: #1."))
    XCTAssertTrue(prompt.contains("Include accessibility checks."))
    let lastTurn = try XCTUnwrap(requests.last { $0["method"].string == "turn/start" })
    let finalMode = continuedMode ?? initialMode
    XCTAssertEqual(lastTurn["params"]["approvalPolicy"].string, finalMode.approvalPolicy)
    XCTAssertEqual(lastTurn["params"]["approvalsReviewer"].string, finalMode.reviewer)
    XCTAssertEqual(lastTurn["params"]["sandboxPolicy"], finalMode.sandboxPolicy)
    let lastPrompt = try XCTUnwrap(lastTurn["params"]["input"].array.first?["text"].string)
    XCTAssertTrue(lastPrompt.contains("<additional_context>"))
    XCTAssertTrue(lastPrompt.contains("Extra context without a screenshot"))
    XCTAssertTrue(lastPrompt.contains("Explain the validation result."))
    XCTAssertFalse(lastPrompt.contains("Include accessibility checks."))
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
  func testClaudePermissionFailureDoesNotAskForATextReply() async throws {
    try await exerciseClaudeWorker(permissionFailure: true)
  }
  func testClaudeEmptyQuestionWithPermissionDenialsDoesNotAskForATextReply() async throws {
    try await exerciseClaudeWorker(permissionFailure: true, emptyQuestion: true)
  }
  func testLegacyClaudePermissionQuestionBecomesRetryableWithoutChangingRealQuestions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.settings.paused = true }
    for title in ["Blocked tools: Bash: xcodebuild", "Which width?"] {
      try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: title,
        context: CaptureContext(), projectID: nil, existingID: nil, draft: true, agent: .claude)
      let id = try XCTUnwrap(model.snapshot.issues.first { $0.title == title }?.id)
      try model.updateIssue(id) {
        $0.status = .needsYou
        $0.questions = [PendingQuestion(title: title)]
      }
    }
    model.worker.recoverClaudePermissionQuestions()
    let repaired = try XCTUnwrap(model.snapshot.issues.first { $0.title.hasPrefix("Blocked tools:") })
    XCTAssertEqual(repaired.status, .failed)
    XCTAssertTrue(repaired.questions.isEmpty)
    XCTAssertEqual(repaired.lastError, AgentWorker.claudePermissionFailure)
    XCTAssertTrue(repaired.activities.contains { $0.kind == "permission-denial" })
    let genuine = try XCTUnwrap(model.snapshot.issues.first { $0.title == "Which width?" })
    XCTAssertEqual(genuine.status, .needsYou)
    XCTAssertEqual(genuine.questions.first?.title, "Which width?")
  }
  private func exerciseClaudeWorker(
    missingSession: Bool = false, disconnectCodex: Bool = false,
    permissionFailure: Bool = false, emptyQuestion: Bool = false
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
      denials=[]
      if \(permissionFailure ? "True" : "False"):
          report={'outcome':'question' if \(emptyQuestion ? "True" : "False") else 'blocked','summary':'Build blocked','question':''}
          denials=[{'tool_name':'Bash','tool_input':{'command':'xcodebuild build-for-testing'}}]
      send({'type':'result','subtype':'success','is_error':False,'result':'','usage':{'input_tokens':1,'output_tokens':2},'total_cost_usd':0.01,'structured_output':report,'permission_denials':denials})
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path)
    try model.saveProject(project)
    var settings = model.snapshot.settings
    settings.claudePath = script.path
    settings.defaultPromptAddOn = "Include accessibility checks."
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
    if permissionFailure {
      try await wait { model.issue(id)?.status == .failed }
      let failed = try XCTUnwrap(model.issue(id))
      XCTAssertTrue(failed.questions.isEmpty)
      XCTAssertEqual(failed.lastError, AgentWorker.claudePermissionFailure)
      XCTAssertTrue(failed.activities.contains {
        $0.kind == "permission-denial" && $0.text.contains("xcodebuild build-for-testing")
      })
      XCTAssertNil(failed.turnID)
      XCTAssertFalse(failed.dispatchUncertain)
      return
    }
    if disconnectCodex {
      try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.jsonl").path) }
      let codex = root.appendingPathComponent("fake-codex")
      try """
        #!/usr/bin/python3
        import sys,json
        for line in sys.stdin:
            message=json.loads(line)
            if message.get('method')=='initialize':
                print(json.dumps({'id':message['id'],'result':{}}),flush=True)
            # The client has received our reply when it sends this notification.
            elif message.get('method')=='initialized': break
        """.write(to: codex, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
      try model.commit { $0.settings.codexPath = codex.path }
      try await model.worker.connect()
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
    settings.defaultPromptAddOn = "Explain the validation result."
    model.saveSettings(settings)
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
    // The resumed session already has the first screenshot: only the new one is attached.
    let secondContent = runs[1]["content"].array
    XCTAssertTrue(runs[0]["content"].array.first?["text"].string?.contains("Include accessibility checks.") == true)
    XCTAssertTrue(secondContent.first?["text"].string?.contains("Explain the validation result.") == true)
    XCTAssertFalse(secondContent.first?["text"].string?.contains("Include accessibility checks.") == true)
    XCTAssertEqual(secondContent.filter { $0["type"].string == "image" }.count, 1)
    XCTAssertTrue(secondContent.first?["text"].string?.contains("User reply: Yes, wrap it") == true)
    XCTAssertTrue(secondContent.first?["text"].string?.contains("Only what is new") == true)
    if missingSession {
      // A replacement session has seen nothing, so it gets every screenshot and the full prompt.
      let freshContent = runs[2]["content"].array
      XCTAssertEqual(freshContent.filter { $0["type"].string == "image" }.count, 2)
      XCTAssertTrue(freshContent.first?["text"].string?.contains("Resolve this ScreenClip issue") == true)
      XCTAssertTrue(freshContent.first?["text"].string?.contains("Explain the validation result.") == true)
    }
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
  func testProjectRunsQueuedReportsInParallelUpToTheLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-parallel-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fake-claude")
    try """
      #!/usr/bin/python3
      import sys,json,os,time
      here=os.path.dirname(os.path.abspath(__file__))
      sys.stdin.readline()
      open(os.path.join(here,'started-'+os.path.basename(os.getcwd())),'w').close()
      while not os.path.exists(os.path.join(here,'release')): time.sleep(0.02)
      def send(value): print(json.dumps(value),flush=True)
      send({'type':'system','subtype':'init','session_id':os.path.basename(os.getcwd())})
      report={'outcome':'question','summary':'','question':'Which width?'}
      send({'type':'result','subtype':'success','is_error':False,'result':'','usage':{'input_tokens':1,'output_tokens':2},'total_cost_usd':0.01,'structured_output':report})
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: repo.appendingPathComponent("source.txt"))
    for arguments in [
      ["init", "-b", "main"], ["add", "source.txt"],
      ["-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"],
    ] {
      _ = try await CommandRunner.checked("/usr/bin/git", arguments, cwd: repo.path)
    }
    try model.saveProject(Project(name: "P", path: repo.path))
    let project = try XCTUnwrap(model.snapshot.projects.first)
    var settings = model.snapshot.settings
    settings.claudePath = script.path
    settings.paused = true
    settings.maxParallelReports = 2
    model.saveSettings(settings)
    for note in ["One", "Two", "Three"] {
      try model.submit(
        imageData: Data([1]), originalData: nil, annotations: [], note: note,
        context: CaptureContext(), projectID: project.id, existingID: nil, draft: false,
        agent: .claude)
    }
    settings.paused = false
    model.saveSettings(settings)
    model.worker.pump()
    func started() -> Int {
      ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        .filter { $0.hasPrefix("started-") }.count
    }
    try await wait { started() == 2 }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(started(), 2)
    let working = model.snapshot.issues.filter { $0.status == .working }
    XCTAssertEqual(working.count, 2)
    XCTAssertEqual(Set(working.compactMap(\.worktreePath)).count, 2)
    XCTAssertEqual(model.snapshot.issues.filter { $0.status == .queued }.count, 1)
    try Data().write(to: root.appendingPathComponent("release"))
    try await wait { model.snapshot.issues.allSatisfy { $0.status == .needsYou } }
    XCTAssertEqual(started(), 3)
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
    try await exerciseRecovery(consumed: nil, superseded: nil, recovers: true)
  }
  /// The usual restart: the result was taken, then validation or publication was interrupted.
  func testReconcileRecoversAResultWhosePublicationWasInterrupted() async throws {
    try await exerciseRecovery(consumed: "T1", superseded: nil, recovers: true)
  }
  /// A newer turn was requested for new evidence but never reached Codex: the older result
  /// must not be published as if it covered that evidence.
  func testReconcileDoesNotRecoverATurnSupersededByALaterDispatch() async throws {
    try await exerciseRecovery(consumed: "T1", superseded: "T1", recovers: false)
  }
  private func exerciseRecovery(consumed: String?, superseded: String?, recovers: Bool) async throws {
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
          if method=='thread/turns/list': result={'data':[{'id':'T1','status':'completed','items':[{'type':'agentMessage','phase':'final_answer','text':json.dumps({'outcome':'implemented','summary':'Recovered fix','question':''})}]}]}
          print(json.dumps({'id':m['id'],'result':result}),flush=True)
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path, validationCommand: "true")
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true; $0.settings.codexPath = script.path; $0.settings.ghPath = "/usr/bin/true" }
    try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(), projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) {
      $0.threadID = "saved"; $0.worktreePath = repo.path; $0.branch = "main"
      $0.coveredRevision = $0.revision; $0.status = .needsYou
      $0.consumedTurnID = consumed; $0.supersededTurnID = superseded
    }
    await model.worker.reconcile(id)
    guard recovers else {
      XCTAssertNil(model.issue(id)?.resultSummary)
      XCTAssertEqual(model.issue(id)?.status, .needsYou)
      XCTAssertEqual(model.issue(id)?.activities.last?.text, "Chat reconciled. Continue when ready.")
      await model.worker.resetConnection()
      return
    }
    XCTAssertEqual(model.issue(id)?.resultSummary, "Recovered fix")
    XCTAssertEqual(model.issue(id)?.consumedTurnID, "T1")
    // Recovery hands the result to publication. The capture is no PNG, which is a warning, not a
    // repair: publication carries on without screenshots (and stops later, at this fake remote).
    XCTAssertTrue(model.issue(id)?.activities.contains {
      $0.kind == PRScreenshotEvidence.warningKind && $0.text.contains("Invalid PNG screenshot")
    } == true)
    XCTAssertEqual(model.issue(id)?.repairAttempts ?? 0, 0)
    XCTAssertNil(model.issue(id)?.validationFeedback)
    let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
    XCTAssertFalse(requests.contains("turn/start"))
    await model.worker.resetConnection()
  }
  /// A report queued again while its previous run is still validating must wait for that run:
  /// both would work in the same worktree.
  func testQueuedReportWaitsWhileItsPreviousRunIsStillFinishing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-gate-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: try makeRepo(root), validationCommand: "true")
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true; $0.settings.codexPath = "/usr/bin/true" }
    try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(), projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.commit { $0.settings.paused = false }
    for keyPath in [\AgentWorker.finishing, \AgentWorker.publishing] {
      model.worker[keyPath: keyPath].insert(id)
      model.worker.pump()
      XCTAssertFalse(model.worker.jobs.contains(id))
      XCTAssertEqual(model.issue(id)?.status, .queued)
      model.worker[keyPath: keyPath].remove(id)
    }
    // Control: with nothing in the way the same report is dispatched.
    model.worker.pump()
    XCTAssertTrue(model.worker.jobs.contains(id))
    try model.commit { $0.settings.paused = true }
    await model.worker.cancel(id)
    try await wait { !model.worker.isActive(id) }
    await model.worker.resetConnection()
  }
  /// Cancel then Continue: the canceled turn's late completion must not fail the queued run.
  /// A request card cannot be answered after its turn is canceled. Left unanswered it hid
  /// Continue and blocked Archive, leaving the canceled report with no way forward.
  func testCancelExpiresUnansweredRequestCards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-cancel-card-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: try makeRepo(root), validationCommand: "true")
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true }
    try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(), projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) {
      $0.agent = .codex
      $0.status = .needsYou
      $0.questions = [
        PendingQuestion(title: "Allow?", requestID: .number(12)),
        PendingQuestion(title: "Should the toolbar wrap?"),
      ]
    }
    let key = JSONValue.number(12).data.base64EncodedString()
    model.worker.requestOwners[key] = id
    XCTAssertEqual(model.issue(id)?.canArchive, false)
    await model.worker.cancel(id)
    let canceled = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(canceled.status, .canceled)
    XCTAssertNotNil(canceled.questions[0].reply)
    // A question the agent asked in its result is still the tester's to answer.
    XCTAssertNil(canceled.questions[1].reply)
    XCTAssertTrue(canceled.canArchive)
    XCTAssertTrue(model.worker.requestOwners.isEmpty)
  }
  func testLateCompletionOfACanceledTurnDoesNotFailTheNextRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-late-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: try makeRepo(root), validationCommand: "true")
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true }
    try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(), projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) { $0.agent = .codex; $0.threadID = "thread"; $0.status = .queued }
    func completed(_ turn: String) -> JSONValue {
      .object([
        "method": .string("turn/completed"),
        "params": .object([
          "threadId": .string("thread"),
          "turn": .object(["id": .string(turn), "status": .string("interrupted")]),
        ]),
      ])
    }
    model.worker.jobs.insert(id)
    model.worker.canceledTurns.insert("canceled-turn")
    await model.worker.handle(completed("canceled-turn"))
    XCTAssertEqual(model.issue(id)?.status, .queued)
    XCTAssertTrue(model.worker.jobs.contains(id))
    XCTAssertTrue(model.worker.canceledTurns.isEmpty)
    // Control: an interruption of the running turn still fails the report.
    await model.worker.handle(completed("running-turn"))
    XCTAssertEqual(model.issue(id)?.status, .failed)
    XCTAssertFalse(model.worker.jobs.contains(id))
  }
  /// The validation command runs the pull request's code on this Mac. For a Grok Bot pull
  /// request that happens only when the project merges automatically; otherwise the report
  /// still follows the pull request so its GitHub status is shown.
  func testGrokBotPullRequestIsValidatedLocallyOnlyWithAutomaticMerge() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-grok-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = "/usr/bin/git"
    let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
    let origin = root.appendingPathComponent("origin.git")
    _ = try await CommandRunner.checked(git, ["init", "--bare", "-b", "main", origin.path], cwd: root.path)
    let repo = root.appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    _ = try await CommandRunner.checked(git, ["init", "-b", "main"], cwd: repo)
    try Data("source".utf8).write(to: URL(fileURLWithPath: repo).appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked(git, ["add", "source.txt"], cwd: repo)
    _ = try await CommandRunner.checked(git, identity + ["commit", "-m", "initial"], cwd: repo)
    let branch = "screenclip/1-report"
    _ = try await CommandRunner.checked(git, ["remote", "add", "origin", origin.path], cwd: repo)
    _ = try await CommandRunner.checked(git, ["checkout", "-b", branch], cwd: repo)
    try Data("fix".utf8).write(to: URL(fileURLWithPath: repo).appendingPathComponent("fixed.txt"))
    _ = try await CommandRunner.checked(git, ["add", "fixed.txt"], cwd: repo)
    _ = try await CommandRunner.checked(git, identity + ["commit", "-m", "fix"], cwd: repo)
    _ = try await CommandRunner.checked(git, ["push", "origin", branch], cwd: repo)
    let head = try await CommandRunner.checked(git, ["rev-parse", "HEAD"], cwd: repo)
    let marker = root.appendingPathComponent("validation-ran")
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    var project = Project(name: "Test", path: repo, validationCommand: "touch '\(marker.path)'", autoMerge: false)
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true }
    try model.submit(imageData: Data([1]), originalData: nil, annotations: [], note: "Fix", context: CaptureContext(), projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try model.updateIssue(id) {
      $0.agent = .external; $0.branch = branch; $0.worktreePath = repo; $0.status = .prOpen
    }
    let issue = try XCTUnwrap(model.issue(id))
    let unattended = try await model.worker.inspectExternal(
      id, issue: issue, project: project, path: repo, pullHead: head)
    guard case .unvalidated = unattended else { return XCTFail("expected unvalidated, got \(unattended)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(model.issue(id)?.prHead, head)
    project.autoMerge = true
    try model.saveProject(project)
    let validated = try await model.worker.inspectExternal(
      id, issue: issue, project: project, path: repo, pullHead: head)
    guard case .ready = validated else { return XCTFail("expected ready, got \(validated)") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }
  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else {
      throw ScreenClipError.message("Worker did not reach the expected state")
    }
  }
}
