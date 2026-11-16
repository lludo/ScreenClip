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
    let allImages = try Dictionary(
      uniqueKeysWithValues: issue.captures.map {
        ($0.id, try Data(contentsOf: URL(fileURLWithPath: $0.imagePath)))
      })
    try model.updateIssue(id) {
      $0.threadID = sessionID
      $0.turnID = "claude:" + sessionID
      $0.dispatchUncertain = false
      $0.coveredRevision = issue.revision
      $0.record("Investigating capture revision \(issue.revision) with Claude Code", status: .working)
    }
    guard let current = model.issue(id) else {
      jobs.remove(id)
      return
    }
    issue = current
    texts[id] = nil
    // A resumed session already holds earlier evidence; send only what is new.
    let turn = AgentPrompt.turn(
      for: issue, project: project, threadID: resume ? sessionID : nil,
      settings: model.snapshot.settings)
    var request = ClaudeTurnRequest(
      executable: executable, cwd: path, sessionID: sessionID, resume: resume,
      name: "ScreenClip: " + issue.referencedTitle,
      model: model.snapshot.settings.claudeModel, prompt: turn.text,
      images: turn.captures.compactMap { allImages[$0.id] }, schema: AgentPrompt.resultSchema)
    request.timeout = turnTimeLimit
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
          $0.turnID = "claude:" + fresh
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
    if !finishing.contains(id) {
      finishing.insert(id)
      await finish(id)
      finishing.remove(id)
    }
  }
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
