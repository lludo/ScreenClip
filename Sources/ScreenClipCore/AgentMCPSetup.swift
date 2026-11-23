import Foundation

/// Registers ScreenClip's read-only MCP server with a coding agent, so a session in any
/// project can ask which of its reports are open, in progress, or blocked.
///
/// The server script ships in the app bundle and is copied into the data folder, so the
/// path an agent stores survives app updates and moving the app.
public enum AgentMCPSetup {
  public static let serverName = "screenclip"
  /// Present on every Mac that can run `/usr/bin/git`, which ScreenClip already requires.
  public static let python = "/usr/bin/python3"

  /// The agents that run on this Mac and can launch a local server. Grok Bot runs in the cloud.
  public static let supportedAgents: [AgentKind] = [.claude, .codex]

  public static func serverURL(dataFolder: URL) -> URL {
    dataFolder.appendingPathComponent("mcp/server.py")
  }

  /// Copies the bundled server into the data folder, replacing an older copy.
  @discardableResult
  public static func prepareServer(
    from bundled: URL, dataFolder: URL, fileManager: FileManager = .default
  ) throws -> URL {
    let destination = serverURL(dataFolder: dataFolder)
    let contents = try Data(contentsOf: bundled)
    if (try? Data(contentsOf: destination)) != contents {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try contents.write(to: destination, options: .atomic)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    return destination
  }

  /// The data folder must be passed explicitly unless it is the default one the server assumes.
  static func environment(dataFolder: URL, home: URL) -> [String] {
    let standard = home.appendingPathComponent("Library/Application Support/ScreenClip")
    return dataFolder.standardizedFileURL.path == standard.standardizedFileURL.path
      ? [] : ["SCREENCLIP_DATA_DIR=\(dataFolder.path)"]
  }

  /// Arguments for the agent's own CLI, after its executable.
  public static func installArguments(
    _ kind: AgentKind, server: URL, dataFolder: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [String] {
    let environment = environment(dataFolder: dataFolder, home: home)
    switch kind {
    case .claude:
      return ["mcp", "add", "--scope", "user"] + environment.flatMap { ["-e", $0] }
        + [serverName, "--", python, server.path]
    case .codex:
      return ["mcp", "add"] + environment.flatMap { ["--env", $0] }
        + [serverName, "--", python, server.path]
    case .external:
      return []
    }
  }

  public static func removeArguments(_ kind: AgentKind) -> [String] {
    switch kind {
    case .claude: return ["mcp", "remove", "--scope", "user", serverName]
    case .codex: return ["mcp", "remove", serverName]
    case .external: return []
    }
  }

  /// The same command for Terminal, with the CLI's usual name.
  public static func terminalCommand(
    _ kind: AgentKind, server: URL, dataFolder: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String {
    let executable = kind == .codex ? "codex" : "claude"
    return ([executable] + installArguments(kind, server: server, dataFolder: dataFolder, home: home))
      .map(shellQuote).joined(separator: " ")
  }

  /// A configuration block for other MCP apps that read the common `mcpServers` JSON.
  public static func genericConfiguration(
    server: URL, dataFolder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String {
    var entry: [String: Any] = ["command": python, "args": [server.path]]
    let environment = environment(dataFolder: dataFolder, home: home)
    if !environment.isEmpty {
      entry["env"] = Dictionary(uniqueKeysWithValues: environment.map {
        let parts = $0.split(separator: "=", maxSplits: 1).map(String.init)
        return (parts[0], parts[1])
      })
    }
    let object = ["mcpServers": [serverName: entry]]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  /// Whether the agent's user-level configuration already has the server, read from its files
  /// so the check is instant and does not start any server.
  public static func isInstalled(
    _ kind: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    switch kind {
    case .claude:
      if let servers = jsonObject(home.appendingPathComponent(".claude.json"))?["mcpServers"]
        as? [String: Any], servers[serverName] != nil
      {
        return true
      }
      // The Claude Code plugin from this repository bundles the same server.
      let plugins = jsonObject(home.appendingPathComponent(".claude/settings.json"))?["enabledPlugins"]
        as? [String: Any]
      return plugins?.contains { $0.key.hasPrefix("\(serverName)@") && ($0.value as? Bool) == true }
        ?? false
    case .codex:
      guard
        let text = try? String(
          contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
      else { return false }
      return text.range(
        of: #"(?m)^\s*\[mcp_servers\.("?)screenclip\1\]\s*$"#, options: .regularExpression) != nil
    case .external:
      return false
    }
  }

  private static func jsonObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func shellQuote(_ value: String) -> String {
    if value.range(of: #"^[A-Za-z0-9_./=:@-]+$"#, options: .regularExpression) != nil {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
