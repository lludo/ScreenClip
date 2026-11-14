import Foundation

/// What ScreenClip found for one local coding agent.
public struct AgentDetection: Identifiable, Equatable, Sendable {
  public var kind: AgentKind
  public var path: String
  public var version: String?
  /// nil when the agent's sign-in is checked elsewhere (Codex uses app-server).
  public var signedIn: Bool?
  public var detail: String
  public var id: AgentKind { kind }
  public var installed: Bool { version != nil }
  public var usable: Bool { installed && signedIn != false }
  public init(
    kind: AgentKind, path: String, version: String?, signedIn: Bool?, detail: String
  ) {
    self.kind = kind
    self.path = path
    self.version = version
    self.signedIn = signedIn
    self.detail = detail
  }
  public var label: String {
    guard installed else { return "\(kind.title) — not found" }
    if signedIn == false { return "\(kind.title) — signed out" }
    return kind.title
  }
}

public enum AgentDetector {
  public static func defaultCodexPath(fileManager: FileManager = .default) -> String {
    // App-bundled runtime is an optional local-development fallback, never copied or redistributed.
    let candidates = [
      "/usr/local/bin/codex", "/opt/homebrew/bin/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
    ]
    return candidates.first(where: { path in
      guard fileManager.isExecutableFile(atPath: path) else { return false }
      // An npm launcher can exist without its native dependency. Prefer the verified runtime in that case.
      if path == "/opt/homebrew/bin/codex",
        !fileManager.fileExists(
          atPath:
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
        )
      {
        return false
      }
      return true
    }) ?? ""
  }

  public static func defaultClaudePath(fileManager: FileManager = .default) -> String {
    let home = fileManager.homeDirectoryForCurrentUser.path
    let candidates = [
      "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude",
      home + "/.claude/local/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude",
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0) } ?? ""
  }

  public static func claudePath(_ settings: AppSettings) -> String {
    let configured = settings.claudePath?.trimmingCharacters(in: .whitespaces) ?? ""
    return configured.isEmpty ? defaultClaudePath() : configured
  }

  public static func codexPath(_ settings: AppSettings) -> String {
    settings.codexPath.isEmpty ? defaultCodexPath() : settings.codexPath
  }

  public static func detectAll(_ settings: AppSettings) async -> [AgentDetection] {
    async let codex = detectCodex(path: codexPath(settings))
    async let claude = detectClaude(path: claudePath(settings))
    return await [codex, claude]
  }

  public static func detectCodex(path: String) async -> AgentDetection {
    guard let version = await version(path) else {
      return AgentDetection(
        kind: .codex, path: path, version: nil, signedIn: nil,
        detail: path.isEmpty ? "Codex CLI not found." : "Codex at \(path) did not respond.")
    }
    return AgentDetection(
      kind: .codex, path: path, version: version, signedIn: nil, detail: "Codex \(version)")
  }

  public static func detectClaude(path: String) async -> AgentDetection {
    guard let version = await version(path) else {
      return AgentDetection(
        kind: .claude, path: path, version: nil, signedIn: nil,
        detail: path.isEmpty
          ? "Claude Code CLI not found. Install it from claude.com/claude-code."
          : "Claude Code at \(path) did not respond.")
    }
    let status = try? await CommandRunner.run(path, ["auth", "status"], timeout: 15)
    let auth = status.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.output.utf8)) }
    let signedIn = auth?["loggedIn"].bool
    let method = auth?["authMethod"].string
    let detail: String
    switch signedIn {
    case true?: detail = "Claude Code \(version), signed in" + (method.map { " (\($0))" } ?? "")
    case false?: detail = "Claude Code \(version) is signed out. Use Sign in to Claude."
    case nil: detail = "Claude Code \(version); sign-in status unavailable."
    }
    return AgentDetection(
      kind: .claude, path: path, version: version, signedIn: signedIn, detail: detail)
  }

  private static func version(_ path: String) async -> String? {
    guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path),
      let result = try? await CommandRunner.run(path, ["--version"], timeout: 15),
      result.status == 0
    else { return nil }
    let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    // "2.1.128 (Claude Code)" or "codex-cli 0.50.0"
    let token = text.split(whereSeparator: \.isWhitespace).first {
      $0.first?.isNumber == true
    }
    return token.map(String.init) ?? (text.isEmpty ? "unknown" : String(text.prefix(40)))
  }
}
