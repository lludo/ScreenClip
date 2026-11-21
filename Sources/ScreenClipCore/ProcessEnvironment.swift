import Darwin
import Foundation

/// Environment for child processes ScreenClip launches.
public enum ProcessEnvironment {
  static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  /// Variables that would redirect git to another repository or index.
  static let gitRedirects = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"]
  /// Credentials a coding agent never needs: ScreenClip pushes and opens PRs itself.
  static let agentSecrets = [
    "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
    "SCREENCLIP_NOTARY_PROFILE",
  ]
  /// Per-user install folders for agent CLIs and the `node` runtime npm installs need.
  /// An app opened from Finder does not inherit the PATH a Terminal shell sets up.
  static func userToolDirectories(home: String = NSHomeDirectory()) -> [String] {
    [
      "/.local/bin", "/.claude/local", "/.bun/bin", "/.volta/bin", "/.npm-global/bin",
      "/.local/share/mise/shims", "/.asdf/shims", "/Library/pnpm",
    ].map { home + $0 }
  }
  private static let loginState = LoginPathState()

  /// Writing to a pipe whose reader exited (an agent that quit before reading its prompt)
  /// raises SIGPIPE, which terminates the whole app by default. Ignore it so the write
  /// fails with EPIPE instead.
  public static func ignoreBrokenPipes() {
    signal(SIGPIPE, SIG_IGN)
  }

  /// Reads the PATH the user's login shell sets up (nvm, Volta, asdf and similar tools
  /// configure it there), once per launch. Later calls return immediately.
  public static func loadLoginShellPath() async {
    guard loginState.beginLoading() else { return }
    let inherited = ProcessInfo.processInfo.environment
    let shell =
      inherited["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
      ?? "/bin/zsh"
    let marker = "__SCREENCLIP_PATH__"
    // -i reads ~/.zshrc, where version managers usually add themselves. stdin is closed and
    // the run is time limited, so a prompt in a shell profile cannot hang ScreenClip.
    let result = try? await CommandRunner.run(
      shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 5,
      environment: inherited)
    loginState.finish(result.flatMap { extractPath(from: $0.output, marker: marker) })
  }

  static func extractPath(from output: String, marker: String) -> String? {
    let parts = output.components(separatedBy: marker)
    guard parts.count >= 3 else { return nil }
    let path = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  /// ScreenClip's search path: system and Homebrew folders, per-user tool folders that
  /// exist, the login shell's PATH, then the inherited PATH, without duplicates.
  static func path(base: String?, login: String? = nil) -> String {
    var seen = Set<String>()
    let existing = userToolDirectories().filter { FileManager.default.fileExists(atPath: $0) }
    let loginPath = login ?? loginState.path ?? ""
    var entries: [String] = searchPath.split(separator: ":").map(String.init)
    entries.append(contentsOf: existing)
    entries.append(contentsOf: loginPath.split(separator: ":").map(String.init))
    entries.append(contentsOf: (base ?? "").split(separator: ":").map(String.init))
    return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
  }

  /// The first executable named `name` on ScreenClip's search path.
  public static func executable(named name: String) -> String? {
    path(base: ProcessInfo.processInfo.environment["PATH"]).split(separator: ":")
      .map { String($0) + "/" + name }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// For ScreenClip's own tools (git, gh, validation commands).
  public static func tools(_ base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    var environment = base
    environment["PATH"] = path(base: base["PATH"])
    for key in gitRedirects { environment.removeValue(forKey: key) }
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GH_PROMPT_DISABLED"] = "1"
    return environment
  }

  /// For a coding agent: tools environment without GitHub credentials or a parent
  /// Claude Code session's identity.
  public static func agent(_ base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    var environment = tools(base)
    for key in agentSecrets { environment.removeValue(forKey: key) }
    for key in environment.keys
    where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_SESSION") {
      environment.removeValue(forKey: key)
    }
    return environment
  }
}

private final class LoginPathState: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var value: String?
  func beginLoading() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if started { return false }
    started = true
    return true
  }
  func finish(_ path: String?) {
    lock.lock()
    value = path
    lock.unlock()
  }
  var path: String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
