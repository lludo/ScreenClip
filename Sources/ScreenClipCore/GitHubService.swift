import Foundation

public struct PRState {
  public var url: String
  public var head: String
  public var base: String
  public var merged: Bool
  public var mergeCommit: String?
  public var checksPassed: Bool
  public var checksFailed: Bool
  public var mergeable: Bool
  public var reviewSatisfied: Bool
  public var details: String
  public static func parse(_ value: JSONValue) -> PRState {
    let checks = value["statusCheckRollup"].array
    let passing: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]
    let pending: Set<String> = [
      "PENDING", "EXPECTED", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED",
    ]
    let conclusions = checks.map {
      $0["conclusion"].string.flatMap { $0.isEmpty ? nil : $0 } ?? $0["state"].string ?? $0[
        "status"
      ].string ?? "UNKNOWN"
    }
    let failed = conclusions.contains { !passing.contains($0) && !pending.contains($0) }
    let passed = !checks.isEmpty && conclusions.allSatisfy { passing.contains($0) }
    return PRState(
      url: value["url"].string ?? "", head: value["headRefOid"].string ?? "",
      base: value["baseRefName"].string ?? "", merged: value["state"].string == "MERGED",
      mergeCommit: value["mergeCommit"]["oid"].string, checksPassed: passed, checksFailed: failed,
      mergeable: value["mergeStateStatus"].string == "CLEAN"
        && value["mergeable"].string == "MERGEABLE",
      reviewSatisfied: !["REVIEW_REQUIRED", "CHANGES_REQUESTED"].contains(
        value["reviewDecision"].string ?? ""),
      details: checks.isEmpty
        ? "Waiting for check results. Configure at least one required CI check for automatic merge."
        : (failed
          ? "One or more checks failed." : (passed ? "Checks passed." : "Checks are running.")))
  }
}

public struct ValidationReceipt: Codable {
  public var head: String
  public var command: String
  public var passed: Bool
  public var date: Date
  public var output: String
  public var fingerprint: String
}

public enum GitHubService {
  public static func validate(project: Project, path: String) async throws -> ValidationReceipt {
    guard !project.validationCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ScreenClipError.message(
        "Add a validation command in this project's settings before publishing a fix.")
    }
    let before = try await GitWorkspace.fingerprint(path: path)
    let result = try await CommandRunner.run(
      "/bin/zsh", ["-c", project.validationCommand], cwd: path, timeout: 600)
    let after = try await GitWorkspace.fingerprint(path: path)
    guard before == after else {
      throw ScreenClipError.message(
        "Source files changed during validation. Run the checks again before publishing.")
    }
    let head = try await CommandRunner.checked("/usr/bin/git", ["rev-parse", "HEAD"], cwd: path)
    return ValidationReceipt(
      head: head, command: project.validationCommand, passed: result.status == 0, date: Date(),
      output: String((result.output + "\n" + result.error).suffix(8000)), fingerprint: after)
  }
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
    guard remote.contains("github.com") else {
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
    let commits = try await CommandRunner.checked(
      "/usr/bin/git", ["rev-list", "--count", project.baseBranch + "..HEAD"], cwd: path)
    guard (Int(commits) ?? 0) > 0 else {
      throw ScreenClipError.message(
        "No fix commit was produced. Open the Codex chat to review the result.")
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
      "\(summary)\n\nValidation: `\(project.validationCommand)`\n\nScreenClip report: \(issue.reportReference ?? issue.id.uuidString)\nIssue ID: \(issue.id.uuidString)\nInput revision: \(issue.revision)\n\nScreenshots and source context remain in ScreenClip."
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
  public static func updateBaseIfNeeded(project: Project, path: String) async throws -> Bool {
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["fetch", "origin", project.baseBranch], cwd: path)
    let ancestor = try await CommandRunner.run(
      "/usr/bin/git", ["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], cwd: path)
    if ancestor.status == 0 { return false }
    guard ancestor.status == 1 else { throw ScreenClipError.message(ancestor.error) }
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["merge", "--no-edit", "FETCH_HEAD"], cwd: path)
    return true
  }
  public static func repositoryIsPublic(_ repo: String, gh: String, cwd: String) async -> Bool? {
    guard
      let text = try? await CommandRunner.checked(
        gh, ["repo", "view", repo, "--json", "isPrivate"], cwd: cwd),
      let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
      let isPrivate = json["isPrivate"].bool
    else { return nil }
    return !isPrivate
  }
  public static func pullRequests(head: String, gh: String, cwd: String) async throws
    -> [ExternalPullRequestCandidate]
  {
    let text = try await CommandRunner.checked(
      gh,
      ["pr", "list", "--head", head, "--state", "all", "--json", "url,headRefName,body,state"],
      cwd: cwd)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).array.map {
      ExternalPullRequestCandidate(
        url: $0["url"].string ?? "", headRefName: $0["headRefName"].string ?? "",
        body: $0["body"].string ?? "", state: $0["state"].string ?? "")
    }
  }
  public static func listScreenclipPaths(revision: String, cwd: String) async throws -> [String] {
    let result = try await CommandRunner.run(
      "/usr/bin/git", ["ls-tree", "-r", "--name-only", revision, "--", ".screenclip"], cwd: cwd)
    guard result.status == 0 else {
      throw ScreenClipError.message(result.error.isEmpty ? result.output : result.error)
    }
    return result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }
  public static func commitEvidence(directory: String, message: String, cwd: String) async throws
    -> String
  {
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "--", directory], cwd: cwd)
    let status = try await CommandRunner.checked(
      "/usr/bin/git", ["status", "--porcelain", "--", directory], cwd: cwd)
    if !status.isEmpty {
      _ = try await CommandRunner.checked("/usr/bin/git", ["commit", "-m", message], cwd: cwd)
    }
    return try await CommandRunner.checked("/usr/bin/git", ["rev-parse", "HEAD"], cwd: cwd)
  }
  public static func pushBranch(_ branch: String, cwd: String) async throws {
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["push", "-u", "origin", branch], cwd: cwd)
  }
  /// Fast-forward onto the remote branch when it exists. A missing remote branch is the first push.
  public static func integrateRemoteBranch(_ branch: String, cwd: String) async throws {
    let fetch = try await CommandRunner.run(
      "/usr/bin/git", ["fetch", "origin", branch], cwd: cwd)
    guard fetch.status == 0 else { return }
    try await fastForwardToFetchHead(cwd: cwd)
  }
  public static func remoteContains(commit: String, branch: String, cwd: String) async throws -> Bool
  {
    let fetch = try await CommandRunner.run(
      "/usr/bin/git", ["fetch", "origin", branch], cwd: cwd)
    guard fetch.status == 0 else { return false }
    let ancestor = try await CommandRunner.run(
      "/usr/bin/git", ["merge-base", "--is-ancestor", commit, "FETCH_HEAD"], cwd: cwd)
    return ancestor.status == 0
  }
  public static func fastForwardToFetchHead(cwd: String) async throws {
    let ahead = try await CommandRunner.checked(
      "/usr/bin/git", ["rev-list", "--count", "FETCH_HEAD..HEAD"], cwd: cwd)
    let behind = try await CommandRunner.checked(
      "/usr/bin/git", ["rev-list", "--count", "HEAD..FETCH_HEAD"], cwd: cwd)
    guard (Int(behind) ?? 0) > 0 else { return }
    guard (Int(ahead) ?? 0) == 0 else {
      throw ScreenClipError.message(
        "The evidence branch has diverged from GitHub. ScreenClip did not overwrite either side.")
    }
    let dirty = try await CommandRunner.checked(
      "/usr/bin/git", ["status", "--porcelain"], cwd: cwd)
    guard dirty.isEmpty else {
      throw ScreenClipError.message(
        "The evidence worktree has uncommitted changes, so ScreenClip did not update it to the pull request."
      )
    }
    let fastForward = try await CommandRunner.run(
      "/usr/bin/git", ["merge", "--ff-only", "FETCH_HEAD"], cwd: cwd)
    if fastForward.status != 0 {
      _ = try await CommandRunner.checked(
        "/usr/bin/git", ["reset", "--hard", "FETCH_HEAD"], cwd: cwd)
    }
  }
}
