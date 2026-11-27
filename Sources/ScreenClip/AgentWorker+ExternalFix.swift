import Foundation
import ScreenClipCore

/// Reports fixed outside ScreenClip's own agents, for example by another Claude Code session
/// that merged its own pull request after ScreenClip's agent stopped on a usage limit.
extension AgentWorker {
  /// The automatic search runs at most this often per project; Refresh runs it at once.
  static let externalFixSearchInterval: TimeInterval = 300

  /// Closes each open report that a merged pull request in its project's repository names as
  /// `ScreenClip #N` (see `ExternalFix.fix`). Reports ScreenClip's agent is working on, and
  /// reports that are done, are never touched.
  func closeReportsFixedElsewhere(force: Bool, now: Date = Date()) async {
    let candidates = model.snapshot.issues.filter { ExternalFix.canClose($0) && !isActive($0.id) }
    let gh = AgentDetector.ghPath(model.snapshot.settings)
    for projectID in Set(candidates.compactMap(\.projectID)) {
      guard let project = model.project(projectID) else { continue }
      if !force, let last = lastExternalFixSearch[projectID],
        now.timeIntervalSince(last) < Self.externalFixSearchInterval
      {
        continue
      }
      lastExternalFixSearch[projectID] = now
      guard let repo = try? await githubRepo(project),
        let merged = try? await GitHubService.mergedPullRequestsMentioningScreenClip(
          base: project.baseBranch, path: project.path, gh: gh)
      else { continue }
      for issue in candidates where issue.projectID == projectID {
        // The tester or the worker may have moved the report on while gh ran.
        guard let current = model.issue(issue.id), current.projectID == projectID,
          !isActive(issue.id), !refreshing.contains(issue.id),
          let pr = ExternalFix.fix(for: current, in: merged, repo: repo, base: project.baseBranch)
        else { continue }
        closeAsFixedElsewhere(issue.id, url: pr.url, commit: pr.mergeCommit, head: pr.headRefName)
      }
    }
  }

  /// Records `url` as the report's merged fix. The report's own worktree and branch are freed
  /// only when the fix was merged from that branch; otherwise they may hold other work.
  func closeAsFixedElsewhere(_ id: UUID, url: String, commit: String?, head: String?) {
    guard let issue = model.issue(id) else { return }
    model.perform {
      try model.updateIssue(id) { issue in
        issue.prURL = url
        issue.prRevision = issue.revision
        issue.handover = nil
        issue.checkSummary = nil
        for i in issue.questions.indices where issue.questions[i].reply == nil {
          issue.questions[i].reply = "Fixed outside ScreenClip"
        }
        issue.record(ExternalFix.activity(url))
      }
      try recordMerge(
        id, commit: commit, coveredRevision: issue.revision,
        cleanUp: head != nil && head == issue.branch)
    }
    if model.issue(id)?.status == .merged {
      model.notify(issue, text: "Fix merged. Ready to rebuild and retest.")
    }
  }

  /// Why GitHub does not confirm `url` as a merged fix for a report of `project`, or nil when
  /// it is merged into the project's base branch, in the project's own repository. Used before
  /// an agent's `close_issue` with a pull request marks a report merged. `unreachable` is true when
  /// GitHub did not answer, which says nothing about the pull request.
  func refusalForMergedPullRequest(
    _ url: String, project: Project, after evidence: Date? = nil
  ) async -> (refusal: String?, mergeCommit: String?, unreachable: Bool) {
    let repo: String
    do { repo = try await githubRepo(project) } catch {
      return (error.localizedDescription, nil, false)
    }
    guard ExternalFix.pullRequestNumber(url, repo: repo) != nil else {
      return ("\(url) is not a pull request of \(repo), the repository of project \(project.name).", nil, false)
    }
    let pr: PRState
    do {
      pr = try await GitHubService.state(
        url: url, path: project.path, gh: AgentDetector.ghPath(model.snapshot.settings))
    } catch {
      return ("GitHub did not confirm \(url): \(error.localizedDescription)", nil, true)
    }
    guard pr.merged else { return ("\(url) is not merged.", nil, false) }
    guard pr.base == project.baseBranch else {
      return ("\(url) was merged into \(pr.base), not \(project.baseBranch).", nil, false)
    }
    // Like the automatic match: a merge from before the report's newest evidence is not its fix.
    if let evidence {
      let gh = AgentDetector.ghPath(model.snapshot.settings)
      let text = try? await CommandRunner.checked(
        gh, ["pr", "view", url, "--json", "mergedAt", "--jq", ".mergedAt"], cwd: project.path)
      if let merged = text.flatMap({ ISO8601DateFormatter().date(from: $0) }), merged < evidence.addingTimeInterval(-300) {
        return ("\(url) was merged before the report's latest evidence.", nil, false)
      }
    }
    return (nil, pr.mergeCommit, false)
  }
}
