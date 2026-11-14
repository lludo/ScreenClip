import AppKit
import Foundation
import ScreenClipCore

@MainActor final class AgentWorker {
  unowned let model: AppModel
  let client = CodexClient()
  let claude = ClaudeCodeClient()
  var connected = false
  var connecting: Task<Void, Error>?
  var eventsTask: Task<Void, Never>?
  var jobs = Set<UUID>()
  // Keep canceled dispatches serialized until their outstanding requests return.
  var dispatching = Set<UUID>()
  var texts: [UUID: String] = [:]
  var receipts: [UUID: ValidationReceipt] = [:]
  var publishing = Set<UUID>()
  var finishing = Set<UUID>()
  var refreshing = Set<UUID>()
  var lastExternalDiscovery = Date.distantPast
  /// The run that currently owns each Grok Bot report. Cancel clears it, so a run still in
  /// flight stops at its next check and cannot remove a later run's job after a retry.
  var externalRuns: [UUID: UUID] = [:]
  var mergingProjects = Set<UUID>()
  var pendingRequests = Set<String>()
  var timer: Timer?
  /// A turn running longer than this, not counting time spent waiting for the tester, is stopped.
  var turnTimeLimit: TimeInterval = 45 * 60
  /// How often agents holding queued reports are checked again.
  var heldRecheckInterval: TimeInterval = 60
  var lastCodexAuthCheck = Date.distantPast
  /// Time limit for each running Codex turn, keyed by issue.
  var codexTurnWatchdogs: [UUID: Task<Void, Never>] = [:]
  /// What each running Codex turn is sending, recorded on the issue once the turn completes.
  var sentContext: [UUID: DeliveredContext] = [:]
  lazy var authentication = CodexAuthentication(
    request: { [unowned self] method, params in
      try await self.connect()
      return try await self.client.request(method, params: params)
    },
    openURL: { NSWorkspace.shared.open($0) },
    statusChanged: { [unowned self] in
      self.model.connection = $0
      // Signing in releases Codex reports held while signed out.
      self.pump()
    }
  )
  init(model: AppModel) { self.model = model }
  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.pump()
        await self?.recheckHeldAgents()
        await self?.refreshPullRequests(discoverInterval: 60)
      }
    }
    Task {
      await model.refreshAgents()
      // Only probe Codex sign-in when Codex is present, so a Claude-only Mac shows no Codex error.
      if model.detection(.codex)?.installed != false { await checkConnection() }
      await recoverClaudeAfterRestart()
    }
    pump()
  }
  /// True while ScreenClip may still be dispatching, running, or publishing this issue.
  func isActive(_ id: UUID) -> Bool {
    jobs.contains(id) || dispatching.contains(id) || finishing.contains(id)
      || publishing.contains(id)
  }
  /// Worktree creation and removal per project, one at a time: concurrent `git fetch` and
  /// `git worktree` calls on one repository contend for the same config and ref locks.
  private var workspaceChanges: [UUID: Task<Void, Never>] = [:]
  func serializedWorkspaceChange<T: Sendable>(
    _ projectID: UUID, _ body: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let previous = workspaceChanges[projectID]
    let task = Task { @MainActor () async throws -> T in
      await previous?.value
      return try await body()
    }
    workspaceChanges[projectID] = Task { _ = try? await task.value }
    return try await task.value
  }
  func pump() {
    guard !model.snapshot.settings.paused else { return }
    // Each report runs in its own worktree, so a project runs up to the configured number at once.
    let limit = model.snapshot.settings.parallelReportLimit
    // Count work ScreenClip is actually doing. A report left "working" without a job (after
    // an interrupted publish, for example) must not hold a slot forever.
    var running = model.snapshot.issues.filter { isActive($0.id) }.reduce(into: [UUID: Int]()) { counts, issue in
      if let projectID = issue.projectID { counts[projectID, default: 0] += 1 }
    }
    for issue in model.snapshot.issues
    where issue.status == .queued && !issue.archived && !issue.dispatchUncertain
      && !jobs.contains(issue.id)
      && !dispatching.contains(issue.id)
    {
      guard let project = model.project(issue.projectID), running[project.id, default: 0] < limit
      else { continue }
      if isHeld(issue.resolvedAgent) { continue }
      jobs.insert(issue.id)
      dispatching.insert(issue.id)
      running[project.id, default: 0] += 1
      Task { [model] in await model.worker.dispatch(issue.id) }
    }
  }
  /// Whether queued work for `agent` waits: detection found it missing, signed out, or not
  /// configured, or Codex sign-in is known to be signed out. Grok Bot stays queued until
  /// detection has seen a saved webhook, including before the first check.
  func isHeld(_ agent: AgentKind) -> Bool {
    switch agent {
    case .external: return model.detection(.external)?.usable != true
    case .codex:
      return model.detection(.codex)?.usable == false || authentication.state == .signedOut
    case .claude: return model.detection(.claude)?.usable == false
    }
  }
  /// While reports are held, check their agents again every `heldRecheckInterval`, so signing
  /// in from Terminal or finishing an install resumes the queue without visiting Settings.
  func recheckHeldAgents(now: Date = Date()) async {
    guard !model.snapshot.settings.paused else { return }
    let held = Set(
      model.snapshot.issues.filter {
        $0.status == .queued && !$0.archived && model.project($0.projectID) != nil
      }.map(\.resolvedAgent)
    ).filter(isHeld)
    guard !held.isEmpty else { return }
    if now.timeIntervalSince(model.lastAgentDetection) >= heldRecheckInterval {
      await model.refreshAgents(automatic: true)
    }
    if held.contains(.codex), authentication.state == .signedOut,
      now.timeIntervalSince(lastCodexAuthCheck) >= heldRecheckInterval
    {
      lastCodexAuthCheck = now
      await authentication.check()
      pump()
    }
  }
  /// A run failed because its agent is signed out. Put the report back in the queue, held
  /// until the agent is signed in, instead of failing it and every report queued after it.
  func holdForSignIn(_ id: UUID, agent: AgentKind) {
    jobs.remove(id)
    model.agentReportedSignedOut(agent)
    model.perform {
      try model.updateIssue(id) {
        $0.turnID = nil
        $0.dispatchUncertain = false
        $0.lastError = nil
        $0.unread = true
        $0.record(
          "\(agent.title) is signed out. This report starts again once you sign in.",
          status: .queued)
      }
    }
    if let issue = model.issue(id) {
      model.notify(issue, text: "\(agent.title) is signed out. Sign in to continue.")
    }
  }
  func dispatch(_ id: UUID) async {
    defer {
      dispatching.remove(id)
      pump()
    }
    do {
      guard var issue = model.issue(id), let project = model.project(issue.projectID) else {
        throw ScreenClipError.message("Choose a project.")
      }
      if issue.resolvedAgent == .codex { try await connect() }
      issue = model.issue(id) ?? issue
      guard issue.status == .queued && jobs.contains(id) else {
        jobs.remove(id)
        return
      }
      if issue.resolvedAgent == .external {
        await runExternal(id, project: project)
        return
      }
      try model.updateIssue(id) {
        $0.record("Preparing isolated workspace", status: .working)
      }
      if issue.worktreePath == nil {
        let workspaceID = issue.workspaceID
        let workspace = try await serializedWorkspaceChange(project.id) { [model] in
          try await GitWorkspace.prepare(
            project: project, issueID: workspaceID, root: model.store.root)
        }
        try model.updateIssue(id) {
          $0.worktreePath = workspace.path
          $0.branch = workspace.branch
        }
      }
      guard let current = model.issue(id), current.status == .working else {
        jobs.remove(id)
        return
      }
      issue = current
      guard let path = issue.worktreePath else {
        throw ScreenClipError.message("Workspace preparation failed.")
      }
      if issue.resolvedAgent == .claude {
        try await runClaude(id, project: project, path: path)
        return
      }
      try await runCodex(id, project: project, path: path)
    } catch {
      if let agent = model.issue(id)?.resolvedAgent, agent != .external,
        AgentDetector.isSignInError(error.localizedDescription),
        model.issue(id)?.status == .working, model.issue(id)?.dispatchUncertain != true
      {
        holdForSignIn(id, agent: agent)
        return
      }
      jobs.remove(id)
      model.perform {
        try model.updateIssue(id) {
          $0.lastError = error.localizedDescription
          $0.record(
            error.localizedDescription,
            status: $0.status == .canceled
              ? .canceled : ($0.dispatchUncertain ? .needsYou : .failed), kind: "error")
        }
      }
    }
  }
  func reply(
    issueID: UUID, questionID: UUID, answers: [String: String], allow: Bool? = nil,
    approvalDecision: JSONValue? = nil
  ) async {
    guard let issue = model.issue(issueID),
      let question = issue.questions.first(where: { $0.id == questionID })
    else { return }
    do {
      if let requestID = question.requestID {
        guard connected && pendingRequests.contains(requestID.data.base64EncodedString()) else {
          throw ScreenClipError.message(
            "Reconnect and reconcile the chat; the original request may no longer be pending.")
        }
        let method = question.requestMethod ?? ""
        if method.contains("requestUserInput") {
          try await client.respond(
            id: requestID,
            result: .object([
              "answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })
            ]))
        } else if method.contains("requestApproval") && !method.contains("permissions") {
          let options = CodexApprovalOptions(method: method, params: question.questions ?? .null)
          let decision = approvalDecision ?? .string(allow == true ? "accept" : "decline")
          guard (decision.string.map { options.permits($0) } ?? (decision == options.ruleDecision)) else {
            throw ScreenClipError.message("This approval choice is no longer available.")
          }
          try await client.respond(
            id: requestID,
            result: .object(["decision": decision]))
        } else {
          try await client.reject(
            id: requestID, message: "Complete this permission or connection request in Codex.")
        }
        pendingRequests.remove(requestID.data.base64EncodedString())
        try model.updateIssue(issueID) { issue in
          if let i = issue.questions.firstIndex(where: { $0.id == questionID }) {
            issue.questions[i].reply =
              (approvalDecision == .string("cancel") ? "Canceled" :
                approvalDecision == .string("acceptForSession") ? "Allowed for this chat" :
                (approvalDecision != nil ? "Allowed with a saved command rule" : nil))
              ?? allow.map { $0 ? "Allowed once" : "Declined" }
              ?? answers.values.joined(separator: "\n")
          }
          let waiting = issue.questions.contains { $0.requestID != nil && $0.reply == nil }
          issue.record("Reply sent to Codex", status: waiting ? .needsYou : .working)
        }
      } else {
        try model.updateIssue(issueID) { issue in
          if let i = issue.questions.firstIndex(where: { $0.id == questionID }) {
            issue.questions[i].reply = answers.values.joined(separator: "\n")
          }
          issue.record("Reply submitted", status: .queued)
        }
        jobs.remove(issueID)
        pump()
      }
    } catch { model.banner = error.localizedDescription }
  }
  func cancel(_ id: UUID) async {
    guard let issue = model.issue(id) else { return }
    if issue.resolvedAgent == .external {
      let remoteCancel = model.loadExternalAssistant().supportsCancel
      model.perform {
        try model.updateIssue(id) {
          $0.dispatchUncertain = false
          $0.turnID = nil
          $0.record(
            remoteCancel
              ? ExternalAssistant.bestEffortCancelActivity : ExternalAssistant.canceledActivity,
            status: .canceled)
        }
      }
      externalRuns.removeValue(forKey: id)
      jobs.remove(id)
      if remoteCancel { await sendExternalCancel(issue) }
      return
    }
    // Cancellation is recorded before interrupting, so late events cannot publish the result.
    model.perform {
      try model.updateIssue(id) {
        $0.turnID = nil
        $0.dispatchUncertain = false
        $0.record("Canceled; existing workspace and PR retained", status: .canceled)
      }
    }
    if issue.resolvedAgent == .claude, let session = issue.threadID {
      await claude.cancel(sessionID: session)
    } else if let thread = issue.threadID, let turn = issue.turnID {
      await interrupt(threadID: thread, turnID: turn)
    }
    codexTurnWatchdogs.removeValue(forKey: id)?.cancel()
    jobs.remove(id)
  }
}
