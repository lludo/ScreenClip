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
      "/usr/bin/git", ["remote", "get-url", "origin"], cwd: path)
    guard isGitHubRemote(remote) else {
      throw ScreenClipError.message(
        "This version publishes to GitHub. Configure the repository's GitHub origin.")
    }
    let changes = try await CommandRunner.checked(
      "/usr/bin/git", ["status", "--porcelain"], cwd: path)
    guard await shouldContinue(),
      try await GitWorkspace.fingerprint(path: path) == receipt.fingerprint
    else {
      throw ScreenClipError.message(
        "The source or issue changed after validation. Publication stopped.")
    }
    if !changes.isEmpty {
      let files = try await CommandRunner.checked(
        "/usr/bin/git", ["ls-files", "--modified", "--deleted", "--others", "--exclude-standard", "-z"], cwd: path)
      let paths = Array(Set(files.split(separator: "\0").map(String.init))).sorted()
      guard !paths.isEmpty else { throw ScreenClipError.message("No source paths to publish.") }
      _ = try await CommandRunner.checked("/usr/bin/git", ["add", "--"] + paths, cwd: path)
      guard await shouldContinue() else { throw CancellationError() }
      _ = try await CommandRunner.checked(
        "/usr/bin/git", ["commit", "-m", "Fix: " + String(issue.title.prefix(120))], cwd: path)
    }
    let base = await GitWorkspace.baseRef(project: project, path: path)
    let commits = try await CommandRunner.checked(
      "/usr/bin/git", ["rev-list", "--count", base + "..HEAD"], cwd: path)
    guard (Int(commits) ?? 0) > 0 else {
      throw ScreenClipError.message(
        "No fix commit was produced. Open the \(issue.resolvedAgent.title) conversation to review the result.")
    }
    let head = try await CommandRunner.checked("/usr/bin/git", ["rev-parse", "HEAD"], cwd: path)
    guard await shouldContinue(),
      try await GitWorkspace.fingerprint(path: path) == receipt.fingerprint
    else {
      throw ScreenClipError.message("The source or issue changed before push. Publication stopped.")
    }
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["push", "-u", "origin", branch], cwd: path)
    let existing = try await CommandRunner.checked(
      gh, ["pr", "list", "--head", branch, "--state", "open", "--json", "url,baseRefName"],
      cwd: path)
    let list = try JSONDecoder().decode(JSONValue.self, from: Data(existing.utf8)).array
    guard await shouldContinue() else { throw CancellationError() }
    if let pr = list.first {
      guard pr["baseRefName"].string == project.baseBranch, let url = pr["url"].string else {
        throw ScreenClipError.message("The existing PR targets a different base branch.")
      }
      return (url, head)
    }
    // Preserve newlines and avoid shell interpolation in PR content.
    let body =
      "\(summary)\n\nValidation: `\(redactSecrets(project.validationCommand))`\n\nScreenClip report: \(issue.reportReference ?? issue.id.uuidString)\nIssue ID: \(issue.id.uuidString)\nInput revision: \(issue.revision)\n\nScreenshots and source context remain in ScreenClip."
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "screenclip-pr-\(UUID().uuidString).md")
    try body.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
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
  public static func state(url: String, path: String, gh: String) async throws -> PRState {
    guard URL(string: url)?.host == "github.com" else {
      throw ScreenClipError.message("Invalid GitHub PR URL.")
    }
    let text = try await CommandRunner.checked(
      gh,
      [
        "pr", "view", url, "--json",
        "url,headRefOid,baseRefName,state,mergeCommit,statusCheckRollup,mergeStateStatus,mergeable,reviewDecision",
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
    var result = text.replacingOccurrences(
      of: #"\b([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|\S+)"#, with: "$1=…",
      options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"\b(gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{40,})\b"#,
      with: "…", options: .regularExpression)
    return result
  }
}
