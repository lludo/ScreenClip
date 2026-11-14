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
  var mergingProjects = Set<UUID>()
  var pendingRequests = Set<String>()
  var timer: Timer?
  lazy var authentication = CodexAuthentication(
    request: { [unowned self] method, params in
      try await self.connect()
      return try await self.client.request(method, params: params)
    },
    openURL: { NSWorkspace.shared.open($0) },
    statusChanged: { [unowned self] in self.model.connection = $0 }
  )
  init(model: AppModel) { self.model = model }
  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.pump()
        await self?.refreshPullRequests(discoverInterval: 60)
      }
    }
    Task {
      await model.refreshAgents()
      // Only probe Codex sign-in when Codex is present, so a Claude-only Mac shows no Codex error.
      if model.detection(.codex)?.installed != false { await checkConnection() }
    }
    pump()
  }
  /// True while ScreenClip may still be dispatching, running, or publishing this issue.
  func isActive(_ id: UUID) -> Bool {
    jobs.contains(id) || dispatching.contains(id) || finishing.contains(id)
      || publishing.contains(id)
  }
  func pump() {
    guard !model.snapshot.settings.paused else { return }
    var busyProjects = Set(
      model.snapshot.issues.filter {
        jobs.contains($0.id) || dispatching.contains($0.id)
          || ($0.status == .working && $0.resolvedAgent != .external)
      }.compactMap(
        \.projectID))
    for issue in model.snapshot.issues
    where issue.status == .queued && !issue.archived && !issue.dispatchUncertain
      && !jobs.contains(issue.id)
      && !dispatching.contains(issue.id)
    {
      guard let project = model.project(issue.projectID), !busyProjects.contains(project.id) else {
        continue
      }
      // Hold work for an agent that detection found missing, signed out, or not configured.
      // Grok Bot stays queued until detection has seen a saved webhook, including before the first check.
      if issue.resolvedAgent == .external {
        if model.detection(.external)?.usable != true { continue }
      } else if model.detection(issue.resolvedAgent)?.usable == false {
        continue
      }
      jobs.insert(issue.id)
      dispatching.insert(issue.id)
      busyProjects.insert(project.id)
      Task { [model] in await model.worker.dispatch(issue.id) }
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
        let workspace = try await GitWorkspace.prepare(
          project: project, issueID: issue.workspaceID, root: model.store.root)
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
  func reply(issueID: UUID, questionID: UUID, answers: [String: String], allow: Bool? = nil) async {
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
          try await client.respond(
            id: requestID,
            result: .object(["decision": .string(allow == true ? "accept" : "decline")]))
        } else {
          try await client.reject(
            id: requestID, message: "Complete this permission or connection request in Codex.")
        }
        pendingRequests.remove(requestID.data.base64EncodedString())
        try model.updateIssue(issueID) { issue in
          if let i = issue.questions.firstIndex(where: { $0.id == questionID }) {
            issue.questions[i].reply =
              allow.map { $0 ? "Allowed once" : "Declined" }
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
      model.perform {
        try model.updateIssue(id) {
          $0.dispatchUncertain = false
          $0.turnID = nil
          $0.record(ExternalAssistant.canceledActivity, status: .canceled)
        }
      }
      jobs.remove(id)
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
    jobs.remove(id)
  }
}
