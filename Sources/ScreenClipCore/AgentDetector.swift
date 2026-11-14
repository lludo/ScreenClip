import Foundation

/// What ScreenClip found for one coding agent.
/// Grok Bot is "installed" when its connection has been saved.
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
  public var label: String { kind.title }
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
    }) ?? ProcessEnvironment.executable(named: "codex") ?? ""
  }

  public static func defaultClaudePath(fileManager: FileManager = .default) -> String {
    let home = fileManager.homeDirectoryForCurrentUser.path
    let candidates = [
      "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude",
      home + "/.claude/local/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude",
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
      ?? ProcessEnvironment.executable(named: "claude") ?? ""
  }

  public static func claudePath(_ settings: AppSettings) -> String {
    let configured = settings.claudePath?.trimmingCharacters(in: .whitespaces) ?? ""
    return configured.isEmpty ? defaultClaudePath() : configured
  }

  public static func codexPath(_ settings: AppSettings) -> String {
    settings.codexPath.isEmpty ? defaultCodexPath() : settings.codexPath
  }

  public static func detectAll(
    _ settings: AppSettings, external: ExternalAssistantConfiguration = .empty
  ) async -> [AgentDetection] {
    // npm, nvm, Volta and bun installs live on the login shell's PATH, not Finder's.
    await ProcessEnvironment.loadLoginShellPath()
    async let codex = detectCodex(path: codexPath(settings))
    async let claude = detectClaude(path: claudePath(settings))
    let remote = detectExternal(external)
    return await [codex, claude, remote]
  }

  /// Connected means a usable address and secret are saved. The secret is never included here.
  public static func detectExternal(_ configuration: ExternalAssistantConfiguration) -> AgentDetection {
    guard configuration.isConfigured else {
      let started =
        !configuration.normalizedURL.isEmpty || !configuration.normalizedAuthorization.isEmpty
      return AgentDetection(
        kind: .external, path: "", version: nil, signedIn: false,
        detail: started
          ? ExternalConnectCode.Failure.invalidURL.message
          : ProviderPhrase.notConnected.english(.external)
      )
    }
    let host = configuration.endpoint?.host ?? ""
    let detail =
      host.isEmpty
      ? ProviderPhrase.ready.english(.external)
      : ProviderPhrase.readyDetail(kind: .external, extra: host)
    return AgentDetection(
      kind: .external, path: "", version: "configured", signedIn: true, detail: detail)
  }

  public static func detectCodex(path: String) async -> AgentDetection {
    guard canRun(path) else {
      return AgentDetection(
        kind: .codex, path: path, version: nil, signedIn: nil,
        detail: ProviderPhrase.notFound.english(.codex))
    }
    guard let version = await version(path) else {
      return AgentDetection(
        kind: .codex, path: path, version: nil, signedIn: nil,
        detail: ProviderPhrase.noResponse(kind: .codex, path: path))
    }
    return AgentDetection(
      kind: .codex, path: path, version: version, signedIn: nil,
      detail: ProviderPhrase.readyDetail(kind: .codex, extra: version))
  }

  public static func detectClaude(path: String) async -> AgentDetection {
    guard canRun(path) else {
      return AgentDetection(
        kind: .claude, path: path, version: nil, signedIn: nil,
        detail: ProviderPhrase.notFound.english(.claude))
    }
    guard let version = await version(path) else {
      return AgentDetection(
        kind: .claude, path: path, version: nil, signedIn: nil,
        detail: ProviderPhrase.noResponse(kind: .claude, path: path))
    }
    let status = try? await CommandRunner.run(path, ["auth", "status"], timeout: 15)
    let auth = status.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.output.utf8)) }
    let signedIn = auth?["loggedIn"].bool
    let detail: String
    switch signedIn {
    case false?: detail = ProviderPhrase.signInToStart.english(.claude)
    default: detail = ProviderPhrase.readyDetail(kind: .claude, extra: version)
    }
    return AgentDetection(
      kind: .claude, path: path, version: version, signedIn: signedIn, detail: detail)
  }

  /// Whether an agent's error means it is signed out rather than that the work failed.
  public static func isSignInError(_ text: String) -> Bool {
    let lower = text.lowercased()
    return [
      "not logged in", "please run /login", "invalid api key", "oauth token has expired",
      "authentication_error", "sign in to codex", "not signed in", "401 unauthorized",
    ].contains { lower.contains($0) }
  }

  /// A path that is missing or not executable has not been found. Only a real executable
  /// that fails `--version` is reported as not responding.
  private static func canRun(_ path: String) -> Bool {
    !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
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
