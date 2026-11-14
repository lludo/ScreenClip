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

  /// For ScreenClip's own tools (git, gh, validation commands).
  public static func tools(_ base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    var environment = base
    environment["PATH"] = searchPath + ":" + (base["PATH"] ?? "")
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
