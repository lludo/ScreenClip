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
    var images: [Data] = []
    for capture in issue.captures {
      images.append(try Data(contentsOf: URL(fileURLWithPath: capture.imagePath)))
    }
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
    var request = ClaudeTurnRequest(
      executable: executable, cwd: path, sessionID: sessionID, resume: resume,
      name: "ScreenClip: " + issue.referencedTitle,
      model: model.snapshot.settings.claudeModel, prompt: AgentPrompt.text(for: issue, project: project),
      images: images, schema: AgentPrompt.resultSchema)
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
    model.perform {
      try model.updateIssue(id) {
        $0.turnID = nil
        $0.record("Claude Code turn finished · " + result.usageSummary, kind: "usage")
      }
    }
    guard model.issue(id)?.status == .working, jobs.contains(id) else {
      jobs.remove(id)
      return
    }
    if result.isError {
      let text = result.text.isEmpty ? "Claude Code reported an error." : result.text
      throw ScreenClipError.message(
        text.localizedCaseInsensitiveContains("not logged in")
          ? "Claude Code is signed out. Open Settings → Connections and use Sign in to Claude."
          : String(text.prefix(3000)))
    }
    if var json = result.outputJSON {
      // Surface blocked tools so a "blocked" outcome says what needs approval.
      if !result.permissionDenials.isEmpty,
        var report = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
        report["outcome"].string != "implemented", case .object(var fields) = report
      {
        let blocked = "Blocked tools: " + result.permissionDenials.prefix(5).joined(separator: "; ")
        let question = fields["question"]?.string ?? ""
        fields["question"] = .string(question.isEmpty ? blocked : question + "\n" + blocked)
        report = .object(fields)
        json = String(decoding: report.data, as: UTF8.self)
      }
      texts[id] = json
    }
    if !finishing.contains(id) {
      finishing.insert(id)
      await finish(id)
      finishing.remove(id)
    }
  }
  func recordProgress(_ id: UUID, text: String) {
    guard model.issue(id)?.status == .working else { return }
    model.perform { try model.updateIssue(id) { $0.record(String(text.prefix(3000))) } }
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
