import Foundation
import ScreenClipCore

/// Frees report worktrees that are no longer needed, without losing work. A worktree and its
/// local branch are removed only when `GitWorkspace.reasonToKeep` finds nothing to lose: no
/// uncommitted or untracked changes, and every commit already on origin. Remote branches are
/// never deleted here (`removeWorkspace` does that, only after ScreenClip's own merge).
extension AgentWorker {
  /// Removes the report's worktree when the report no longer needs it: merged or verified,
  /// closed by an agent, or archived. Kept while ScreenClip is working on the report.
  func releaseWorkspace(_ id: UUID) async {
    guard let issue = model.issue(id), let path = issue.worktreePath,
      let project = model.project(issue.projectID), Self.canRelease(issue), !isActive(id)
    else { return }
    let branch = issue.branch
    let removed = await removeIfUnneeded(path: path, branch: branch, project: project) { [weak self] in
      guard let self, let current = self.model.issue(id) else { return false }
      return current.worktreePath == path && Self.canRelease(current) && !self.isActive(id)
    }
    guard removed else { return }
    model.perform {
      try model.updateIssue(id) { issue in
        if issue.worktreePath == path { issue.worktreePath = nil }
      }
    }
  }

  /// A report whose worktree may be freed: finished, or archived.
  static func canRelease(_ issue: Issue) -> Bool {
    !issue.dispatchUncertain
      && (issue.archived || [.merged, .verified].contains(issue.status)
        || (issue.status == .canceled && issue.activities.last?.kind == "agent-closure"))
  }

  /// Removes a worktree no report refers to any more, for example after a merged report got new
  /// evidence (it continues in a new worktree) or after a report was deleted.
  func releaseUnreferencedWorkspace(path: String, branch: String?, project: Project) async {
    _ = await removeIfUnneeded(path: path, branch: branch, project: project) { [weak self] in
      guard let self else { return false }
      return !self.isReferenced(path)
    }
  }

  /// On launch: frees worktrees of finished or archived reports kept by earlier versions, and
  /// ScreenClip worktrees no report refers to.
  func releaseUnneededWorkspaces() async {
    for issue in model.snapshot.issues where issue.worktreePath != nil && Self.canRelease(issue) {
      await releaseWorkspace(issue.id)
    }
    var repositories = Set<String>()
    for project in model.snapshot.projects where repositories.insert(project.path).inserted {
      for worktree in await GitWorkspace.worktrees(repository: project.path)
      where GitWorkspace.isScreenClipWorktree(worktree.path, root: model.store.root)
        && !isReferenced(worktree.path)
      {
        await releaseUnreferencedWorkspace(
          path: worktree.path, branch: worktree.branch, project: project)
      }
    }
  }

  func isReferenced(_ path: String) -> Bool {
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return model.snapshot.issues.contains {
      guard let other = $0.worktreePath else { return false }
      return other == path || URL(fileURLWithPath: other).resolvingSymlinksInPath().path == target
    }
  }

  /// Runs the safety checks and the removal as one workspace change of the project, so it never
  /// overlaps a worktree being created. `stillUnneeded` is asked again right before removal.
  func removeIfUnneeded(
    path: String, branch: String?, project: Project,
    stillUnneeded: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let root = model.store.root
    return (try? await serializedWorkspaceChange(project.id) {
      guard stillUnneeded(),
        await GitWorkspace.reasonToKeep(
          path: path, branch: branch, repository: project.path, root: root) == nil,
        stillUnneeded()
      else { return false }
      return await GitWorkspace.remove(path: path, branch: branch, repository: project.path)
    }) ?? false
  }
}
