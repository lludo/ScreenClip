import Foundation

/// Ad-hoc signed and launched under App Sandbox by scripts/sandbox-diagnostic.sh.
/// Prints one `key=value` line per check. Denials are results, not crashes.
@main
enum SandboxDiag {
  static func main() {
    let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none"
    line("sandbox_container", container)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    line("home", home)
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    line("application_support", support.path)
    line("read_home", probe {
      _ = try FileManager.default.contentsOfDirectory(atPath: home)
      return "allowed"
    })
    line("read_gitconfig", probe {
      _ = try Data(contentsOf: URL(fileURLWithPath: home + "/.gitconfig"))
      return "allowed"
    })
    let probeFile = home + "/screenclip-sandbox-probe.txt"
    line("write_home", probe {
      try Data("x".utf8).write(to: URL(fileURLWithPath: probeFile))
      try? FileManager.default.removeItem(atPath: probeFile)
      return "allowed"
    })
    line("bin_echo", run("/bin/echo", ["ok"]))
    line("usr_bin_git", run("/usr/bin/git", ["--version"]))
    line("opt_homebrew_git_visible", visibility("/opt/homebrew/bin/git"))
    line("opt_homebrew_git", run("/opt/homebrew/bin/git", ["--version"]))
    line("opt_homebrew_gh_visible", visibility("/opt/homebrew/bin/gh"))
    line("opt_homebrew_gh", run("/opt/homebrew/bin/gh", ["--version"]))
    line("usr_local_bin_git", run("/usr/local/bin/git", ["--version"]))
    let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "sandbox-repo-" + UUID().uuidString)
    line("temp_dir", NSTemporaryDirectory())
    line("git_init_in_temp", {
      do {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        return run("/usr/bin/git", ["init"], cwd: repo.path)
      } catch {
        return "mkdir_denied " + brief(error)
      }
    }())
  }

  static func line(_ key: String, _ value: String) {
    print("\(key)=\(value.replacingOccurrences(of: "\n", with: " "))")
    fflush(stdout)
  }

  static func brief(_ error: Error) -> String {
    String(String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(180))
  }

  static func probe(_ body: () throws -> String) -> String {
    do { return try body() } catch { return "denied " + brief(error) }
  }

  static func visibility(_ path: String) -> String {
    guard FileManager.default.fileExists(atPath: path) else { return "missing" }
    return FileManager.default.isReadableFile(atPath: path) ? "readable" : "present-unreadable"
  }

  static func run(_ path: String, _ arguments: [String], cwd: String? = nil) -> String {
    guard FileManager.default.fileExists(atPath: path) else { return "missing" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return "launch_failed " + brief(error) }
    if finished.wait(timeout: .now() + 8) == .timedOut {
      process.terminate()
      return "timeout"
    }
    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let text = (out + " " + err).replacingOccurrences(of: "\n", with: " ")
    return "status \(process.terminationStatus) " + String(text.prefix(180))
  }
}
