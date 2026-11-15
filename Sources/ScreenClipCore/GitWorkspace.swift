import CryptoKit
import Foundation

/// Local Git work for an issue: its isolated worktree, source fingerprint, validation,
/// and base-branch updates. GitHub calls live in `GitHubService`.
public enum GitWorkspace {
  public static let git = "/usr/bin/git"
  public static let branchPrefix = "screenclip/"
  /// Branch names created before the prefix became agent-neutral.
  static let legacyBranchPrefix = "codex/screenclip-"

  public static func branchName(issueID: UUID) -> String {
    branchPrefix + issueID.uuidString.lowercased().prefix(8)
  }

  public static func fingerprint(path: String) async throws -> String {
    let listing = try await CommandRunner.run(
      git, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd: path)
    guard listing.status == 0 else { throw ScreenClipError.message(listing.error) }
    var hash = SHA256()
    for name in Set(listing.output.split(separator: "\0").map(String.init)).sorted() {
      let file = URL(fileURLWithPath: path).appendingPathComponent(name)
      hash.update(data: Data(name.utf8))
      hash.update(data: Data([0]))
      let attributes: [FileAttributeKey: Any]
      do {
        attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      } catch CocoaError.fileReadNoSuchFile {
        hash.update(data: Data("deleted".utf8))
        continue
      }
      hash.update(data: Data(String(describing: attributes[.posixPermissions]).utf8))
      if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        hash.update(
          data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
      } else if attributes[.type] as? FileAttributeType == .typeDirectory {
        hash.update(data: Data(try await submoduleRevision(file.path).utf8))
      } else {
        hash.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
      }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// A checked-out submodule is identified by its HEAD. `git worktree add` leaves
  /// submodules uninitialized, and running rev-parse in an empty directory would walk up
  /// and return the worktree's own HEAD, which changes when ScreenClip commits.
  static func submoduleRevision(_ path: String) async throws -> String {
    let top = try await CommandRunner.run(git, ["rev-parse", "--show-toplevel"], cwd: path)
    guard top.status == 0,
      canonical(top.output.trimmingCharacters(in: .whitespacesAndNewlines)) == canonical(path)
    else { return "uninitialized-submodule" }
    return try await CommandRunner.checked(git, ["rev-parse", "HEAD"], cwd: path)
  }

  static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// The ref an issue branch starts from and is compared against: the remote base when the
  /// repository has an origin, so a tester's unpushed local commits never enter a PR.
  public static func baseRef(project: Project, path: String) async -> String {
    let remote = try? await CommandRunner.run(
      git, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + project.baseBranch],
      cwd: path)
    return remote?.status == 0 ? "origin/" + project.baseBranch : project.baseBranch
  }

  /// Pass `branch` to use a specific branch name (Grok Bot handoffs). An existing local
  /// branch is checked out instead of being created from the base.
  public static func prepare(
    project: Project, issueID: UUID, root: URL, branch requestedBranch: String? = nil
  ) async throws -> (path: String, branch: String) {
    let branch = requestedBranch ?? branchName(issueID: issueID)
    let legacy = legacyBranchPrefix + issueID.uuidString.lowercased().prefix(8)
    let path = root.appendingPathComponent("worktrees").appendingPathComponent(issueID.uuidString)
      .path
    let repo = try await CommandRunner.checked(
      git, ["rev-parse", "--show-toplevel"], cwd: project.path)
    guard canonical(repo) == canonical(project.path) else {
      throw ScreenClipError.message("Choose the repository root for \(project.name).")
    }
    _ = try await CommandRunner.checked(
      git, ["check-ref-format", "--branch", project.baseBranch], cwd: project.path)
    if FileManager.default.fileExists(atPath: path) {
      let actual = try await CommandRunner.checked(git, ["branch", "--show-current"], cwd: path)
      guard actual == branch || (requestedBranch == nil && actual == legacy) else {
        throw ScreenClipError.message(
          "The issue worktree has an unexpected branch. Inspect it before retrying.")
      }
      return (path, actual)
    }
    // Start from the latest remote base when there is one; fall back to the local branch.
    let hasOrigin =
      (try? await CommandRunner.run(git, ["remote", "get-url", "origin"], cwd: project.path))?
      .status == 0
    if hasOrigin {
      try? await fetch(project.baseBranch, cwd: project.path)
    }
    let existing = try await CommandRunner.run(
      git, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: project.path)
    if existing.status == 0 {
      _ = try await CommandRunner.checked(
        git, ["worktree", "add", path, branch], cwd: project.path)
      return (path, branch)
    }
    let start = await baseRef(project: project, path: project.path)
    _ = try await CommandRunner.checked(
      git, ["worktree", "add", "-b", branch, path, start], cwd: project.path)
    return (path, branch)
  }

  /// Removes a finished issue's worktree and local branch. A worktree with uncommitted
  /// changes is kept (git refuses to remove it without --force).
  @discardableResult
  public static func remove(path: String, branch: String?, repository: String) async -> Bool {
    let removed = try? await CommandRunner.run(
      git, ["worktree", "remove", path], cwd: repository)
    guard removed?.status == 0 else { return false }
    if let branch, branch.hasPrefix(branchPrefix) || branch.hasPrefix(legacyBranchPrefix) {
      _ = try? await CommandRunner.run(git, ["branch", "-D", branch], cwd: repository)
    }
    return true
  }

  /// Deletes a merged issue branch from origin. Only ScreenClip's own branch prefixes are
  /// touched. For Grok Bot reports this also removes the pushed screenshots from the branch,
  /// though GitHub keeps pull request commits reachable.
  @discardableResult
  public static func deleteRemoteBranch(_ branch: String, repository: String) async -> Bool {
    guard branch.hasPrefix(branchPrefix) || branch.hasPrefix(legacyBranchPrefix) else {
      return false
    }
    let result = try? await CommandRunner.run(
      git, ["push", "origin", "--delete", branch], cwd: repository)
    return result?.status == 0
  }

  public static func validate(project: Project, path: String) async throws -> ValidationReceipt {
    guard !project.validationCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ScreenClipError.message(
        "Add a validation command in this project's settings before publishing a fix.")
    }
    let before = try await fingerprint(path: path)
    let result = try await CommandRunner.run(
      "/bin/zsh", ["-c", project.validationCommand], cwd: path, timeout: 600)
    let after = try await fingerprint(path: path)
    guard before == after else {
      throw ScreenClipError.message(
        "Source files changed during validation. Run the checks again before publishing.")
    }
    let head = try await CommandRunner.checked(git, ["rev-parse", "HEAD"], cwd: path)
    return ValidationReceipt(
      head: head, command: project.validationCommand, passed: result.status == 0, date: Date(),
      output: String((result.output + "\n" + result.error).suffix(8000)), fingerprint: after)
  }

  /// Fetches a branch from origin. Worktrees of one repository share remote refs, so parallel
  /// reports can collide on git's ref lock; that transient error is retried.
  public static func fetch(_ branch: String, cwd: String, attempts: Int = 4) async throws {
    for attempt in 1...max(1, attempts) {
      let result = try await CommandRunner.run(git, ["fetch", "origin", branch], cwd: cwd)
      if result.status == 0 { return }
      let message = result.error.isEmpty ? result.output : result.error
      let locked = message.contains("cannot lock ref") || message.contains(".lock")
      guard locked, attempt < attempts else {
        throw ScreenClipError.message(String(message.suffix(4000)))
      }
      try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
    }
  }

  /// Merges the latest remote base into the issue branch. Returns true when the base had
  /// advanced. A conflicted merge is aborted so the worktree is never left mid-merge.
  public static func updateBaseIfNeeded(project: Project, path: String) async throws -> Bool {
    try await fetch(project.baseBranch, cwd: path)
    let ancestor = try await CommandRunner.run(
      git, ["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], cwd: path)
    if ancestor.status == 0 { return false }
    guard ancestor.status == 1 else { throw ScreenClipError.message(ancestor.error) }
    let merge = try await CommandRunner.run(git, ["merge", "--no-edit", "FETCH_HEAD"], cwd: path)
    guard merge.status == 0 else {
      _ = try? await CommandRunner.run(git, ["merge", "--abort"], cwd: path)
      throw ScreenClipError.message(
        "The base branch conflicts with this fix: "
          + String((merge.error.isEmpty ? merge.output : merge.error).suffix(2000)))
    }
    return true
  }
}
