import AppKit
import Foundation
import ScreenClipCore

/// Claude Code transport: one headless turn per dispatch, progress, and reconciliation.
extension AgentWorker {
  /// Runs one headless Claude Code turn in the issue's worktree and hands the
  /// structured result to the same finish/publish path Codex uses.
  func runClaude(_ id: UUID, project: Project, path: String) async throws {
    guard var issue = model.issue(id) else { return }
    let executable = AgentDetector.claudePath(model.snapshot.settings)
    // ScreenClip chooses the session ID before starting the process.
    let resume = issue.threadID != nil
    let sessionID = issue.threadID ?? UUID().uuidString.lowercased()
    if resume, try await claude.sessionIsRunning(sessionID: sessionID) {
      throw ScreenClipError.message(
        "This Claude Code session is still running. Wait or cancel it before continuing.")
    }
    guard let current = model.issue(id), current.status == .working, jobs.contains(id) else {
      jobs.remove(id)
      return
    }
    issue = current
    // Read every screenshot up front, so a missing file fails before the session is touched.
    var allImages: [UUID: Data] = [:]
    for capture in issue.captures {
      if let path = capture.imagePath {
        allImages[capture.id] = try Data(contentsOf: URL(fileURLWithPath: path))
      }
    }
    try model.updateIssue(id) {
      $0.threadID = sessionID
      $0.turnID = Self.claudeTurnID(sessionID)
      $0.dispatchUncertain = false
      $0.coveredRevision = issue.revision
      $0.record("Investigating capture revision \(issue.revision) with Claude Code", status: .working)
    }
    // updateIssue throws when the report is gone, so it exists here.
    issue = model.issue(id) ?? issue
    texts[id] = nil
    // A resumed session already holds earlier evidence; send only what is new.
    let turn = AgentPrompt.turn(
      for: issue, project: project, threadID: resume ? sessionID : nil,
      settings: model.snapshot.settings)
    var request = ClaudeTurnRequest(
      executable: executable, cwd: path, sessionID: sessionID, resume: resume,
      name: "ScreenClip: " + issue.referencedTitle,
      model: (issue.agentModel ?? model.snapshot.settings.claudeModel).flatMap {
        $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
      },
      effort: issue.agentModel == nil ? nil : issue.agentEffort, prompt: turn.text,
      images: turn.captures.compactMap { allImages[$0.id] }, schema: AgentPrompt.resultSchema)
    request.timeout = turnTimeLimit
    request.additionalDirectories = issue.captures.compactMap { $0.diagnostics?.folder }
    let progress: @Sendable (String) async -> Void = { [weak self] text in
      await self?.recordProgress(id, text: text)
    }
    var result: ClaudeTurnResult
    do {
      do {
        result = try await claude.run(request, progress: progress)
        if resume, result.isError,
          result.text.localizedCaseInsensitiveContains("no conversation found")
        {
          throw ScreenClipError.message(result.text)
        }
      } catch {
        // Missing sessions may be reported as a JSON result or only on stderr.
        guard resume,
          error.localizedDescription.localizedCaseInsensitiveContains("no conversation found")
        else { throw error }
        guard model.issue(id)?.status == .working, jobs.contains(id) else {
          throw CancellationError()
        }
        let fresh = UUID().uuidString.lowercased()
        try model.updateIssue(id) {
          $0.threadID = fresh
          $0.turnID = Self.claudeTurnID(fresh)
          $0.record("Previous Claude Code session was not found; starting a new session")
        }
        request.sessionID = fresh
        request.resume = false
        // The new session has seen nothing yet.
        let full = AgentPrompt.turn(
          for: issue, project: project, threadID: nil, settings: model.snapshot.settings)
        request.prompt = full.text
        request.images = full.captures.compactMap { allImages[$0.id] }
        result = try await claude.run(request, progress: progress)
      }
    } catch is CancellationError {
      jobs.remove(id)
      model.perform { try model.updateIssue(id) { $0.turnID = nil } }
      return
    } catch {
      model.perform { try model.updateIssue(id) { $0.turnID = nil } }
      throw error
    }
    // A used-up model must not fail the report: carry on with the next model in the chain.
    var limitText: String? =
      result.isError && AgentDetector.isUsageLimitError(result.text) ? result.text : nil
    var fallbacks = AgentModelCatalog.claudeFallbacks(after: request.model)
    while limitText != nil, !fallbacks.isEmpty {
      guard model.issue(id)?.status == .working, jobs.contains(id) else {
        jobs.remove(id)
        model.perform { try model.updateIssue(id) { $0.turnID = nil } }
        return
      }
      let next = fallbacks.removeFirst()
      let previous = request.model.map(Self.modelTitle) ?? "The default model"
      if !request.resume {
        // The limited turn may never have started its session; start a clean one. It may still
        // have edited the worktree before the limit, so the new session looks first.
        let fresh = UUID().uuidString.lowercased()
        request.sessionID = fresh
        if !request.prompt.contains(Self.partialChangesNote) {
          request.prompt += "\n\n" + Self.partialChangesNote
        }
        model.perform {
          try model.updateIssue(id) {
            $0.threadID = fresh
            $0.turnID = Self.claudeTurnID(fresh)
          }
        }
      }
      model.perform {
        try model.updateIssue(id) {
          $0.record("\(previous) is at its usage limit; continuing with \(Self.modelTitle(next))")
        }
      }
      request.model = next
      // Efforts differ per model; let the fallback use its own default.
      request.effort = nil
      do {
        result = try await claude.run(request, progress: progress)
        limitText =
          result.isError && AgentDetector.isUsageLimitError(result.text) ? result.text : nil
      } catch is CancellationError {
        jobs.remove(id)
        model.perform { try model.updateIssue(id) { $0.turnID = nil } }
        return
      } catch where AgentDetector.isUsageLimitError(error.localizedDescription) {
        limitText = error.localizedDescription
      } catch {
        model.perform { try model.updateIssue(id) { $0.turnID = nil } }
        throw error
      }
    }
    if let limitText {
      model.perform { try model.updateIssue(id) { $0.turnID = nil } }
      // Canceled during the last attempt: leave it canceled.
      guard model.issue(id)?.status == .working, jobs.contains(id) else {
        jobs.remove(id)
        return
      }
      holdForUsageLimit(id, agent: .claude, detail: limitText)
      return
    }
    let delivered = AgentPrompt.delivered(issue, threadID: request.sessionID)
    model.perform {
      try model.updateIssue(id) {
        $0.turnID = nil
        if !result.isError { $0.deliveredContext = delivered }
        $0.record("Claude Code turn finished · " + result.usageSummary, kind: "usage")
      }
    }
    guard model.issue(id)?.status == .working, jobs.contains(id) else {
      jobs.remove(id)
      return
    }
    if result.isError {
      if AgentDetector.isSignInError(result.text) {
        holdForSignIn(id, agent: .claude)
        return
      }
      let text = result.text.isEmpty ? "Claude Code reported an error." : result.text
      throw ScreenClipError.message(String(text.prefix(3000)))
    }
    if let json = result.outputJSON {
      if !result.permissionDenials.isEmpty,
        let report = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
        report["outcome"].string != "implemented"
      {
        model.perform {
          try model.updateIssue(id) {
            $0.record("Blocked tools: " + result.permissionDenials.joined(separator: "\n"),
              kind: "permission-denial")
          }
        }
        let question = report["question"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if report["outcome"].string == "blocked" || question.isEmpty {
          // Keep the agent's own explanation: the generic message replaces the result.
          let summary =
            report["summary"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          if !summary.isEmpty {
            model.perform { try model.updateIssue(id) { $0.record(String(summary.prefix(3000))) } }
          }
          throw ScreenClipError.message(Self.claudePermissionFailure)
        }
      }
      texts[id] = json
    }
    await finishOnce(id)
  }
  static let partialChangesNote =
    "An earlier attempt on this report stopped at a model usage limit and may have left uncommitted changes in this worktree. Run `git status` and `git diff` first, keep what is right, and build on it rather than starting over."
  static func modelTitle(_ id: String) -> String {
    AgentModelCatalog.claude.first { $0.id == id.lowercased() }?.title ?? id
  }
  /// Claude Code has no turn IDs; a running session stands in for its turn.
  static func claudeTurnID(_ session: String) -> String { "claude:" + session }
  static let claudePermissionFailure = """
    Claude Code could not run a required tool because access was denied. No text reply can grant that access. Choose Continue to retry with automatic permission review. If it is denied again, open the Claude chat to inspect the restriction. Technical details are in Activity.
    """

  /// Older versions put raw permission denials in a reply box. Restore a usable
  /// Continue action without inventing a user reply or discarding real questions.
  func recoverClaudePermissionQuestions() {
    for issue in model.snapshot.issues where issue.resolvedAgent == .claude
      && issue.status == .needsYou && !issue.archived && !isActive(issue.id)
      && issue.turnID == nil && !issue.dispatchUncertain
    {
      let pending = issue.questions.filter { $0.reply == nil }
      guard !pending.isEmpty, pending.allSatisfy({
        $0.requestID == nil && $0.title.hasPrefix("Blocked tools: ")
      }) else { continue }
      let ids = Set(pending.map(\.id))
      model.perform {
        try model.updateIssue(issue.id) {
          for question in pending { $0.record(question.title, kind: "permission-denial") }
          $0.questions.removeAll { ids.contains($0.id) }
          $0.lastError = Self.claudePermissionFailure
          $0.record(Self.claudePermissionFailure, status: .failed, kind: "error")
        }
      }
    }
  }
  /// A Claude turn cannot survive a ScreenClip restart: the process belonged to the old app.
  /// When no process for the session is still running, continue the same session instead of
  /// waiting for a manual reconcile. A session still running elsewhere keeps waiting.
  func recoverClaudeAfterRestart() async {
    recoverClaudePermissionQuestions()
    for id in model.takeRestartedClaudeIssues() {
      guard let issue = model.issue(id), issue.status == .needsYou, !issue.archived,
        issue.resolvedAgent == .claude, !isActive(id),
        issue.activities.last?.text == AppModel.restartActivity
      else { continue }
      if let session = issue.threadID {
        // Unknown (ps failed) is treated like running: the tester reconciles.
        guard (try? await claude.sessionIsRunning(sessionID: session)) == false else { continue }
      }
      guard model.issue(id)?.activities.last?.text == AppModel.restartActivity, !isActive(id)
      else { continue }
      model.perform {
        try model.updateIssue(id) {
          $0.turnID = nil
          $0.dispatchUncertain = false
          $0.record(
            "No Claude Code process survived the restart; continuing the same session",
            status: .queued)
        }
      }
    }
    pump()
  }
  func recordProgress(_ id: UUID, text: String) {
    guard model.issue(id)?.status == .working else { return }
    model.updateIssueSoon(id) { $0.record(String(text.prefix(3000))) }
  }
  /// Reconciliation checks for surviving children and Terminal sessions before
  /// allowing another turn. Claude history is resumed on Continue.
  func reconcileClaude(_ id: UUID, linkingSession: String?) async {
    do {
      guard !jobs.contains(id), !dispatching.contains(id) else {
        throw ScreenClipError.message("Cancel the active run before changing its session.")
      }
      if let linkingSession {
        guard UUID(uuidString: linkingSession) != nil else {
          throw ScreenClipError.message("Enter the Claude Code session ID (a UUID).")
        }
      }
      if let session = linkingSession ?? model.issue(id)?.threadID,
        try await claude.sessionIsRunning(sessionID: session)
      {
        throw ScreenClipError.message("This Claude Code session is still running.")
      }
      guard !jobs.contains(id), !dispatching.contains(id) else {
        throw ScreenClipError.message("Cancel the active run before changing its session.")
      }
      try model.updateIssue(id) { issue in
        if let linkingSession { issue.threadID = linkingSession.lowercased() }
        issue.dispatchUncertain = false
        issue.turnID = nil
        issue.lastError = nil
        issue.record("Session reconciled. Continue when ready.", status: .needsYou)
      }
    } catch { model.banner = error.localizedDescription }
  }
}
