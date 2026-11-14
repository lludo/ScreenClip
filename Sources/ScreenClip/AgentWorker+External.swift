import AppKit
import Foundation
import ScreenClipCore

/// Grok Bot transport: commits approved evidence to a `screenclip/` branch, posts the report
/// to the saved webhook, discovers the PR Grok Bot opens, and inspects it before merge.
/// Grok Bot has no local session, so there is nothing to reconcile or interrupt.
extension AgentWorker {
  enum ExternalInspection {
    case ready(Bool)
    case blocked
  }
  func runExternal(_ id: UUID, project: Project) async {
    let token = UUID()
    externalRuns[id] = token
    defer {
      // Only the owning run releases the job; a canceled run must not drop a retry's entry.
      if externalRuns[id] == token {
        externalRuns.removeValue(forKey: id)
        jobs.remove(id)
      }
    }
    do {
      try await deliverExternal(id, project: project, token: token)
    } catch is CancellationError {
      return
    } catch {
      guard model.issue(id)?.status != .canceled else { return }
      model.perform {
        try model.updateIssue(id) {
          $0.dispatchUncertain = false
          $0.lastError = error.localizedDescription
          $0.unread = true
          $0.record(error.localizedDescription, status: .failed, kind: "error")
        }
      }
    }
  }
  private func ensureExternalActive(_ id: UUID, _ token: UUID) throws {
    guard let issue = model.issue(id), issue.status != .canceled, jobs.contains(id),
      externalRuns[id] == token
    else {
      throw CancellationError()
    }
  }
  private func deliverExternal(_ id: UUID, project: Project, token: UUID) async throws {
    try ensureExternalActive(id, token)
    guard var issue = model.issue(id) else { return }
    guard let number = issue.reportNumber, number > 0 else {
      throw ScreenClipError.message("This report does not have a number yet.")
    }
    let configuration = model.loadExternalAssistant()
    guard configuration.isConfigured, let endpoint = configuration.endpoint else {
      throw ScreenClipError.message(
        AgentPicker.externalAvailability(configured: false, hasProject: true, projectOptIn: true).hint
          ?? "Grok Bot is not connected.")
    }
    if !project.sendsExternalScreenshots {
      let remote = try await CommandRunner.checked(
        "/usr/bin/git", ["remote", "get-url", "origin"], cwd: project.path)
      let parsed = GitHubRepository.parse(remote: remote)
      let isPublic =
        parsed == nil
        ? nil
        : await GitHubService.repositoryIsPublic(
          parsed!.slug, gh: model.snapshot.settings.ghPath, cwd: project.path)
      throw ScreenClipError.message(
        ExternalScreenshotGate.refusal(optIn: false, repositoryIsPublic: isPublic)
          ?? "Turn on Allow sending screenshots to the external assistant in this project's settings before sending captures to Grok Bot."
      )
    }
    let repo = try await githubRepo(project)
    let branch =
      issue.branch
      ?? ExternalAssistant.branchName(
        reportNumber: number, title: issue.title, workspaceID: issue.workspaceID)
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["check-ref-format", "--branch", branch], cwd: project.path)
    let workspaceID = issue.workspaceID
    let workspace = try await serializedWorkspaceChange(project.id) { [model] in
      try await GitWorkspace.prepare(
        project: project, issueID: workspaceID, root: model.store.root, branch: branch)
    }
    try ensureExternalActive(id, token)
    issue = model.issue(id) ?? issue
    let preparedRevision = issue.revision
    try model.updateIssue(id) {
      $0.worktreePath = workspace.path
      $0.branch = workspace.branch
      if $0.status == .queued {
        $0.record("Preparing evidence for Grok Bot", status: .working)
      }
    }
    let state = ExternalHandoffState(
      revision: preparedRevision, handoffRevision: issue.handoffRevision,
      handoffCommit: issue.handoffCommit, uncertain: issue.dispatchUncertain)
    let commit: String
    switch ExternalHandoff.action(state) {
    case .commitEvidence:
      // A failed attempt can leave `.screenclip/` uncommitted. Commit that before fast-forwarding,
      // or the retry stops on a dirty worktree and never reaches the push.
      if FileManager.default.fileExists(atPath: workspace.path + "/.screenclip") {
        _ = try await GitHubService.commitEvidence(
          directory: ".screenclip",
          message: "ScreenClip: #\(number) evidence revision \(preparedRevision)",
          cwd: workspace.path)
      }
      try await GitHubService.integrateRemoteBranch(workspace.branch, cwd: workspace.path)
      try ensureExternalActive(id, token)
      issue = model.issue(id) ?? issue
      guard issue.revision == preparedRevision else {
        try model.updateIssue(id) {
          $0.record("New evidence arrived; continuing with the latest revision", status: .queued)
        }
        return
      }
      let filePayload = ExternalAssistant.makePayload(
        issue: issue, project: project, repo: repo, branch: workspace.branch,
        includePageContext: model.snapshot.settings.browserContext, commit: nil)
      var images: [Data] = []
      for capture in issue.captures {
        // Approved derivative only. originalPath is the unredacted crop and is never uploaded.
        images.append(try Data(contentsOf: URL(fileURLWithPath: capture.imagePath)))
      }
      let paths = try ExternalEvidenceWriter.write(
        worktree: workspace.path, reportNumber: number,
        report: try ExternalAssistant.json(filePayload, pretty: true), images: images)
      guard
        paths
          == ExternalAssistant.evidencePaths(
            reportNumber: number, captureCount: issue.captures.count)
      else { throw ScreenClipError.message("Could not write the approved screenshots for Grok Bot.") }
      commit = try await GitHubService.commitEvidence(
        directory: ExternalAssistant.evidenceDirectory(reportNumber: number),
        message: "ScreenClip: #\(number) evidence revision \(preparedRevision)",
        cwd: workspace.path)
      try model.updateIssue(id) {
        $0.handoffCommit = commit
        $0.handoffRevision = preparedRevision
        $0.branch = workspace.branch
        $0.worktreePath = workspace.path
      }
    case .postExisting(let existing):
      commit = existing
    }
    try ensureExternalActive(id, token)
    guard model.issue(id)?.revision == preparedRevision else {
      try model.updateIssue(id) {
        $0.dispatchUncertain = false
        $0.record("New evidence arrived; continuing with the latest revision", status: .queued)
      }
      return
    }
    try await GitHubService.integrateRemoteBranch(workspace.branch, cwd: workspace.path)
    let alreadyPushed = try await GitHubService.remoteContains(
      commit: commit, branch: workspace.branch, cwd: workspace.path)
    if !alreadyPushed {
      _ = try await CommandRunner.checked(
        model.snapshot.settings.ghPath, ["auth", "status"], cwd: workspace.path)
      try await GitHubService.pushBranch(workspace.branch, cwd: workspace.path)
    }
    try ensureExternalActive(id, token)
    guard let current = model.issue(id), current.revision == preparedRevision else {
      try model.updateIssue(id) {
        $0.dispatchUncertain = false
        $0.record("New evidence arrived; continuing with the latest revision", status: .queued)
      }
      return
    }
    let begun = ExternalHandoff.beginSend(
      ExternalHandoffState(
        revision: preparedRevision, handoffRevision: current.handoffRevision,
        handoffCommit: commit, uncertain: false),
      revision: preparedRevision, commit: commit)
    try model.updateIssue(id) {
      $0.handoffRevision = begun.handoffRevision
      $0.handoffCommit = begun.handoffCommit
      $0.coveredRevision = preparedRevision
      $0.dispatchUncertain = true
      $0.record("Sending report revision \(preparedRevision) to Grok Bot", status: .working)
    }
    let wire = ExternalAssistant.makePayload(
      issue: model.issue(id) ?? current, project: project, repo: repo, branch: workspace.branch,
      includePageContext: model.snapshot.settings.browserContext, commit: commit)
    let response = try await ExternalAssistantClient.post(
      url: endpoint, authorization: configuration.normalizedAuthorization,
      body: try ExternalAssistant.json(wire))
    guard model.issue(id)?.status != .canceled else { return }
    guard response.succeeded else {
      let snippet = response.body.trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = snippet.isEmpty ? "" : " " + snippet
      throw ScreenClipError.message(
        "Grok Bot rejected the report (HTTP \(response.status)).\(detail)")
    }
    let latestRevision = model.issue(id)?.revision
    try model.updateIssue(id) { updated in
      updated.dispatchUncertain = false
      updated.handoffCommit = commit
      updated.handoffRevision = preparedRevision
      updated.lastError = nil
      if latestRevision != preparedRevision {
        updated.record(ExternalAssistant.sentActivity, status: .queued)
      } else if updated.prURL != nil {
        updated.record(ExternalAssistant.sentActivity, status: .prOpen)
      } else {
        updated.record(ExternalAssistant.sentActivity, status: .working)
      }
    }
  }
  private func githubRepo(_ project: Project) async throws -> String {
    let remote = try await CommandRunner.checked(
      "/usr/bin/git", ["remote", "get-url", "origin"], cwd: project.path)
    guard let repo = GitHubRepository.parse(remote: remote) else {
      throw ScreenClipError.message(
        "This project's origin is not a GitHub repository. Grok Bot needs a GitHub repository to receive the screenshots."
      )
    }
    return repo.slug
  }
  private func receiptURL(_ issue: Issue) -> URL {
    model.store.root.appendingPathComponent("runs/\(issue.workspaceID).json")
  }
  private func loadReceipt(_ id: UUID, issue: Issue) -> ValidationReceipt? {
    if let receipt = receipts[id] { return receipt }
    return try? JSONDecoder().decode(
      ValidationReceipt.self, from: Data(contentsOf: receiptURL(issue)))
  }
  private func noteScreenclipEvidence(_ id: UUID) throws {
    let summary = ExternalAssistant.evidenceStillPresentSummary
    try model.updateIssue(id) { issue in
      if issue.checkSummary != summary {
        issue.record(summary)
        issue.unread = true
      }
      issue.checkSummary = summary
    }
  }
  func inspectExternal(
    _ id: UUID, issue: Issue, project: Project, path: String, pullHead: String
  ) async throws -> ExternalInspection {
    guard let branch = issue.branch else {
      throw ScreenClipError.message("The Grok Bot report has no evidence branch.")
    }
    _ = try await CommandRunner.checked("/usr/bin/git", ["fetch", "origin", branch], cwd: path)
    let remotePaths = try await GitHubService.listScreenclipPaths(revision: "FETCH_HEAD", cwd: path)
    if ExternalAssistant.containsScreenclipEvidence(remotePaths) {
      try noteScreenclipEvidence(id)
      return .blocked
    }
    try await GitHubService.fastForwardToFetchHead(cwd: path)
    let head = try await CommandRunner.checked("/usr/bin/git", ["rev-parse", "HEAD"], cwd: path)
    guard head == pullHead else {
      let summary = "The pull request head does not match the \(branch) branch ScreenClip is watching."
      try model.updateIssue(id) {
        if $0.checkSummary != summary { $0.record(summary) }
        $0.checkSummary = summary
        $0.unread = true
      }
      return .blocked
    }
    let localPaths = try await GitHubService.listScreenclipPaths(revision: "HEAD", cwd: path)
    guard !ExternalAssistant.containsScreenclipEvidence(localPaths) else {
      try noteScreenclipEvidence(id)
      return .blocked
    }
    if let receipt = loadReceipt(id, issue: issue), receipt.head == head {
      if receipt.passed {
        if model.issue(id)?.prHead != head {
          try model.updateIssue(id) { $0.prHead = head }
        }
        return .ready(true)
      }
      let summary = "Project validation failed for this pull request head."
      try model.updateIssue(id) {
        if $0.checkSummary != summary { $0.record(summary) }
        $0.checkSummary = summary
        $0.unread = true
      }
      return .blocked
    }
    let validated = try await GitWorkspace.validate(project: project, path: path)
    receipts[id] = validated
    try JSONEncoder().encode(validated).write(to: receiptURL(issue), options: .atomic)
    try model.updateIssue(id) { $0.prHead = validated.head }
    guard validated.passed else {
      let summary = "Project validation failed for this pull request head."
      try model.updateIssue(id) {
        $0.checkSummary = summary
        $0.record(summary)
        $0.unread = true
      }
      return .blocked
    }
    return .ready(true)
  }
  func publishExternalBaseUpdate(
    _ id: UUID, project: Project, path: String, branch: String, previousHead: String
  ) async throws {
    guard !branch.isEmpty, let issue = model.issue(id) else {
      throw ScreenClipError.message("The Grok Bot report has no evidence branch.")
    }
    let paths = try await GitHubService.listScreenclipPaths(revision: "HEAD", cwd: path)
    if ExternalAssistant.containsScreenclipEvidence(paths) {
      _ = try? await CommandRunner.checked(
        "/usr/bin/git", ["reset", "--hard", previousHead], cwd: path)
      try noteScreenclipEvidence(id)
      return
    }
    let validated: ValidationReceipt
    do {
      validated = try await GitWorkspace.validate(project: project, path: path)
    } catch {
      _ = try? await CommandRunner.checked(
        "/usr/bin/git", ["reset", "--hard", previousHead], cwd: path)
      throw error
    }
    guard validated.passed else {
      _ = try? await CommandRunner.checked(
        "/usr/bin/git", ["reset", "--hard", previousHead], cwd: path)
      throw ScreenClipError.message(
        "Project validation failed after updating the base branch.\n" + validated.output)
    }
    let remaining = try await GitHubService.listScreenclipPaths(revision: "HEAD", cwd: path)
    if ExternalAssistant.containsScreenclipEvidence(remaining) {
      _ = try? await CommandRunner.checked(
        "/usr/bin/git", ["reset", "--hard", previousHead], cwd: path)
      try noteScreenclipEvidence(id)
      return
    }
    receipts[id] = validated
    try JSONEncoder().encode(validated).write(to: receiptURL(issue), options: .atomic)
    do {
      _ = try await CommandRunner.checked(
        "/usr/bin/git", ["push", "origin", "HEAD:\(branch)"], cwd: path)
    } catch {
      // Without the rollback the local merge diverges from the PR and blocks every later refresh.
      _ = try? await CommandRunner.checked(
        "/usr/bin/git", ["reset", "--hard", previousHead], cwd: path)
      throw error
    }
    try model.updateIssue(id) {
      $0.prHead = validated.head
      $0.lastError = nil
      $0.checkSummary = "Waiting for checks on the pull request after updating it onto the base branch."
      $0.record(
        "Updated the pull request onto the current base branch. Waiting for checks.", status: .prOpen)
    }
  }
  /// A report waiting for Grok Bot's pull request: still working, or flagged after no PR arrived.
  static func awaitsExternalPullRequest(_ issue: Issue) -> Bool {
    issue.status == .working
      || (issue.status == .needsYou && issue.lastError == ExternalAssistant.noPullRequestActivity)
  }
  func discoverExternalPullRequests(now: Date = Date()) async {
    let pending = model.snapshot.issues.filter {
      $0.resolvedAgent == .external && Self.awaitsExternalPullRequest($0) && $0.prURL == nil
        && !$0.dispatchUncertain && !$0.archived && $0.branch != nil && $0.worktreePath != nil
        && !isActive($0.id)
    }
    for issue in pending {
      guard let branch = issue.branch, let path = issue.worktreePath,
        let number = issue.reportNumber
      else { continue }
      do {
        let candidates = try await GitHubService.pullRequests(
          head: branch, gh: model.snapshot.settings.ghPath, cwd: path)
        if let match = ExternalPullRequestFinder.match(
          reportNumber: number, branch: branch, candidates: candidates)
        {
          guard let current = model.issue(issue.id), Self.awaitsExternalPullRequest(current),
            current.prURL == nil, !isActive(issue.id)
          else { continue }
          try model.updateIssue(issue.id) {
            $0.prURL = match.url
            $0.lastError = nil
            $0.record("Pull request opened: " + match.url, status: .prOpen)
          }
        } else if ExternalPullRequestFinder.closedMatch(
          reportNumber: number, branch: branch, candidates: candidates) != nil
        {
          let text =
            "The pull request for \(branch) is closed. Grok Bot can open another from the same branch."
          if model.issue(issue.id)?.lastError != text {
            try model.updateIssue(issue.id) { $0.lastError = text }
          }
        } else if issue.status == .working, let sent = ExternalAssistant.sentDate(issue),
          now.timeIntervalSince(sent) >= ExternalAssistant.noPullRequestReminder
        {
          // Without this, a report Grok Bot never picked up shows "working" indefinitely.
          try model.updateIssue(issue.id) {
            $0.lastError = ExternalAssistant.noPullRequestActivity
            $0.unread = true
            $0.record(ExternalAssistant.noPullRequestActivity, status: .needsYou)
          }
          model.notify(issue, text: ExternalAssistant.noPullRequestActivity)
        }
      } catch {
        if model.issue(issue.id)?.lastError != error.localizedDescription {
          model.perform {
            try model.updateIssue(issue.id) { $0.lastError = error.localizedDescription }
          }
        }
      }
    }
  }
}
