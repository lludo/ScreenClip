import AppKit
import Foundation
import ScreenClipCore

/// Grok Bot transport: commits approved evidence to a `screenclip/` branch, posts the report
/// to the saved webhook, discovers the PR Grok Bot opens, and inspects it before merge.
/// Grok Bot has no local session, so there is nothing to reconcile or interrupt.
extension AgentWorker {
  enum ExternalInspection {
    case ready
    /// Not validated on this Mac (automatic merge is off). PR status is still shown.
    case unvalidated
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
        AgentPicker.externalAvailability(configured: false, hasProject: true).hint
          ?? "Grok Bot is not connected.")
    }
    let repo = try await githubRepo(project)
    let branch =
      issue.branch
      ?? ExternalAssistant.branchName(
        reportNumber: number, title: issue.title, workspaceID: issue.workspaceID)
    _ = try await CommandRunner.checked(
      GitWorkspace.git, ["check-ref-format", "--branch", branch], cwd: project.path)
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
        includePageContext: model.snapshot.settings.browserContext, commit: nil,
        settings: model.snapshot.settings)
      var images: [Data] = []
      for path in issue.captures.compactMap(\.imagePath) {
        // Approved derivative only. originalPath is the unredacted crop and is never uploaded.
        images.append(try Data(contentsOf: URL(fileURLWithPath: path)))
      }
      let paths = try ExternalEvidenceWriter.write(
        worktree: workspace.path, reportNumber: number,
        report: try ExternalAssistant.json(filePayload, pretty: true), images: images)
      guard
        paths
          == ExternalAssistant.evidencePaths(
            reportNumber: number, captureCount: images.count)
      else { throw ScreenClipError.message("Could not write the approved screenshots for Grok Bot.") }
      commit = try await GitHubService.commitEvidence(
        directory: ExternalAssistant.evidenceDirectory(reportNumber: number),
        message: "ScreenClip: #\(number) evidence revision \(preparedRevision)",
        cwd: workspace.path)
      try model.updateIssue(id) {
        $0.handoffCommit = commit
        $0.handoffRevision = preparedRevision
        $0.handoffAttempts = nil
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
        AgentDetector.ghPath(model.snapshot.settings), ["auth", "status"], cwd: workspace.path)
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
    let begun = ExternalHandoff.beginSend(revision: preparedRevision, commit: commit)
    let attempt = ExternalDeliveryAttempt.next(
      stored: current.handoffAttempts, handoffRevision: current.handoffRevision,
      revision: preparedRevision)
    try model.updateIssue(id) {
      $0.handoffRevision = begun.handoffRevision
      $0.handoffCommit = begun.handoffCommit
      $0.handoffAttempts = attempt
      $0.coveredRevision = preparedRevision
      $0.dispatchUncertain = true
      $0.record("Sending report revision \(preparedRevision) to Grok Bot", status: .working)
    }
    let sending = model.issue(id) ?? current
    let wire = ExternalAssistant.makePayload(
      issue: sending, project: project, repo: repo, branch: workspace.branch,
      includePageContext: model.snapshot.settings.browserContext, commit: commit, attempt: attempt,
      previousPullRequests: ExternalAssistant.previousPullRequests(in: sending.activities),
      settings: model.snapshot.settings)
    let response = try await ExternalAssistantClient.post(
      url: endpoint, authorization: configuration.normalizedAuthorization,
      body: try ExternalAssistant.json(wire), idempotencyKey: wire.delivery?.key)
    guard model.issue(id)?.status != .canceled else { return }
    guard response.succeeded else {
      // The body can repeat the Authorization secret. The status code is enough.
      throw ScreenClipError.message(ExternalAssistant.rejectionMessage(status: response.status))
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
      GitWorkspace.git, ["remote", "get-url", "origin"], cwd: project.path)
    guard let repo = GitHubRepository.parse(remote: remote) else {
      throw ScreenClipError.message(
        "This project's origin is not a GitHub repository. Grok Bot needs a GitHub repository to receive the screenshots."
      )
    }
    return repo.slug
  }
  private static let validationFailedSummary = "Project validation failed for this pull request head."
  /// Shows `summary` as the check summary, recording it in the activity only when it changes.
  private func noteCheckSummary(_ id: UUID, _ summary: String) throws {
    try model.updateIssue(id) { issue in
      if issue.checkSummary != summary {
        issue.record(summary)
        issue.unread = true
      }
      issue.checkSummary = summary
    }
  }
  private func noteScreenclipEvidence(_ id: UUID) throws {
    try noteCheckSummary(id, ExternalAssistant.evidenceStillPresentSummary)
  }
  func inspectExternal(
    _ id: UUID, issue: Issue, project: Project, path: String, pullHead: String
  ) async throws -> ExternalInspection {
    guard let branch = issue.branch else {
      throw ScreenClipError.message("The Grok Bot report has no evidence branch.")
    }
    _ = try await CommandRunner.checked(GitWorkspace.git, ["fetch", "origin", branch], cwd: path)
    let remotePaths = try await GitHubService.listScreenclipPaths(revision: "FETCH_HEAD", cwd: path)
    if ExternalAssistant.containsScreenclipEvidence(remotePaths) {
      try noteScreenclipEvidence(id)
      return .blocked
    }
    try await GitHubService.fastForwardToFetchHead(cwd: path)
    let head = try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: path)
    guard head == pullHead else {
      try noteCheckSummary(
        id, "The pull request head does not match the \(branch) branch ScreenClip is watching.")
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
        return .ready
      }
      try noteCheckSummary(id, Self.validationFailedSummary)
      return .blocked
    }
    // The validation command runs the pull request's code on this Mac. Without automatic
    // merge ScreenClip has nothing to decide, so it does not run it.
    guard project.autoMerge else {
      // Follow the head so the summary below describes this pull request, not a changed one.
      if model.issue(id)?.prHead != head { try model.updateIssue(id) { $0.prHead = head } }
      return .unvalidated
    }
    let validated: ValidationReceipt
    do {
      validated = try await GitWorkspace.validate(project: project, path: path)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A timeout or a changed tree must not rerun an hour-long validation on every refresh.
      // Record it as a failed check of this head; a new head is validated again.
      validated = ValidationReceipt(
        head: head, command: project.validationCommand, passed: false, date: Date(),
        output: error.localizedDescription, fingerprint: "")
      try model.updateIssue(id) { $0.lastError = error.localizedDescription }
    }
    try saveReceipt(validated, for: id, issue: issue)
    try model.updateIssue(id) { $0.prHead = validated.head }
    guard validated.passed else {
      try model.updateIssue(id) {
        $0.checkSummary = Self.validationFailedSummary
        $0.record(Self.validationFailedSummary)
        $0.unread = true
      }
      return .blocked
    }
    return .ready
  }
  /// Puts the worktree back on `head`. A failed reset leaves an unvalidated merge that blocks
  /// every later refresh, so it is reported (with the error that caused the rollback) instead of ignored.
  private func rollBackBase(_ path: String, to head: String, after cause: Error?) async throws {
    do {
      _ = try await CommandRunner.checked(GitWorkspace.git, ["reset", "--hard", head], cwd: path)
    } catch {
      let original = cause.map { "\n\nOriginal problem: \($0.localizedDescription)" } ?? ""
      throw ScreenClipError.message(
        "Could not restore the worktree to its previous state: \(error.localizedDescription)"
          + original)
    }
  }
  func publishExternalBaseUpdate(
    _ id: UUID, project: Project, path: String, branch: String, previousHead: String
  ) async throws {
    guard !branch.isEmpty, let issue = model.issue(id) else {
      throw ScreenClipError.message("The Grok Bot report has no evidence branch.")
    }
    let paths = try await GitHubService.listScreenclipPaths(revision: "HEAD", cwd: path)
    if ExternalAssistant.containsScreenclipEvidence(paths) {
      try await rollBackBase(path, to: previousHead, after: nil)
      try noteScreenclipEvidence(id)
      return
    }
    let validated: ValidationReceipt
    do {
      validated = try await GitWorkspace.validate(project: project, path: path)
    } catch {
      try await rollBackBase(path, to: previousHead, after: error)
      throw error
    }
    guard validated.passed else {
      let failure = ScreenClipError.message(
        "Project validation failed after updating the base branch.\n" + validated.output)
      try await rollBackBase(path, to: previousHead, after: failure)
      throw failure
    }
    let remaining = try await GitHubService.listScreenclipPaths(revision: "HEAD", cwd: path)
    if ExternalAssistant.containsScreenclipEvidence(remaining) {
      try await rollBackBase(path, to: previousHead, after: nil)
      try noteScreenclipEvidence(id)
      return
    }
    try saveReceipt(validated, for: id, issue: issue)
    do {
      _ = try await CommandRunner.checked(
        GitWorkspace.git, ["push", "origin", "HEAD:\(branch)"], cwd: path)
    } catch {
      // Without the rollback the local merge diverges from the PR and blocks every later refresh.
      try await rollBackBase(path, to: previousHead, after: error)
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
  /// A report waiting for Grok Bot's pull request: still working, or flagged after no PR or no status.
  static func awaitsExternalPullRequest(_ issue: Issue) -> Bool {
    let revision = issue.handoffRevision ?? issue.revision
    return issue.status == .working
      || (issue.status == .needsYou && ExternalAssistant.isReminder(issue.lastError, revision: revision))
  }
  func discoverExternalPullRequests(now: Date = Date()) async {
    await pollExternalStatuses(now: now)
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
        let repo = await repositorySlug(for: issue)
        let candidates = try await GitHubService.pullRequests(
          head: branch, gh: AgentDetector.ghPath(model.snapshot.settings), cwd: path)
        if let match = ExternalPullRequestFinder.match(
          reportNumber: number, issueID: issue.id, branch: branch, candidates: candidates, repo: repo)
        {
          guard let current = model.issue(issue.id), Self.awaitsExternalPullRequest(current),
            current.prURL == nil, !isActive(issue.id)
          else { continue }
          try model.updateIssue(issue.id) {
            $0.prURL = match.url
            $0.prRevision = $0.coveredRevision
            $0.lastError = nil
            $0.record("Pull request opened: " + match.url, status: .prOpen)
            if match.draft == true {
              $0.checkSummary = ExternalAssistant.draftPullRequestSummary
              $0.record(ExternalAssistant.draftPullRequestSummary)
            }
          }
        } else if ExternalPullRequestFinder.closedMatch(
          reportNumber: number, issueID: issue.id, branch: branch, candidates: candidates, repo: repo)
          != nil
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
  /// Best-effort. A failure still leaves the report canceled locally and does not show the reply body.
  func sendExternalCancel(_ issue: Issue) async {
    let configuration = model.loadExternalAssistant()
    guard configuration.supportsCancel, let endpoint = configuration.endpoint,
      let project = model.project(issue.projectID), let branch = issue.branch
    else { return }
    let repo: String
    do { repo = try await githubRepo(project) } catch { return }
    guard let payload = ExternalAssistant.makeCancelPayload(issue: issue, repo: repo, branch: branch)
    else { return }
    do {
      let response = try await ExternalAssistantClient.post(
        url: endpoint, authorization: configuration.normalizedAuthorization,
        body: try ExternalAssistant.jsonCancel(payload))
      guard !response.succeeded else { return }
      model.perform {
        try model.updateIssue(issue.id) {
          $0.record(ExternalAssistant.cancelFailureMessage(status: response.status))
        }
      }
    } catch {
      model.perform {
        try model.updateIssue(issue.id) {
          $0.record(ExternalAssistant.cancelUnreachableActivity)
        }
      }
    }
  }
  private func repositorySlug(for issue: Issue) async -> String {
    guard let project = model.project(issue.projectID) else { return "" }
    return (try? await githubRepo(project)) ?? ""
  }
  /// Reads `screenclip/grok-bot` on the evidence commit. No status leaves today's behavior,
  /// except an earlier warning once this connection has posted a status before.
  func pollExternalStatuses(now: Date = Date()) async {
    let watching = model.snapshot.issues.filter { issue in
      guard issue.resolvedAgent == .external, !issue.archived, !issue.dispatchUncertain,
        let commit = issue.handoffCommit, !commit.isEmpty, issue.worktreePath != nil,
        !isActive(issue.id)
      else { return false }
      if issue.status == .prOpen { return true }
      return Self.awaitsExternalPullRequest(issue) && issue.prURL == nil
    }
    for issue in watching {
      guard let commit = issue.handoffCommit, let path = issue.worktreePath else { continue }
      let repo = await repositorySlug(for: issue)
      guard GitHubService.isRepositorySlug(repo), GitHubService.isCommit(commit) else { continue }
      let status: ExternalStatus?
      do {
        status = try await GitHubService.externalStatus(
          repo: repo, commit: commit, gh: AgentDetector.ghPath(model.snapshot.settings), cwd: path)
      } catch {
        continue
      }
      guard let current = model.issue(issue.id), !isActive(issue.id) else { continue }
      if let status {
        let effect = ExternalAssistant.statusEffect(issue: current, status: status, repo: repo)
        let unchanged =
          effect.activity == nil && !effect.clearReminder && !effect.resumeWatching
          && effect.agentURL == current.externalAgentURL
          && effect.ackRevision == current.externalAckRevision
          && effect.statusText == current.externalStatusText
        if model.snapshot.settings.externalStatusSeen != true {
          model.perform { try model.commit { $0.settings.externalStatusSeen = true } }
        }
        if unchanged { continue }
        model.perform {
          try model.updateIssue(issue.id) { updated in
            if let url = effect.agentURL { updated.externalAgentURL = url }
            updated.externalAckRevision = effect.ackRevision
            updated.externalStatusText = effect.statusText
            if effect.clearReminder { updated.lastError = nil }
            if effect.resumeWatching { updated.status = .working }
            if let activity = effect.activity { updated.record(activity) }
          }
        }
      } else {
        let revision = current.handoffRevision ?? current.revision
        let warning = ExternalAssistant.pickupWarning(revision: revision)
        let acknowledged = current.externalAckRevision == revision
        let alreadyWarned =
          current.activities.contains { $0.text == warning }
          || ExternalAssistant.isReminder(current.lastError, revision: revision)
        guard
          ExternalAssistant.shouldWarnAboutMissingStatus(
            statusSeen: model.snapshot.settings.externalStatusSeen == true,
            acknowledged: acknowledged, alreadyWarned: alreadyWarned,
            awaitingPullRequest: Self.awaitsExternalPullRequest(current) && current.prURL == nil
              && current.status == .working,
            sentAt: ExternalAssistant.sentDate(current), now: now)
        else { continue }
        model.perform {
          try model.updateIssue(issue.id) {
            $0.lastError = warning
            $0.unread = true
            $0.record(warning, status: .needsYou)
          }
        }
        model.notify(current, text: warning)
      }
    }
  }
}
