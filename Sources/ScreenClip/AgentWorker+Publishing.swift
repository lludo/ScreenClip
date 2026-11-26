import AppKit
import Foundation
import ScreenClipCore

/// Agent-neutral result handling: validation, PR publication, repair attempts, PR
/// monitoring, guarded merges, and workspace cleanup.
extension AgentWorker {
  /// Validation receipts outlive a restart, keyed by the report's worktree.
  func receiptURL(_ issue: Issue) -> URL {
    model.store.root.appendingPathComponent("runs/\(issue.workspaceID).json")
  }
  func loadReceipt(_ id: UUID, issue: Issue) -> ValidationReceipt? {
    if let receipt = receipts[id] { return receipt }
    return try? JSONDecoder().decode(
      ValidationReceipt.self, from: Data(contentsOf: receiptURL(issue)))
  }
  func saveReceipt(_ receipt: ValidationReceipt, for id: UUID, issue: Issue) throws {
    receipts[id] = receipt
    try JSONEncoder().encode(receipt).write(to: receiptURL(issue), options: .atomic)
  }

  /// Finishes a completed turn unless another path already is. While a report is in
  /// `finishing`, disconnect events and duplicate completions leave it alone.
  func finishOnce(_ id: UUID) async {
    guard finishing.insert(id).inserted else { return }
    await finishMarked(id)
  }
  /// For callers that inserted `id` into `finishing` themselves.
  func finishMarked(_ id: UUID) async {
    await finish(id)
    finishing.remove(id)
    // A report queued again during validation waits for this run to end.
    pump()
  }
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
  func publish(_ id: UUID, project: Project, summary: String, baseAlreadyUpdated: Bool = false) async {
    guard !publishing.contains(id), let issue = model.issue(id), issue.status != .canceled,
      let path = issue.worktreePath
    else { return }
    publishing.insert(id)
    defer { publishing.remove(id) }
    do {
      try model.updateIssue(id) {
        $0.resultSummary = summary
        $0.status = .working
      }
      do {
        try await PRScreenshotEvidence.prepare(issue: issue, worktree: path)
      } catch {
        if scheduleRepair(id, message: error.localizedDescription) { return }
        throw error
      }
      if !baseAlreadyUpdated {
        do {
          guard let branch = issue.branch else { throw ScreenClipError.message("No issue branch exists.") }
          try await GitWorkspace.updateBaseBeforeValidation(project: project, path: path, branch: branch)
        } catch let conflict as GitWorkspace.BaseConflict {
          guard model.issue(id)?.status == .working else { return }
          if scheduleRepair(id, message: conflict.agentInstructions,
            note: "The base branch conflicts with this fix; resolving the conflict") { return }
          try model.updateIssue(id) { $0.setValidationFeedback(conflict.agentInstructions) }
          throw conflict
        }
      }
      guard let current = model.issue(id), current.status == .working else { return }
      guard current.revision == issue.coveredRevision else { throw CancellationError() }
      try model.updateIssue(id) { $0.record("Running project validation", status: .working) }
      let receipt = try await GitWorkspace.validate(project: project, path: path)
      // Canceled, or canceled and queued again, during validation: leave that decision alone.
      // A queued report starts once this run has ended.
      guard model.issue(id)?.status == .working else { return }
      guard receipt.passed else {
        let feedback = "Project validation failed:\n" + receipt.output
        if scheduleRepair(id, message: feedback) { return }
        // Continue after a manual look still hands the agent the failing output.
        try model.updateIssue(id) { $0.setValidationFeedback(feedback) }
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
      try saveReceipt(savedReceipt, for: id, issue: issue)
      try model.updateIssue(id) { current in
        current.prURL = published.url
        current.prHead = published.head
        current.prRevision = issue.coveredRevision
        current.lastError = nil
        current.validationFeedback = nil
        current.record(
          "PR opened: " + published.url,
          status: [.canceled, .queued].contains(current.status)
            ? current.status : (current.revision == issue.coveredRevision ? .prOpen : .queued))
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
          // Canceled, or canceled and queued again, while publishing: keep that decision.
          $0.record(
            error.localizedDescription,
            status: [.canceled, .queued].contains($0.status) ? $0.status : .needsYou, kind: "error")
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
      for issue in model.snapshot.issues where Self.awaitsMergeOutsideScreenClip(issue) {
        await refreshStalledPR(issue.id)
      }
    }
    for issue in model.snapshot.issues where issue.status == .prOpen { await refreshPR(issue.id) }
  }
  /// Where gh runs for a report: its worktree, or the project's checkout, which has the same
  /// GitHub remote. The worktree may have been removed outside ScreenClip, for example by
  /// whoever resolved and merged the pull request, and gh cannot start in a missing directory.
  static func ghDirectory(_ issue: Issue, project: Project) -> String {
    guard let path = issue.worktreePath, FileManager.default.fileExists(atPath: path) else {
      return project.path
    }
    return path
  }
  /// An open pull request whose worktree is gone cannot be updated, validated, or merged here.
  static let removedWorktreeSummary =
    "The worktree for this fix was removed. Merge or close the PR on GitHub."
  nonisolated static let closedPullRequestActivity =
    "The pull request was closed without merging. Choose Continue to open a new one, or archive this report."
  /// A report that stopped for attention (a base conflict, failing checks, a question) keeps
  /// its pull request, and the tester may resolve and merge that pull request on GitHub.
  /// A report with no recorded pull request may still have had its branch merged outside
  /// ScreenClip (see `findsMergeByBranch`). An uncertain dispatch may still be running in the
  /// worktree; it waits for Reconcile.
  nonisolated static func awaitsMergeOutsideScreenClip(_ issue: Issue) -> Bool {
    [.needsYou, .failed].contains(issue.status)
      && (issue.prURL != nil || findsMergeByBranch(issue)) && !issue.archived
      && !issue.dispatchUncertain
  }
  /// A local agent's report that stopped before publishing, whose worktree was then removed
  /// outside ScreenClip, usually by whoever pushed the branch and merged it by hand. With the
  /// worktree gone there is no unpushed work to lose. Grok Bot reports reuse their branch
  /// across revisions, so only discovery, which checks the report in the PR body, links them.
  nonisolated static func findsMergeByBranch(_ issue: Issue) -> Bool {
    guard issue.prURL == nil, issue.branch != nil, issue.resolvedAgent != .external else {
      return false
    }
    guard let path = issue.worktreePath else { return true }
    return !FileManager.default.fileExists(atPath: path)
  }
  /// Only watches for a merge: anything else about the pull request waits for Continue.
  func refreshStalledPR(_ id: UUID) async {
    guard let issue = model.issue(id), Self.awaitsMergeOutsideScreenClip(issue),
      let project = model.project(issue.projectID), !isActive(id), !refreshing.contains(id)
    else { return }
    refreshing.insert(id)
    defer { refreshing.remove(id) }
    let path = Self.ghDirectory(issue, project: project)
    let gh = AgentDetector.ghPath(model.snapshot.settings)
    // Without a recorded pull request, the report's branch identifies it. Each local dispatch
    // after a merge gets a new workspace and branch, so a merged pull request from this branch
    // holds this report's fix.
    var found: String?
    if Self.findsMergeByBranch(issue), let branch = issue.branch {
      found = try? await GitHubService.mergedPullRequest(
        branch: branch, base: project.baseBranch, path: path, gh: gh)
    }
    guard let url = issue.prURL ?? found,
      let pr = try? await GitHubService.state(url: url, path: path, gh: gh),
      pr.merged
    else { return }
    // The tester may have continued, canceled, or added evidence while gh ran.
    guard let current = model.issue(id), Self.awaitsMergeOutsideScreenClip(current),
      (current.prURL ?? found) == url, current.branch == issue.branch, !isActive(id)
    else { return }
    model.perform {
      try model.updateIssue(id) { issue in
        // The report links to the pull request it found by branch.
        if issue.prURL == nil { issue.prURL = url }
        for i in issue.questions.indices where issue.questions[i].reply == nil {
          issue.questions[i].reply = "Pull request merged on GitHub"
        }
      }
      // Newer evidence may have been dispatched after the pull request was last updated; only
      // the revision it holds is fixed. Older queues have no record and use the covered one.
      try recordMerge(
        id, commit: pr.mergeCommit, coveredRevision: current.prRevision ?? current.coveredRevision)
    }
    if model.issue(id)?.status == .merged {
      model.notify(current, text: "Fix merged. Ready to rebuild and retest.")
    } else {
      // recordMerge queued the newer evidence for a new fix.
      pump()
    }
  }
  func refreshPR(_ id: UUID, mergeReviewedHead: String? = nil) async {
    // The caller's list is a snapshot from before earlier refreshes were awaited; this report
    // may have been canceled or sent back to its agent since.
    guard let issue = model.issue(id), issue.status == .prOpen, !issue.archived, let url = issue.prURL,
      let project = model.project(issue.projectID)
    else { return }
    guard !refreshing.contains(id), !mergingProjects.contains(project.id) else {
      if mergeReviewedHead != nil {
        try? model.updateIssue(id) {
          $0.checkSummary = "ScreenClip is busy with this project. Try the merge again in a moment."
        }
      }
      return
    }
    if let mergeReviewedHead {
      guard manualMergeHeads[id] == mergeReviewedHead, !model.snapshot.settings.paused else { return }
    }
    refreshing.insert(id)
    var eligibleHead: String?
    defer {
      if manualMergeHeads[id] != eligibleHead { manualMergeHeads[id] = eligibleHead }
      refreshing.remove(id)
    }
    do {
      let pr = try await GitHubService.state(
        url: url, path: Self.ghDirectory(issue, project: project),
        gh: AgentDetector.ghPath(model.snapshot.settings))
      guard pr.url == url, let current = model.issue(id), current.status == .prOpen,
        current.prURL == url, current.workspaceID == issue.workspaceID
      else { return }
      if pr.merged {
        try recordMerge(id, commit: pr.mergeCommit, coveredRevision: issue.prRevision ?? issue.coveredRevision)
        model.notify(issue, text: "Fix merged. Ready to rebuild and retest.")
        return
      }
      // Closed without merging: nothing will land, so the tester decides. Continue opens a new
      // pull request from the branch, and Move to project is allowed again. The closed one stays
      // in the activity ("PR opened: …").
      guard pr.open else {
        try model.updateIssue(id) {
          $0.checkSummary = nil
          $0.prURL = nil
          $0.prHead = nil
          $0.prRevision = nil
          $0.record(Self.closedPullRequestActivity, status: .needsYou)
          $0.unread = true
        }
        model.notify(current, text: Self.closedPullRequestActivity)
        return
      }
      guard let path = issue.worktreePath, FileManager.default.fileExists(atPath: path) else {
        if current.checkSummary != Self.removedWorktreeSummary {
          try model.updateIssue(id) { $0.checkSummary = Self.removedWorktreeSummary }
        }
        return
      }
      if let mergeReviewedHead, mergeReviewedHead != pr.head {
        try model.updateIssue(id) { $0.checkSummary = "The PR changed; run validation again before merging." }
        return
      }
      var validatedHere = true
      if issue.resolvedAgent == .external {
        switch try await inspectExternal(id, issue: issue, project: project, path: path,
          pullHead: pr.head, requestedMerge: mergeReviewedHead != nil)
        {
        case .blocked: return
        case .unvalidated: validatedHere = false
        case .ready: break
        }
      }
      if pr.checksFailed, model.issue(id)?.status == .prOpen {
        if issue.resolvedAgent == .external {
          if model.issue(id)?.checkSummary != pr.details {
            try model.updateIssue(id) {
              $0.checkSummary = pr.details
              $0.unread = true
              $0.record("GitHub checks failed. Grok Bot can push another commit to " + url + ".")
            }
          }
          return
        }
        // Checks reported for another head (one GitHub has not caught up from, or a commit
        // someone else pushed) say nothing about the fix in this worktree.
        guard pr.head == model.issue(id)?.prHead else {
          let summary = "The PR changed; run validation again before merging."
          if model.issue(id)?.checkSummary != summary {
            try model.updateIssue(id) { $0.checkSummary = summary }
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
      // An empty rollup counts as "no checks" only once it has stayed empty for this head,
      // so a merge cannot slip in before CI has registered its runs.
      let noChecksSettled: Bool
      if pr.noChecksReported {
        if emptyRollupSince[id]?.head != pr.head { emptyRollupSince[id] = (pr.head, Date()) }
        noChecksSettled =
          Date().timeIntervalSince(emptyRollupSince[id]?.since ?? Date()) >= emptyRollupGrace
      } else {
        emptyRollupSince[id] = nil
        noChecksSettled = false
      }
      let receipt = loadReceipt(id, issue: issue)
      // The local checkout can move independently while a PR is waiting for review.
      // Inspect the commit GitHub would actually merge.
      var carriesEvidence = true
      if model.issue(id)?.prHead == pr.head {
        carriesEvidence = ExternalAssistant.containsScreenclipEvidence(
          try await GitHubService.listScreenclipPaths(revision: pr.head, cwd: path))
      }
      guard let currentIssue = model.issue(id), currentIssue.status == .prOpen,
        currentIssue.prURL == url, currentIssue.workspaceID == issue.workspaceID
      else { return }
      let evidence = MergeEvidence(
        expectedHead: currentIssue.prHead ?? "", currentHead: pr.head,
        inputRevision: currentIssue.revision, coveredRevision: currentIssue.prRevision ?? currentIssue.coveredRevision,
        validationPassed: receipt?.passed == true && receipt?.head == pr.head,
        hasValidation: receipt?.command == project.validationCommand
          && !project.validationCommand.isEmpty, checksPassed: pr.checksPassed || noChecksSettled,
        mergeable: pr.mergeable && pr.base == project.baseBranch,
        reviewSatisfied: pr.reviewSatisfied,
        unresolvedQuestions: currentIssue.questions.contains { $0.reply == nil },
        // Grok Bot pull requests that still have their hand-off folder returned `.blocked` above.
        screenclipEvidenceCleared: !carriesEvidence, draft: pr.draft)
      let checkSummary: String
      if pr.draft {
        checkSummary = ExternalAssistant.draftPullRequestSummary
      } else if currentIssue.prHead != pr.head {
        checkSummary = "The PR changed; run validation again before merging."
      } else if pr.conflicting {
        // Ahead of the checks: CI often does not start on a conflicting pull request.
        checkSummary = "The base branch conflicts with this fix."
      } else if !pr.checksPassed && !noChecksSettled {
        checkSummary = pr.details
      } else if !pr.reviewSatisfied {
        checkSummary = "Waiting for required review."
      } else if pr.base != project.baseBranch {
        checkSummary = "The existing PR targets a different base branch."
      } else if !pr.mergeable {
        checkSummary = "Waiting for the PR to become mergeable."
      } else if !validatedHere {
        checkSummary = "Merge will run the project’s validation command on this Mac."
      } else if !evidence.validationPassed || !evidence.hasValidation {
        checkSummary = "Local validation is required for this commit."
      } else if noChecksSettled {
        checkSummary = "Local validation passed. GitHub reports no checks."
      } else if model.snapshot.settings.paused {
        checkSummary = "Checks passed. Processing is paused."
      } else if !project.autoMerge && mergeReviewedHead == nil {
        checkSummary = "Checks passed. Automatic merge is disabled for this project."
      } else {
        checkSummary = "Checks passed; preparing merge."
      }
      if model.issue(id)?.checkSummary != checkSummary {
        try model.updateIssue(id) { $0.checkSummary = checkSummary }
      }
      // A conflict never clears by waiting, and it blocks a manual merge too, so the base is
      // integrated whether or not automatic merge is on.
      let resolvesConflict =
        pr.conflicting && !pr.draft && pr.base == project.baseBranch
        && currentIssue.prHead == pr.head && currentIssue.revision == currentIssue.coveredRevision
        && !evidence.unresolvedQuestions
        // A Grok Bot pull request is only validated, and so only updated, on this Mac with
        // automatic merge on, or when the tester confirms a merge.
        && (issue.resolvedAgent != .external || project.autoMerge)
      // A clean PR whose check rollup has stayed empty can be merged by the tester after
      // local validation. Automatic merge still requires at least one passing GitHub check.
      let approved = mergeReviewedHead != nil || (project.autoMerge && pr.checksPassed)
      let mergesNow = evidence.canMerge && approved
      // A head with `.screenclip/` is never merged. ScreenClip removes the folder and pushes;
      // the merge follows once checks pass on that commit.
      let removesEvidence = evidence.removesEvidenceFirst && approved
      if !mergesNow, !removesEvidence, evidence.readyForValidation,
        currentIssue.revision == currentIssue.coveredRevision,
        evidence.canMerge || evidence.removesEvidenceFirst
          || (!validatedHere && !project.validationCommand.isEmpty)
      {
        eligibleHead = pr.head
      }
      guard (mergesNow || removesEvidence || resolvesConflict) && !model.snapshot.settings.paused
      else { return }
      // Re-check after the awaits above: parallel reports in one project must merge one at a
      // time, so each later merge revalidates against the base that already includes the earlier.
      guard !mergingProjects.contains(project.id), model.issue(id)?.status == .prOpen else { return }
      mergingProjects.insert(project.id)
      defer { mergingProjects.remove(project.id) }
      let baseAdvanced: Bool
      do {
        baseAdvanced = try await GitWorkspace.updateBaseIfNeeded(
          project: project, path: path, keepConflicts: issue.resolvedAgent != .external)
      } catch let conflict as GitWorkspace.BaseConflict where conflict.kept {
        // The merge stays in progress with its conflict markers. The agent resolves them in
        // the files; the next publish commits, which concludes the merge, and pushes.
        if scheduleRepair(
          id, message: conflict.agentInstructions,
          note: "The base branch conflicts with this fix; resolving the conflict")
        {
          pump()
        } else {
          await GitWorkspace.abortMerge(path: path)
          try model.updateIssue(id) {
            $0.lastError = conflict.localizedDescription
            $0.unread = true
            $0.record("The base update needs attention in " + issue.resolvedAgent.title + ".", status: .needsYou)
          }
        }
        return
      } catch let error
        where !(error is GitWorkspace.BaseMergeFailed) && !(error is GitWorkspace.BaseConflict)
      {
        // A failed fetch (network, SSH agent, GitHub) is not a problem in the worktree. The
        // report stays open and the next refresh tries again. A merge that failed or
        // conflicted does not clear by waiting, and is handled below.
        try model.updateIssue(id) { $0.lastError = error.localizedDescription }
        return
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
          summary: issue.resultSummary ?? "Update fix against the current base branch", baseAlreadyUpdated: true)
        return
      }
      // Recheck local revision immediately before submitting a guarded merge.
      guard mergesNow || removesEvidence, let latest = model.issue(id), latest.status == .prOpen,
        latest.revision == issue.coveredRevision, latest.prURL == url, latest.prHead == pr.head,
        latest.questions.allSatisfy({ $0.reply != nil }), !model.snapshot.settings.paused,
        let latestProject = model.project(latest.projectID), latestProject.baseBranch == pr.base,
        latestProject.validationCommand == project.validationCommand,
        latestProject.autoMerge || mergeReviewedHead == pr.head
      else { return }
      if removesEvidence {
        try await removeEvidenceBeforeMerge(id, issue: issue, path: path, pullHead: pr.head)
        return
      }
      try await GitHubService.merge(
        url: url, head: pr.head, path: path, gh: AgentDetector.ghPath(model.snapshot.settings))
      let confirmed = try await GitHubService.state(
        url: url, path: path, gh: AgentDetector.ghPath(model.snapshot.settings))
      if confirmed.merged {
        try recordMerge(
          id, commit: confirmed.mergeCommit, coveredRevision: issue.prRevision ?? issue.coveredRevision)
        model.notify(issue, text: "Fix merged. Ready to rebuild and retest.")
      }
    } catch {
      model.perform { try model.updateIssue(id) { $0.lastError = error.localizedDescription } }
    }
  }
  /// Removes `.screenclip/` from the pull request in a commit of its own and pushes it, so the
  /// squash merge cannot carry evidence into the base. The description keeps its images: they are
  /// linked at the commit that added them. The validation receipt moves to the new head, which
  /// only deletes ScreenClip's evidence files; GitHub checks run again before the merge.
  func removeEvidenceBeforeMerge(_ id: UUID, issue: Issue, path: String, pullHead: String) async throws {
    guard let branch = issue.branch else { throw ScreenClipError.message("No issue branch exists.") }
    let head = try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: path)
    let checkedOut = try await CommandRunner.checked(GitWorkspace.git, ["branch", "--show-current"], cwd: path)
    guard head == pullHead, checkedOut == branch else {
      throw ScreenClipError.message(
        "The worktree is not on the pull request's head, so ScreenClip did not remove its evidence files.")
    }
    guard let removed = try await PRScreenshotEvidence.removeFromBranch(worktree: path) else { return }
    do {
      _ = try await CommandRunner.checked(
        GitWorkspace.git, ["push", "origin", removed + ":refs/heads/" + branch], cwd: path)
    } catch {
      // Undo only this commit's tree changes. A hard reset would erase unrelated local
      // edits, including another change staged before the evidence removal.
      let current = try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: path)
      if current == removed,
        try await CommandRunner.checked(GitWorkspace.git, ["branch", "--show-current"], cwd: path) == branch
      {
        _ = try await CommandRunner.checked(GitWorkspace.git, ["read-tree", "-m", "-u", removed, head], cwd: path)
        _ = try await CommandRunner.checked(GitWorkspace.git, ["update-ref", "refs/heads/" + branch, head, removed], cwd: path)
      }
      throw error
    }
    if var receipt = loadReceipt(id, issue: issue), receipt.head == pullHead {
      receipt.head = removed
      try saveReceipt(receipt, for: id, issue: issue)
    }
    let summary = PRScreenshotEvidence.removedBeforeMergeSummary
    try model.updateIssue(id) {
      $0.prHead = removed
      $0.lastError = nil
      $0.checkSummary = summary
      $0.record(summary)
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
        issue.deliveredContext = nil
        issue.worktreePath = nil
        issue.branch = nil
        issue.prURL = nil
        issue.prHead = nil
        issue.prRevision = nil
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
  /// `note` replaces the timeline entry when the repair is not about failed checks.
  func scheduleRepair(_ id: UUID, message: String, note: String? = nil) -> Bool {
    guard model.issue(id)?.resolvedAgent != .external else { return false }
    guard let issue = model.issue(id), issue.status != .canceled,
      issue.revision == issue.coveredRevision, (issue.repairAttempts ?? 0) < 2
    else { return false }
    do {
      try model.updateIssue(id) {
        $0.repairAttempts = ($0.repairAttempts ?? 0) + 1
        $0.lastError = message
        $0.setValidationFeedback(message)
        $0.record(
          note ?? "Checks failed; starting repair attempt \($0.repairAttempts ?? 1) of 2",
          status: .queued)
      }
      return true
    } catch {
      model.banner = error.localizedDescription
      return false
    }
  }
}
