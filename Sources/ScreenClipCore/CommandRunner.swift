import CryptoKit
import Foundation

public struct CommandResult {
  public let output: String
  public let error: String
  public let status: Int32
}
public enum CommandRunner {
  public static func run(
    _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 120
  ) async throws -> CommandResult {
    try await Task.detached(priority: .utility) {
      try runBlocking(executable, arguments, cwd: cwd, timeout: timeout)
    }.value
  }
  private static func runBlocking(
    _ executable: String, _ arguments: [String], cwd: String?, timeout: TimeInterval
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] =
      "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
      + (environment["PATH"] ?? "")
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GH_PROMPT_DISABLED"] = "1"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    let group = DispatchGroup()
    let out = DataBox()
    let err = DataBox()
    try process.run()
    group.enter()
    DispatchQueue.global().async {
      out.data = stdout.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      err.data = stderr.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
      process.terminate()
      throw ScreenClipError.message(
        "Command timed out: \(URL(fileURLWithPath: executable).lastPathComponent)")
    }
    process.waitUntilExit()
    group.wait()
    return CommandResult(
      output: String(decoding: out.data, as: UTF8.self),
      error: String(decoding: err.data, as: UTF8.self), status: process.terminationStatus)
  }
  public static func checked(
    _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 120
  ) async throws -> String {
    let result = try await run(executable, arguments, cwd: cwd, timeout: timeout)
    guard result.status == 0 else {
      throw ScreenClipError.message(
        String((result.error.isEmpty ? result.output : result.error).suffix(4000)))
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
private final class DataBox: @unchecked Sendable { var data = Data() }

public enum GitWorkspace {
  public static func fingerprint(path: String) async throws -> String {
    let listing = try await CommandRunner.checked(
      "/usr/bin/git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd: path)
    var hash = SHA256()
    for name in Set(listing.split(separator: "\0").map(String.init)).sorted() {
      let file = URL(fileURLWithPath: path).appendingPathComponent(name)
      hash.update(data: Data(name.utf8))
      hash.update(data: Data([0]))
      if !FileManager.default.fileExists(atPath: file.path) {
        hash.update(data: Data("deleted".utf8))
        continue
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        hash.update(
          data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
      } else if attributes[.type] as? FileAttributeType == .typeDirectory {
        // Git submodules are recorded by their checked-out revision.
        hash.update(
          data: Data(
            try await CommandRunner.checked("/usr/bin/git", ["rev-parse", "HEAD"], cwd: file.path)
              .utf8))
      } else {
        hash.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
      }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func prepare(project: Project, issueID: UUID, root: URL) async throws -> (
    path: String, branch: String
  ) {
    let branch = "codex/screenclip-" + issueID.uuidString.lowercased().prefix(8)
    let path = root.appendingPathComponent("worktrees").appendingPathComponent(issueID.uuidString)
      .path
    let repo = try await CommandRunner.checked(
      "/usr/bin/git", ["rev-parse", "--show-toplevel"], cwd: project.path)
    guard
      URL(fileURLWithPath: repo).standardizedFileURL.path
        == URL(fileURLWithPath: project.path).standardizedFileURL.path
    else { throw ScreenClipError.message("Choose the repository root for \(project.name).") }
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["check-ref-format", "--branch", project.baseBranch], cwd: project.path)
    if FileManager.default.fileExists(atPath: path) {
      let actual = try await CommandRunner.checked(
        "/usr/bin/git", ["branch", "--show-current"], cwd: path)
      guard actual == branch else {
        throw ScreenClipError.message(
          "The issue worktree has an unexpected branch. Inspect it before retrying.")
      }
      return (path, String(branch))
    }
    _ = try await CommandRunner.checked(
      "/usr/bin/git", ["worktree", "add", "-b", String(branch), path, project.baseBranch],
      cwd: project.path)
    return (path, String(branch))
  }
}
