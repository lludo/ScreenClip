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
        // The same path as an agent's close_issue; the search already found it merged into the
        // project's base branch, so GitHub is not asked again.
        await applyClosure(
          AgentClosure(
            issueID: issue.id, resolution: .done, pullRequest: pr.url, commit: pr.mergeCommit,
            summary: ExternalFix.activity(pr.url), closer: "ScreenClip"),
          pullRequestVerified: true)
      }
    }
  }

  /// Why GitHub does not confirm `url` as a merged fix for a report of `project`, or nil when
  /// it is merged into the project's base branch, in the project's own repository. Used before
  /// an agent's `close_issue` with a pull request marks a report merged.
  func refusalForMergedPullRequest(_ url: String, project: Project) async -> (refusal: String?, mergeCommit: String?) {
    let repo: String
    do { repo = try await githubRepo(project) } catch {
      return (error.localizedDescription, nil)
    }
    guard ExternalFix.pullRequestNumber(url, repo: repo) != nil else {
      return ("\(url) is not a pull request of \(repo), the repository of project \(project.name).", nil)
    }
    let pr: PRState
    do {
      pr = try await GitHubService.state(
        url: url, path: project.path, gh: AgentDetector.ghPath(model.snapshot.settings))
    } catch {
      return ("GitHub did not confirm \(url): \(error.localizedDescription)", nil)
    }
    guard pr.merged else { return ("\(url) is not merged.", nil) }
    guard pr.base == project.baseBranch else {
      return ("\(url) was merged into \(pr.base), not \(project.baseBranch).", nil)
    }
    return (nil, pr.mergeCommit)
  }
}
