import AppKit
import Foundation
import ScreenClipCore

/// Agent-neutral result handling: validation, PR publication, repair attempts, PR
/// monitoring, guarded merges, and workspace cleanup.
extension AgentWorker {
  func finish(_ id: UUID) async {
    guard let issue = model.issue(id), let project = model.project(issue.projectID),
      issue.status != .canceled
    else {
      jobs.remove(id)
      model.perform { try model.updateIssue(id) { $0.turnID = nil } }
      return
    }
    model.perform {
      try model.updateIssue(id) {
        $0.turnID = nil
        $0.dispatchUncertain = false
      }
    }
    if issue.revision != issue.coveredRevision {
      model.perform {
        try model.updateIssue(id) {
          $0.record("New evidence arrived; continuing with the latest revision", status: .queued)
        }
      }
      jobs.remove(id)
      pump()
      return
    }
    guard let text = texts[id],
      let result = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    else {
      jobs.remove(id)
      model.perform {
        try model.updateIssue(id) {
          $0.record(
            issue.resolvedAgent.title + " finished without a structured result. Open the chat to review.",
            status: .needsYou)
        }
      }
      return
    }
    let summary = result["summary"].string ?? ""
    if result["outcome"].string != "implemented" {
      let question = result["question"].string.flatMap { $0.isEmpty ? nil : $0 } ?? summary
      model.perform {
        try model.updateIssue(id) {
          $0.questions.append(PendingQuestion(title: question))
          $0.unread = true
          $0.record(question, status: .needsYou, kind: "question")
        }
      }
      model.notify(issue, text: question)
      jobs.remove(id)
      return
    }
    await publish(id, project: project, summary: summary)
    if model.issue(id)?.status == .prOpen { await refreshPR(id) }
    jobs.remove(id)
    pump()
  }
  func publish(_ id: UUID, project: Project, summary: String) async {
    guard !publishing.contains(id), let issue = model.issue(id), issue.status != .canceled,
      let path = issue.worktreePath
    else { return }
    publishing.insert(id)
    defer { publishing.remove(id) }
    do {
      try model.updateIssue(id) {
        $0.resultSummary = summary
        $0.record("Running project validation", status: .working)
      }
      do {
        try await PRScreenshotEvidence.prepare(issue: issue, worktree: path)
      } catch {
        if scheduleRepair(id, message: error.localizedDescription) { return }
        throw error
      }
      let receipt = try await GitWorkspace.validate(project: project, path: path)
      // Canceled, or canceled and queued again, during validation: leave that decision alone.
      // A queued report starts once this run has ended.
      guard model.issue(id)?.status == .working else { return }
      guard receipt.passed else {
        let feedback = "Project validation failed:\n" + receipt.output
        if scheduleRepair(id, message: feedback) { return }
        // Continue after a manual look still hands the agent the failing output.
        try model.updateIssue(id) { $0.validationFeedback = feedback }
        throw ScreenClipError.message(
          "Validation failed after two repair attempts.\n" + receipt.output)
      }
      guard model.issue(id)?.revision == issue.coveredRevision, model.issue(id)?.status != .canceled
      else {
        throw ScreenClipError.message(
          "New evidence or cancellation arrived during validation; publication stopped.")
      }
      let published = try await GitHubService.publish(
        project: project, issue: issue, summary: summary, receipt: receipt,
        gh: AgentDetector.ghPath(model.snapshot.settings),
        shouldContinue: { [weak self] in
          self?.model.issue(id)?.revision == issue.coveredRevision
            && self?.model.issue(id)?.status == .working
        })
      var savedReceipt = receipt
      savedReceipt.head = published.head
      receipts[id] = savedReceipt
      try JSONEncoder().encode(savedReceipt).write(
        to: model.store.root.appendingPathComponent("runs/\(issue.workspaceID).json"),
        options: .atomic)
      try model.updateIssue(id) { current in
        current.prURL = published.url
        current.prHead = published.head
        current.lastError = nil
        current.validationFeedback = nil
        current.record(
          "PR opened: " + published.url,
          status: current.status == .canceled
            ? .canceled : (current.revision == issue.coveredRevision ? .prOpen : .queued))
      }
    } catch {
      if let current = model.issue(id), current.status != .canceled,
        current.revision != issue.coveredRevision
      {
        // Superseded, not failed: the next dispatch covers the newer evidence.
        model.perform {
          try model.updateIssue(id) {
            $0.record(
              "New evidence arrived during publication; continuing with the latest revision",
              status: .queued)
          }
        }
        return
      }
      model.perform {
        try model.updateIssue(id) {
          $0.lastError = error.localizedDescription
          $0.unread = true
          $0.record(
            error.localizedDescription, status: $0.status == .canceled ? .canceled : .needsYou,
            kind: "error")
        }
      }
    }
  }
  func refreshPRs() async { await refreshPullRequests(discoverInterval: 0) }
  /// Grok Bot opens its own PRs, so discovery for those issues runs at most once per interval.
  func refreshPullRequests(discoverInterval: TimeInterval) async {
    if Date().timeIntervalSince(lastExternalDiscovery) >= discoverInterval {
      lastExternalDiscovery = Date()
      await discoverExternalPullRequests()
    }
    for issue in model.snapshot.issues where issue.status == .prOpen { await refreshPR(issue.id) }
  }
  func refreshPR(_ id: UUID) async {
    guard let issue = model.issue(id), let url = issue.prURL, let path = issue.worktreePath,
      let project = model.project(issue.projectID)
    else { return }
    guard !refreshing.contains(id), !mergingProjects.contains(project.id) else { return }
    refreshing.insert(id)
    defer { refreshing.remove(id) }
    do {
      let pr = try await GitHubService.state(
        url: url, path: path, gh: AgentDetector.ghPath(model.snapshot.settings))
      if pr.merged {
        try recordMerge(id, commit: pr.mergeCommit, coveredRevision: issue.coveredRevision)
        model.notify(issue, text: "Fix merged. Ready to rebuild and retest.")
        return
      }
      var screenclipEvidenceCleared = true
      if issue.resolvedAgent == .external {
        switch try await inspectExternal(id, issue: issue, project: project, path: path, pullHead: pr.head)
        {
        case .blocked: return
        case .ready(let cleared): screenclipEvidenceCleared = cleared
        }
      }
      if pr.checksFailed, model.issue(id)?.status == .prOpen {
        if model.issue(id)?.resolvedAgent == .external {
          if model.issue(id)?.checkSummary != pr.details {
            try model.updateIssue(id) {
              $0.checkSummary = pr.details
              $0.unread = true
              $0.record("GitHub checks failed. Grok Bot can push another commit to " + url + ".")
            }
          }
          return
        }
        if scheduleRepair(
          id,
          message:
            "GitHub checks failed for \(url). Inspect the failing checks, repair the fix, and rerun the project validation."
        ) {
          pump()
        } else {
          try model.updateIssue(id) {
            $0.record(
              "CI still fails after two repair attempts. Review the PR checks in " + issue.resolvedAgent.title + ".",
              status: .needsYou)
            $0.unread = true
          }
        }
        return
      }
      let receipt =
        receipts[id]
        ?? (try? JSONDecoder().decode(
          ValidationReceipt.self,
          from: Data(
            contentsOf: model.store.root.appendingPathComponent("runs/\(issue.workspaceID).json"))))
      let currentIssue = model.issue(id) ?? issue
      let evidence = MergeEvidence(
        expectedHead: currentIssue.prHead ?? "", currentHead: pr.head,
        inputRevision: currentIssue.revision, coveredRevision: currentIssue.coveredRevision,
        validationPassed: receipt?.passed == true && receipt?.head == pr.head,
        hasValidation: receipt?.command == project.validationCommand
          && !project.validationCommand.isEmpty, checksPassed: pr.checksPassed,
        mergeable: pr.mergeable && pr.base == project.baseBranch,
        reviewSatisfied: pr.reviewSatisfied,
        unresolvedQuestions: currentIssue.questions.contains { $0.reply == nil },
        screenclipEvidenceCleared: screenclipEvidenceCleared, draft: pr.draft)
      let checkSummary: String
      if pr.draft {
        checkSummary = ExternalAssistant.draftPullRequestSummary
      } else if currentIssue.prHead != pr.head {
        checkSummary = "The PR changed; run validation again before merging."
      } else if !pr.checksPassed {
        checkSummary = pr.details
      } else if !pr.reviewSatisfied {
        checkSummary = "Waiting for required review."
      } else if !pr.mergeable {
        checkSummary = "Waiting for the PR to become mergeable."
      } else if !screenclipEvidenceCleared {
        checkSummary = ExternalAssistant.evidenceStillPresentSummary
      } else if !project.autoMerge {
        checkSummary = "Checks passed. Automatic merge is disabled for this project."
      } else if model.snapshot.settings.paused {
        checkSummary = "Checks passed. Processing is paused."
      } else {
        checkSummary = "Checks passed; preparing merge."
      }
      if model.issue(id)?.checkSummary != checkSummary {
        try model.updateIssue(id) { $0.checkSummary = checkSummary }
      }
      guard project.autoMerge && evidence.canMerge && !model.snapshot.settings.paused else {
        return
      }
      // Re-check after the awaits above: parallel reports in one project must merge one at a
      // time, so each later merge revalidates against the base that already includes the earlier.
      guard !mergingProjects.contains(project.id) else { return }
      mergingProjects.insert(project.id)
      defer { mergingProjects.remove(project.id) }
      let baseAdvanced: Bool
      do {
        baseAdvanced = try await GitWorkspace.updateBaseIfNeeded(project: project, path: path)
      } catch {
        if issue.resolvedAgent == .external {
          try model.updateIssue(id) {
            $0.lastError = error.localizedDescription
            $0.record(
              "Could not update the pull request against its base branch. "
                + error.localizedDescription,
              status: .needsYou)
          }
          return
        }
        if scheduleRepair(
          id,
          message:
            "Could not update the PR against its current base branch. Resolve the worktree's merge state and rerun validation. Details: "
            + error.localizedDescription)
        {
          pump()
        } else {
          try model.updateIssue(id) {
            $0.lastError = error.localizedDescription
            $0.record("The base update needs attention in " + issue.resolvedAgent.title + ".", status: .needsYou)
          }
        }
        return
      }
      if baseAdvanced {
        if issue.resolvedAgent == .external {
          try await publishExternalBaseUpdate(
            id, project: project, path: path, branch: issue.branch ?? "", previousHead: pr.head)
          return
        }
        // publish() returns at once while another publish runs; marking the report working
        // first would leave it working with nothing to finish it.
        guard model.issue(id)?.revision == issue.coveredRevision, model.issue(id)?.status == .prOpen,
          !publishing.contains(id)
        else { return }
        try model.updateIssue(id) {
          $0.record("Base branch advanced; revalidating the updated fix", status: .working)
        }
        await publish(
          id, project: project,
          summary: issue.resultSummary ?? "Update fix against the current base branch")
        return
      }
      // Recheck local revision immediately before submitting a guarded merge.
      guard model.issue(id)?.revision == issue.coveredRevision && model.issue(id)?.status == .prOpen
      else { return }
      try await GitHubService.merge(
        url: url, head: pr.head, path: path, gh: AgentDetector.ghPath(model.snapshot.settings))
      let confirmed = try await GitHubService.state(
        url: url, path: path, gh: AgentDetector.ghPath(model.snapshot.settings))
      if confirmed.merged {
        try recordMerge(id, commit: confirmed.mergeCommit, coveredRevision: issue.coveredRevision)
        model.notify(issue, text: "Fix merged. Ready to rebuild and retest.")
      }
    } catch {
      model.perform { try model.updateIssue(id) { $0.lastError = error.localizedDescription } }
    }
  }
  func recordMerge(_ id: UUID, commit: String?, coveredRevision: Int) throws {
    let finished = model.issue(id)
    defer {
      // The merged fix no longer needs its checkout; free the disk and the local branch.
      if let finished, let path = finished.worktreePath,
        let project = model.project(finished.projectID)
      {
        Task { await removeWorkspace(id, path: path, branch: finished.branch, project: project) }
      }
    }
    try model.updateIssue(id) { issue in
      issue.mergeCommit = commit
      issue.validationFeedback = nil
      // Polling stops once the report is merged, so an error from an earlier refresh (a gh
      // or GitHub failure) would otherwise stay on the merged report for good.
      issue.lastError = nil
      issue.unread = true
      if issue.revision == coveredRevision {
        issue.record("Merged. Rebuild or deploy the app, then retest.", status: .merged)
      } else {
        issue.record(
          "Previous revision merged; continuing with newly submitted evidence. PR: \(issue.prURL ?? "")",
          status: .queued)
        issue.workspaceID = UUID()
        issue.worktreePath = nil
        issue.branch = nil
        issue.prURL = nil
        issue.prHead = nil
        issue.handoffCommit = nil
        issue.handoffRevision = nil
        issue.handoffAttempts = nil
      }
    }
  }
  func removeWorkspace(_ id: UUID, path: String, branch: String?, project: Project) async {
    // The merge is confirmed with GitHub before this runs, so the PR branch is no longer needed.
    if let branch { await GitWorkspace.deleteRemoteBranch(branch, repository: project.path) }
    let removed =
      (try? await serializedWorkspaceChange(project.id) {
        await GitWorkspace.remove(path: path, branch: branch, repository: project.path)
      }) ?? false
    guard removed else { return }
    model.perform {
      try model.updateIssue(id) { issue in
        if issue.worktreePath == path { issue.worktreePath = nil }
      }
    }
  }
  func scheduleRepair(_ id: UUID, message: String) -> Bool {
    guard model.issue(id)?.resolvedAgent != .external else { return false }
    guard let issue = model.issue(id), issue.status != .canceled,
      issue.revision == issue.coveredRevision, (issue.repairAttempts ?? 0) < 2
    else { return false }
    do {
      try model.updateIssue(id) {
        $0.repairAttempts = ($0.repairAttempts ?? 0) + 1
        $0.lastError = message
        $0.validationFeedback = message
        $0.record(
          "Checks failed; starting repair attempt \($0.repairAttempts ?? 1) of 2", status: .queued)
      }
      return true
    } catch {
      model.banner = error.localizedDescription
      return false
    }
  }
}
