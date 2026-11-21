import Foundation

public enum GitHubService {
  public static func publish(
    project: Project, issue: Issue, summary: String, receipt: ValidationReceipt, gh: String,
    shouldContinue: @escaping @MainActor () -> Bool
  ) async throws -> (url: String, head: String) {
    guard let path = issue.worktreePath, let branch = issue.branch else {
      throw ScreenClipError.message("No issue worktree exists.")
    }
    _ = try await CommandRunner.checked(gh, ["auth", "status"], cwd: path)
    let remote = try await CommandRunner.checked(
      GitWorkspace.git, ["remote", "get-url", "origin"], cwd: path)
    guard isGitHubRemote(remote) else {
      throw ScreenClipError.message(
        "This version publishes to GitHub. Configure the repository's GitHub origin.")
    }
    let changes = try await CommandRunner.checked(
      GitWorkspace.git, ["status", "--porcelain"], cwd: path)
    guard await shouldContinue(),
      try await GitWorkspace.fingerprint(path: path) == receipt.fingerprint
    else {
      throw ScreenClipError.message(
        "The source or issue changed after validation. Publication stopped.")
    }
    if !changes.isEmpty {
      try await stageChanges(cwd: path)
      guard await shouldContinue() else { throw CancellationError() }
      _ = try await CommandRunner.checked(
        GitWorkspace.git, ["commit", "-m", "Fix: " + String(issue.title.prefix(120))], cwd: path)
    }
    let base = await GitWorkspace.baseRef(project: project, path: path)
    let commits = try await CommandRunner.checked(
      GitWorkspace.git, ["rev-list", "--count", base + "..HEAD"], cwd: path)
    guard (Int(commits) ?? 0) > 0 else {
      throw ScreenClipError.message(
        "No fix commit was produced. Open the \(issue.resolvedAgent.title) conversation to review the result.")
    }
    let head = try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: path)
    guard await shouldContinue(),
      try await GitWorkspace.fingerprint(path: path) == receipt.fingerprint
    else {
      throw ScreenClipError.message("The source or issue changed before push. Publication stopped.")
    }
    let screenshots = try PRScreenshotEvidence.markdown(issue: issue, worktree: path, remote: remote, head: head)
    try await pushBranch(branch, cwd: path)
    let existing = try await CommandRunner.checked(
      gh, ["pr", "list", "--head", branch, "--state", "open", "--json", "url,baseRefName,isCrossRepository"],
      cwd: path)
    let list = try JSONDecoder().decode(JSONValue.self, from: Data(existing.utf8)).array
    guard await shouldContinue() else { throw CancellationError() }
    let body =
      "\(summary)\n\n\(screenshots)\n\nValidation: `\(redactSecrets(project.validationCommand))`\n\nScreenClip report: \(issue.reportReference ?? issue.id.uuidString)\nIssue ID: \(issue.id.uuidString)\nInput revision: \(issue.revision)"
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "screenclip-pr-\(UUID().uuidString).md")
    try body.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    // A fork can open a pull request from a branch with the same name; that one is not ours.
    if let pr = list.first(where: { $0["isCrossRepository"].bool != true }) {
      guard pr["baseRefName"].string == project.baseBranch, let url = pr["url"].string else {
        throw ScreenClipError.message("The existing PR targets a different base branch.")
      }
      _ = try await CommandRunner.checked(gh, ["pr", "edit", url, "--body-file", file.path], cwd: path)
      return (url, head)
    }
    let url = try await CommandRunner.checked(
      gh,
      [
        "pr", "create", "--head", branch, "--base", project.baseBranch, "--title",
        String(issue.title.prefix(200)), "--body-file", file.path,
      ], cwd: path)
    guard URL(string: url)?.host == "github.com" else {
      throw ScreenClipError.message(
        "Could not identify the created PR. Inspect the branch before retrying.")
    }
    return (url, head)
  }
  /// Stages every change for the fix commit. A deletion that is already staged has no path
  /// left to add: a base merge left in progress stages the files the base deleted or renamed,
  /// and naming them would make `git add` fail.
  public static func stageChanges(cwd path: String) async throws {
    func list(_ arguments: [String]) async throws -> Set<String> {
      Set(
        try await CommandRunner.checked(GitWorkspace.git, arguments, cwd: path)
          .split(separator: "\0").map(String.init))
    }
    let unstaged = try await list(
      ["ls-files", "--modified", "--deleted", "--others", "--exclude-standard", "-z"])
    let staged = try await list(["diff", "--cached", "--name-only", "-z"])
    let stagedDeletions = try await list(
      ["diff", "--cached", "--name-only", "--diff-filter=D", "-z"])
    guard !unstaged.isEmpty || !staged.isEmpty else {
      throw ScreenClipError.message("No source paths to publish.")
    }
    let paths = unstaged.union(staged.subtracting(stagedDeletions)).sorted()
    guard !paths.isEmpty else { return }
    _ = try await CommandRunner.checked(GitWorkspace.git, ["add", "--"] + paths, cwd: path)
  }
  public static func state(url: String, path: String, gh: String) async throws -> PRState {
    guard URL(string: url)?.host == "github.com" else {
      throw ScreenClipError.message("Invalid GitHub PR URL.")
    }
    let text = try await CommandRunner.checked(
      gh,
      [
        "pr", "view", url, "--json",
        "url,headRefOid,baseRefName,state,mergeCommit,statusCheckRollup,mergeStateStatus,mergeable,reviewDecision,isDraft",
      ], cwd: path)
    return PRState.parse(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
  }
  public static func merge(url: String, head: String, path: String, gh: String) async throws {
    _ = try await CommandRunner.checked(
      gh, ["pr", "merge", url, "--squash", "--match-head-commit", head], cwd: path)
  }

  /// Accepts github.com over HTTPS, SSH URL, or scp-style SSH, and nothing that merely
  /// contains the string (such as github.com.example.net).
  public static func isGitHubRemote(_ remote: String) -> Bool {
    let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: value), let host = url.host, url.scheme != nil {
      return host.lowercased() == "github.com"
    }
    // scp-style: [user@]github.com:owner/repo.git
    guard let colon = value.firstIndex(of: ":") else { return false }
    let hostPart = value[..<colon].split(separator: "@").last.map(String.init) ?? ""
    return hostPart.lowercased() == "github.com" && !value[value.index(after: colon)...].isEmpty
  }

  /// Hides values in `NAME=value` assignments and long token-like strings so a validation
  /// command never publishes credentials in a PR body.
  public static func redactSecrets(_ text: String) -> String {
    redactTokens(
      text.replacingOccurrences(
        of: #"\b([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|\S+)"#, with: "$1=…",
        options: .regularExpression))
  }
  /// Hides only token-shaped strings. For agent prompts, where `CI=1 npm test` must stay runnable.
  public static func redactTokens(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\b(gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{40,})\b"#,
      with: "…", options: .regularExpression)
  }
  public static func pullRequests(head: String, gh: String, cwd: String) async throws
    -> [ExternalPullRequestCandidate]
  {
    let text = try await CommandRunner.checked(
      gh,
      [
        "pr", "list", "--head", head, "--state", "all", "--json",
        "url,headRefName,body,state,isCrossRepository,headRepositoryOwner,isDraft",
      ],
      cwd: cwd)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).array.map {
      candidate in
      ExternalPullRequestCandidate(
        url: candidate["url"].string ?? "", headRefName: candidate["headRefName"].string ?? "",
        body: candidate["body"].string ?? "", state: candidate["state"].string ?? "",
        crossRepository: candidate["isCrossRepository"].bool, draft: candidate["isDraft"].bool,
        headOwner: candidate["headRepositoryOwner"].string
          ?? candidate["headRepositoryOwner"]["login"].string)
    }
  }
  /// Latest `screenclip/grok-bot` commit status, or nil when the routine has not posted one.
  /// GitHub returns newest first. A missing status is not an error.
  public static func externalStatus(repo: String, commit: String, gh: String, cwd: String)
    async throws -> ExternalStatus?
  {
    guard isRepositorySlug(repo), isCommit(commit) else {
      throw ScreenClipError.message("Could not read the Grok Bot status for this report.")
    }
    let text = try await CommandRunner.checked(
      gh, ["api", "--paginate", "repos/\(repo)/commits/\(commit)/statuses"], cwd: cwd)
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
      return nil
    }
    return ExternalStatus.first(in: value)
  }
  public static func isRepositorySlug(_ repo: String) -> Bool {
    repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
  }
  public static func isCommit(_ commit: String) -> Bool {
    commit.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil
  }
  public static func listScreenclipPaths(revision: String, cwd: String) async throws -> [String] {
    let result = try await CommandRunner.run(
      GitWorkspace.git, ["ls-tree", "-r", "--name-only", revision, "--", ".screenclip"], cwd: cwd)
    guard result.status == 0 else {
      throw ScreenClipError.message(result.error.isEmpty ? result.output : result.error)
    }
    return result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }
  public static func commitEvidence(directory: String, message: String, cwd: String) async throws
    -> String
  {
    // Forced, like the Before / After evidence: an ignore rule such as `*.png` would otherwise
    // leave the screenshots out of a commit whose webhook still names them.
    _ = try await CommandRunner.checked(GitWorkspace.git, ["add", "--force", "--", directory], cwd: cwd)
    let status = try await CommandRunner.checked(
      GitWorkspace.git, ["status", "--porcelain", "--", directory], cwd: cwd)
    if !status.isEmpty {
      _ = try await CommandRunner.checked(GitWorkspace.git, ["commit", "-m", message], cwd: cwd)
    }
    return try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: cwd)
  }
  public static func pushBranch(_ branch: String, cwd: String) async throws {
    _ = try await CommandRunner.checked(
      GitWorkspace.git, ["push", "-u", "origin", branch], cwd: cwd)
  }
  /// Fast-forward onto the remote branch when it exists. A missing remote branch is the first push.
  public static func integrateRemoteBranch(_ branch: String, cwd: String) async throws {
    let fetch = try await CommandRunner.run(
      GitWorkspace.git, ["fetch", "origin", branch], cwd: cwd)
    guard fetch.status == 0 else { return }
    try await fastForwardToFetchHead(cwd: cwd)
  }
  public static func remoteContains(commit: String, branch: String, cwd: String) async throws -> Bool
  {
    let fetch = try await CommandRunner.run(
      GitWorkspace.git, ["fetch", "origin", branch], cwd: cwd)
    guard fetch.status == 0 else { return false }
    let ancestor = try await CommandRunner.run(
      GitWorkspace.git, ["merge-base", "--is-ancestor", commit, "FETCH_HEAD"], cwd: cwd)
    return ancestor.status == 0
  }
  public static func fastForwardToFetchHead(cwd: String) async throws {
    let ahead = try await CommandRunner.checked(
      GitWorkspace.git, ["rev-list", "--count", "FETCH_HEAD..HEAD"], cwd: cwd)
    let behind = try await CommandRunner.checked(
      GitWorkspace.git, ["rev-list", "--count", "HEAD..FETCH_HEAD"], cwd: cwd)
    guard (Int(behind) ?? 0) > 0 else { return }
    guard (Int(ahead) ?? 0) == 0 else {
      throw ScreenClipError.message(
        "The evidence branch has diverged from GitHub. ScreenClip did not overwrite either side.")
    }
    let dirty = try await CommandRunner.checked(
      GitWorkspace.git, ["status", "--porcelain"], cwd: cwd)
    guard dirty.isEmpty else {
      throw ScreenClipError.message(
        "The evidence worktree has uncommitted changes, so ScreenClip did not update it to the pull request."
      )
    }
    let fastForward = try await CommandRunner.run(
      GitWorkspace.git, ["merge", "--ff-only", "FETCH_HEAD"], cwd: cwd)
    if fastForward.status != 0 {
      // Not a fast-forward: the clean-tree and not-ahead checks above make discarding local state safe.
      _ = try await CommandRunner.checked(
        GitWorkspace.git, ["reset", "--hard", "FETCH_HEAD"], cwd: cwd)
    }
  }
}
