import AppKit
import Foundation
import ScreenClipCore

/// Codex transport: the app-server connection, thread dispatch, server events and
/// requests, interruption, and reconciliation.
extension AgentWorker {
  func checkConnection() async {
    await authentication.check()
    guard authentication.state == .ready else { return }
    do {
      let models = try await client.request("model/list")
      model.codexModels = AgentModelCatalog.codex(fromModelList: models)
      let available = models["data"].array.flatMap { [$0["id"].string, $0["model"].string] }
        .compactMap { $0 }
      if !model.snapshot.settings.model.isEmpty
        && !available.contains(model.snapshot.settings.model)
      {
        model.connection = "Selected model is unavailable; choose another model"
      }
    } catch { model.connection = error.localizedDescription }
  }
  func signIn(method: CodexAuthentication.Method = .browser) async {
    await authentication.signIn(method: method)
  }
  func connect() async throws {
    if connected { return }
    if let connecting { return try await connecting.value }
    let task = Task { @MainActor [self] in
      let stream = try await client.connect(path: AgentDetector.codexPath(model.snapshot.settings))
      connected = true
      // Ends with the stream when the client stops.
      Task { [weak self] in for await event in stream { await self?.handle(event) } }
    }
    connecting = task
    defer { connecting = nil }
    try await task.value
  }
  func resetConnection() async {
    guard !jobs.contains(where: { model.issue($0)?.resolvedAgent == .codex }) else {
      model.banner = "Finish or cancel active Codex work before changing the Codex connection."
      return
    }
    await client.stop()
    authentication.reset()
    requestOwners.removeAll()
    model.codexModels = []
    connected = false
    model.connection = ProviderPhrase.notConnected.english(.codex)
  }
  /// Starts or resumes the issue's Codex thread and starts a turn. Completion arrives
  /// as app-server events handled in `handle(_:)`.
  func runCodex(_ id: UUID, project: Project, path: String) async throws {
    guard var issue = model.issue(id) else {
      jobs.remove(id)
      return
    }
    let mode = project.codexApprovalMode
    var threadParams: [String: JSONValue] = [
      "cwd": .string(path), "approvalPolicy": .string(mode.approvalPolicy),
      "approvalsReviewer": .string(mode.reviewer), "sandbox": .string(mode.sandbox),
    ]
    let chosenModel = issue.agentModel ?? model.snapshot.settings.model
    if !chosenModel.isEmpty { threadParams["model"] = .string(chosenModel) }
    // Runtime project identity is separate from the isolated execution directory.
    // Desktop sidebar membership must be verified independently.
    var codexProjectID: String?
    do {
      codexProjectID = try await client.projectID(forRepositoryPath: project.path)
      if codexProjectID == nil {
        try recordProjectLinkIssue(id, message: "No saved Codex project matches this repository")
      }
    } catch {
      try recordProjectLinkIssue(id, message: error.localizedDescription)
    }
    guard let current = model.issue(id), current.status == .working, jobs.contains(id) else {
      jobs.remove(id)
      return
    }
    issue = current
    if let threadID = issue.threadID {
      let resumed = try await client.resumeThread(threadID, params: threadParams)
      if resumed["thread"]["status"]["type"].string == "active" {
        throw ScreenClipError.message(
          "This issue is active in another Codex client. Wait for that turn, then reconcile.")
      }
      if let codexProjectID {
        do {
          _ = try await client.request(
            "thread/metadata/update",
            params: .object([
              "threadId": .string(threadID), "projectId": .string(codexProjectID),
            ]))
        } catch {
          try recordProjectLinkIssue(id, message: error.localizedDescription)
        }
      }
    } else {
      if let codexProjectID { threadParams["projectId"] = .string(codexProjectID) }
      try model.updateIssue(id) { $0.dispatchUncertain = true }
      let created: JSONValue
      do {
        created = try await client.request(
          "thread/start", params: .object(threadParams), timeout: 60)
      } catch let error as ScreenClipError {
        // An error reply is definite: no chat exists, so Continue may simply try again.
        if case .refused = error { try? model.updateIssue(id) { $0.dispatchUncertain = false } }
        throw error
      }
      guard let threadID = created["thread"]["id"].string else {
        throw ScreenClipError.message("Codex did not return a chat ID.")
      }
      try model.updateIssue(id) {
        $0.threadID = threadID
        $0.dispatchUncertain = false
      }
      // Older runtimes can ignore unknown fields. Do not present manual approvals as automation.
      if mode == .automaticReview, created["approvalsReviewer"].string != "auto_review" {
        throw ScreenClipError.message(
          "Codex did not enable automatic approval review. Update Codex or choose Ask me in project settings.")
      }
      _ = try? await client.request(
        "thread/name/set",
        params: .object([
          "threadId": .string(threadID), "name": .string("ScreenClip: " + issue.referencedTitle),
        ]))
    }
    guard let current = model.issue(id), current.status == .working else {
      jobs.remove(id)
      return
    }
    issue = current
    guard let threadID = issue.threadID else {
      throw ScreenClipError.message("Codex did not return a chat ID.")
    }
    if mode == .automaticReview,
      !(await client.supportsAutomaticReview(threadID: threadID))
    {
      throw ScreenClipError.message(
        "Codex did not enable automatic approval review. Update Codex or choose Ask me in project settings.")
    }
    // A resumed chat already holds earlier evidence; send only what is new.
    let turn = AgentPrompt.turn(
      for: issue, project: project, threadID: issue.threadID, settings: model.snapshot.settings)
    var input: [JSONValue] = [.object(["type": .string("text"), "text": .string(turn.text)])]
    for path in turn.captures.compactMap(\.imagePath) {
      let image = try Data(contentsOf: URL(fileURLWithPath: path))
      input.append(
        .object([
          "type": .string("image"),
          "url": .string("data:image/png;base64," + image.base64EncodedString()),
        ]))
    }
    let schema = AgentPrompt.resultSchema
    try model.updateIssue(id) {
      $0.dispatchUncertain = true
      $0.supersededTurnID = $0.consumedTurnID
      $0.coveredRevision = issue.revision
      $0.record("Investigating capture revision \(issue.revision)", status: .working)
    }
    texts[id] = nil
    sentContext[id] = AgentPrompt.delivered(issue, threadID: threadID)
    let result = try await client.request(
      "turn/start",
      params: .object([
        "threadId": .string(threadID), "input": .array(input), "outputSchema": schema,
        // A follow-up after a merge runs in a new worktree; an owned thread is not resumed,
        // so the turn is what carries the current directory.
        "cwd": .string(path),
        // Owned threads skip thread/resume. Reapply the project choice on every turn,
        // including a switch back from full access and a continuation after a question.
        "approvalPolicy": .string(mode.approvalPolicy),
        "approvalsReviewer": .string(mode.reviewer), "sandboxPolicy": mode.sandboxPolicy,
      ].merging(Self.codexModelParams(for: issue)) { $1 }), timeout: 60)
    guard let turnID = result["turn"]["id"].string else {
      throw ScreenClipError.message("Codex did not acknowledge the turn.")
    }
    let alreadyFinishing = finishing.contains(id)
    try model.updateIssue(id) {
      if $0.status == .working && !alreadyFinishing && $0.turnID == nil { $0.turnID = turnID }
      $0.dispatchUncertain = false
    }
    // Cancellation can arrive while turn/start is awaiting its acknowledgement,
    // before cancel() knows which turn to interrupt.
    if !jobs.contains(id) || model.issue(id)?.status == .canceled {
      canceledTurns.insert(turnID)
      await interrupt(threadID: threadID, turnID: turnID)
      return
    }
    watchCodexTurn(id, threadID: threadID, turnID: turnID)
  }
  /// The report's model and effort for `turn/start`. Owned threads skip thread/resume, so the
  /// turn carries the report's choice. Without one the thread keeps the Settings model.
  static func codexModelParams(for issue: Issue) -> [String: JSONValue] {
    guard let chosen = issue.agentModel, !chosen.isEmpty else { return [:] }
    var params: [String: JSONValue] = ["model": .string(chosen)]
    if let effort = issue.agentEffort, !effort.isEmpty { params["effort"] = .string(effort) }
    return params
  }
  /// Completion of a Codex turn arrives only as an app-server event. If Codex stalls without
  /// disconnecting, that event never comes, so stop the turn after `turnTimeLimit`. Time the
  /// turn spends waiting for the tester's answer does not count.
  func watchCodexTurn(_ id: UUID, threadID: String, turnID: String) {
    codexTurnWatchdogs[id]?.cancel()
    let limit = turnTimeLimit
    codexTurnWatchdogs[id] = Task { [weak self] in
      var activeTime: TimeInterval = 0
      var lastCheck = Date()
      var wasWorking = true
      while true {
        let wait = min(1, max(0.01, limit - activeTime))
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        guard !Task.isCancelled, let self else { return }
        guard let issue = self.model.issue(id), self.jobs.contains(id), issue.threadID == threadID,
          issue.turnID == nil || issue.turnID == turnID, !self.finishing.contains(id),
          !self.publishing.contains(id), issue.status == .working || issue.status == .needsYou
        else {
          self.codexTurnWatchdogs[id] = nil
          return
        }
        let now = Date()
        // Exclude intervals that touch a wait for the tester. Sampling conservatively
        // can add at most one polling interval, rather than timing out on their reply.
        if wasWorking && issue.status == .working { activeTime += now.timeIntervalSince(lastCheck) }
        lastCheck = now
        wasWorking = issue.status == .working
        guard activeTime >= limit else { continue }
        self.codexTurnWatchdogs[id] = nil
        await self.expireCodexTurn(id, threadID: threadID, turnID: turnID, limit: limit)
        return
      }
    }
  }
  func expireCodexTurn(_ id: UUID, threadID: String, turnID: String, limit: TimeInterval) async {
    let minutes = max(1, Int((limit / 60).rounded()))
    let message =
      "Codex did not finish within \(minutes) minutes and was stopped. Retry to continue in the same chat."
    // Record first, so the interrupted turn's late events cannot publish a result.
    jobs.remove(id)
    model.perform {
      try model.updateIssue(id) {
        $0.turnID = nil
        $0.dispatchUncertain = false
        $0.lastError = message
        $0.unread = true
        $0.record(message, status: .failed, kind: "error")
      }
    }
    if let issue = model.issue(id) { model.notify(issue, text: message) }
    canceledTurns.insert(turnID)
    await interrupt(threadID: threadID, turnID: turnID)
    pump()
  }
  func recordProjectLinkIssue(_ id: UUID, message: String) throws {
    let text =
      "Codex project link unavailable: \(message). Repository context is included in the prompt."
    guard model.issue(id)?.activities.contains(where: { $0.text == text }) != true else { return }
    try model.updateIssue(id) { $0.record(text) }
  }
  /// Reconcile interrupted, acknowledged work and expired permission dialogs before
  /// continuing under the project mode. Genuine user questions remain unanswered.
  func recoverCodexAfterRestart() async {
    guard !model.snapshot.settings.paused else { return }
    let ids = model.snapshot.issues.filter { issue in
      let unanswered = issue.questions.filter { $0.reply == nil }
      let interrupted = unanswered.isEmpty && model.restartedCodexIssues.contains(issue.id)
      let permissionOnly = !unanswered.isEmpty && unanswered.allSatisfy {
        $0.requestID != nil && CodexRequestKind(method: $0.requestMethod).isApproval
      }
      return issue.resolvedAgent == .codex && issue.status == .needsYou && !issue.archived
        && !isActive(issue.id) && !issue.dispatchUncertain
        && model.project(issue.projectID)?.codexApprovalMode != .ask
        && model.project(issue.projectID) != nil && (interrupted || permissionOnly)
    }.map(\.id)
    for id in ids {
      guard !model.snapshot.settings.paused else { return }
      guard let issue = model.issue(id),
        model.project(issue.projectID)?.codexApprovalMode != .ask else { continue }
      await reconcile(id)
      // Reconcile refuses an active or mismatched chat, retaining its unanswered requests.
      // It may also recover an implemented result and start publication instead.
      if let issue = model.issue(id), issue.status == .needsYou, !issue.dispatchUncertain,
        !isActive(id), model.project(issue.projectID)?.codexApprovalMode != .ask,
        issue.questions.allSatisfy({ $0.reply != nil })
      {
        model.retry(id)
      }
    }
  }
  /// Approve this exact pending request once, then let Codex review later requests.
  /// Never save a command-prefix rule or infer consent from capture evidence.
  func allowAndAutomate(issueID: UUID, questionID: UUID) async {
    guard let issue = model.issue(issueID), issue.resolvedAgent == .codex,
      jobs.contains(issueID), let threadID = issue.threadID, let turnID = issue.turnID,
      let question = issue.questions.first(where: { $0.id == questionID && $0.reply == nil }),
      let requestID = question.requestID,
      requestOwners[Self.requestKey(requestID)] == issueID,
      CodexRequestKind(method: question.requestMethod).isApproval,
      CodexApprovalOptions(method: question.requestMethod ?? "", params: question.questions ?? .null)
        .permits("accept"),
      model.project(issue.projectID) != nil
    else { return }
    do {
      // Changing a turn does not reroute its already pending request. The button explicitly
      // approves that request; subsequent steps use automatic review, in the same sandbox.
      let updated = try await client.request("turn/settings/update", params: .object([
        "threadId": .string(threadID), "turnId": .string(turnID),
        "approvalsReviewer": .string("auto_review"),
      ]))
      guard updated["status"].string == "applied" else {
        throw ScreenClipError.message("Codex could not update this turn. Reconcile the chat before continuing.")
      }
      _ = try await client.request("thread/settings/update", params: .object([
        "threadId": .string(threadID), "approvalPolicy": .string("on-request"),
        "approvalsReviewer": .string("auto_review"),
      ]))
      // Re-read after awaits so saving the mode cannot overwrite concurrent project edits.
      guard jobs.contains(issueID), requestOwners[Self.requestKey(requestID)] == issueID,
        model.issue(issueID)?.questions.contains(where: { $0.id == questionID && $0.reply == nil }) == true,
        let current = model.project(issue.projectID) else { return }
      var project = current
      project.codexApprovalMode = .automaticReview
      try model.saveProject(project)
      await reply(issueID: issueID, questionID: questionID, answers: [:], allow: true)
    } catch { model.banner = error.localizedDescription }
  }
  func handle(_ message: JSONValue) async {
    guard let method = message["method"].string else { return }
    if method == "account/login/completed" || method == "account/updated" {
      await authentication.handleNotification(method: method, params: message["params"])
      return
    }
    if method == "screenclip/disconnected" {
      connected = false
      authentication.reset(message: "Codex disconnected. Check the connection to reconnect.")
      requestOwners.removeAll()
      // Another account may sign in on reconnect; its model list is read again then.
      model.codexModels = []
      model.connection = ProviderPhrase.disconnected.english(.codex)
      // Work already in validation or publication no longer needs the Codex connection.
      for id in jobs
      where model.issue(id)?.resolvedAgent == .codex && !finishing.contains(id)
        && !publishing.contains(id)
      {
        codexTurnWatchdogs.removeValue(forKey: id)?.cancel()
        model.perform {
          try model.updateIssue(id) {
            $0.record(
              "Worker disconnected. Reconcile the chat before continuing.", status: .needsYou)
          }
        }
        jobs.remove(id)
      }
      return
    }
    let p = message["params"]
    let threadID = p["threadId"].string ?? p["thread"]["id"].string
    guard let issue = model.snapshot.issues.first(where: {
      $0.resolvedAgent == .codex && $0.threadID == threadID
    }), let threadID
    else {
      if message["id"] != .null {
        try? await client.reject(
          id: message["id"], message: "ScreenClip cannot handle this request for an unknown issue.")
      }
      return
    }
    let id = issue.id
    if message["id"] != .null {
      guard jobs.contains(id), issue.status != .canceled else {
        try? await client.reject(
          id: message["id"], message: "This ScreenClip issue is no longer running.")
        return
      }
      requestOwners[Self.requestKey(message["id"])] = id
      let isQuestion = CodexRequestKind(method: method) == .userInput
      let title =
        isQuestion
        ? p["questions"].array.map { $0["question"].string ?? $0["header"].string ?? "Question" }
          .joined(separator: "\n")
        : (p["reason"].string ?? p["message"].string ?? "Codex requests permission to continue.")
      let question = PendingQuestion(
        title: title, requestID: message["id"], questions: isQuestion ? p["questions"] : p,
        requestMethod: method)
      model.perform {
        try model.updateIssue(id) {
          // A card left from an earlier Codex process can carry the same request id.
          for i in $0.questions.indices
          where $0.questions[i].requestID == message["id"] && $0.questions[i].reply == nil {
            $0.questions[i].reply = "Expired request; continue the issue to ask again"
          }
          $0.questions.append(question)
          $0.unread = true
          $0.record(title, status: .needsYou, kind: "question")
        }
      }
      model.notify(issue, text: title)
      // A report waiting for the tester gives its slot to the next queued one.
      pump()
      return
    }
    switch method {
    case "turn/started":
      if jobs.contains(id), let turn = p["turn"]["id"].string {
        model.perform {
          try model.updateIssue(id) { if $0.status != .canceled { $0.turnID = turn } }
        }
      }
    case "item/completed":
      let item = p["item"]
      if item["type"].string == "agentMessage", let text = item["text"].string {
        texts[id] = text
        if item["phase"].string != "final_answer" {
          model.updateIssueSoon(id) { $0.record(String(text.prefix(3000))) }
        }
      }
    case "turn/completed":
      guard jobs.contains(id) else { return }
      guard issue.turnID == nil || issue.turnID == p["turn"]["id"].string else { return }
      // A canceled turn finishing late, after Continue queued the report again.
      if let turn = p["turn"]["id"].string, canceledTurns.remove(turn) != nil,
        ![.canceled, .failed].contains(issue.status)
      {
        return
      }
      codexTurnWatchdogs.removeValue(forKey: id)?.cancel()
      let delivered = sentContext.removeValue(forKey: id)
      if p["turn"]["status"].string == "completed" {
        if let delivered, delivered.threadID == threadID {
          model.perform { try model.updateIssue(id) { $0.deliveredContext = delivered } }
        }
        if let turn = p["turn"]["id"].string {
          model.perform { try model.updateIssue(id) { $0.consumedTurnID = turn } }
        }
        // Marked synchronously, so a second completion event cannot start another finish.
        if finishing.insert(id).inserted {
          Task { await finishMarked(id) }
        }
      } else {
        let error =
          p["turn"]["error"]["message"].string ?? "Turn " + (p["turn"]["status"].string ?? "failed")
        if issue.status != .canceled, AgentDetector.isSignInError(error) {
          holdForSignIn(id, agent: .codex)
          pump()
          return
        }
        jobs.remove(id)
        model.perform {
          try model.updateIssue(id) {
            $0.turnID = nil
            $0.dispatchUncertain = false
            $0.lastError = error
            $0.record(error, status: $0.status == .canceled ? .canceled : .failed)
          }
        }
      }
    case "error":
      if p["willRetry"].bool != true {
        model.perform {
          try model.updateIssue(id) { $0.lastError = p["error"]["message"].string ?? "Codex error" }
        }
      }
    case "serverRequest/resolved":
      requestOwners.removeValue(forKey: Self.requestKey(p["requestId"]))
      model.perform {
        try model.updateIssue(id) { issue in
          for i in issue.questions.indices
          where issue.questions[i].requestID == p["requestId"] && issue.questions[i].reply == nil {
            issue.questions[i].reply = "Request resolved in Codex"
          }
          if issue.status == .needsYou && issue.turnID != nil && jobs.contains(id)
            && issue.questions.allSatisfy({ $0.reply != nil })
          {
            issue.record("Continuing in Codex", status: .working)
          }
        }
      }
    default: break
    }
  }
  func interrupt(threadID: String, turnID: String) async {
    _ = try? await client.request(
      "turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
  }
  func reconcile(_ id: UUID, linkingThread: String? = nil) async {
    guard let issue = model.issue(id) else { return }
    if issue.resolvedAgent == .external {
      model.banner =
        "The conversation is in Grok Bot's chat. ScreenClip cannot open or reconcile it from here."
      return
    }
    if issue.resolvedAgent == .claude {
      await reconcileClaude(id, linkingSession: linkingThread)
      return
    }
    do {
      try await connect()
      guard !jobs.contains(id) else {
        throw ScreenClipError.message("Cancel the active run before changing its chat binding.")
      }
      guard let thread = linkingThread ?? issue.threadID else {
        throw ScreenClipError.message(
          "Chat creation was not acknowledged. Locate the ScreenClip chat in Codex and use Link existing chat before retrying."
        )
      }
      let result = try await client.request(
        "thread/read", params: .object(["threadId": .string(thread)]))
      guard let path = issue.worktreePath, result["thread"]["cwd"].string == path else {
        throw ScreenClipError.message(
          "This chat does not belong to the issue's workspace. The existing chat binding was retained."
        )
      }
      let active = result["thread"]["status"]["type"].string == "active"
      if active {
        throw ScreenClipError.message(
          "This chat still has an active turn. Open it in Codex and wait or interrupt before continuing."
        )
      }
      let history = try await client.request(
        "thread/turns/list", params: .object([
          "threadId": .string(thread), "limit": .number(1), "itemsView": .string("full"),
        ]))
      guard history["data"].array.first?["status"].string != "inProgress" else {
        throw ScreenClipError.message(
          "The latest saved turn is still running. Finish or interrupt it in Codex before continuing."
        )
      }
      // A user can cancel, add context, or retry while the history request is in flight.
      // Reconciliation must not replace that newer decision, including during auto recovery.
      guard let current = model.issue(id), current.status == issue.status,
        current.revision == issue.revision, current.threadID == issue.threadID, !isActive(id)
      else { return }
      try model.updateIssue(id) { issue in
        issue.threadID = thread
        issue.dispatchUncertain = false
        issue.turnID = nil
        issue.lastError = nil
        for i in issue.questions.indices
        where issue.questions[i].requestID != nil && issue.questions[i].reply == nil {
          issue.questions[i].reply = "Expired request; continue the issue to ask again"
        }
        issue.record("Chat reconciled. Continue when ready.", status: .needsYou)
      }
      // Recover completed work after a restart, including work finished in Codex.
      // Publishing still independently validates source, revision, and PR head.
      if linkingThread == nil, issue.revision == issue.coveredRevision,
        let turn = history["data"].array.first, turn["status"].string == "completed",
        // Not the older result a later dispatch superseded, when that newer turn never started.
        turn["id"].string == nil || turn["id"].string != issue.supersededTurnID,
        let final = turn["items"].array.last(where: {
          $0["type"].string == "agentMessage" && $0["phase"].string == "final_answer"
        })?["text"].string,
        let report = try? JSONDecoder().decode(JSONValue.self, from: Data(final.utf8)),
        report["outcome"].string == "implemented",
        model.issue(id)?.questions.allSatisfy({ $0.reply != nil }) == true
      {
        texts[id] = final
        jobs.insert(id)
        try model.updateIssue(id) {
          $0.consumedTurnID = turn["id"].string
          $0.record("Recovering completed fix", status: .working)
        }
        // Marked finishing like a live completion, so a disconnect meanwhile cannot fail it.
        await finishOnce(id)
      }
    } catch { model.banner = error.localizedDescription }
  }
}
