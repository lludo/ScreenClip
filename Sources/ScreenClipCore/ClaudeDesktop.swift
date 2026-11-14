import Foundation

/// Whether a `claude` executable can hand a session to the Claude desktop app
/// (`claude --desktop --resume <id>`, Claude Code 2.1.285 or newer).
public enum ClaudeDesktopSupport: Equatable, Sendable {
  case supported(version: String)
  case unsupported(version: String)
  /// The version could not be read; fall back to the Terminal command.
  case unknown

  public static let minimumVersion = [2, 1, 285]

  /// Parses the leading `major.minor.patch` of `claude --version` output ("2.1.325 (Claude Code)").
  public static func version(from output: String) -> [Int]? {
    guard let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
      return nil
    }
    let parts = output[match].split(separator: ".").compactMap { Int($0) }
    return parts.count == 3 ? parts : nil
  }

  public static func classify(versionOutput: String) -> ClaudeDesktopSupport {
    guard let parts = version(from: versionOutput) else { return .unknown }
    let text = parts.map(String.init).joined(separator: ".")
    return parts.lexicographicallyPrecedes(minimumVersion)
      ? .unsupported(version: text) : .supported(version: text)
  }
}

extension ClaudeCodeClient {
  /// Arguments after the executable. The CLI refuses redirected output, so the caller
  /// runs it under a pseudo-terminal (see `openInDesktop`).
  public static func desktopArguments(sessionID: String) -> [String] {
    ["--desktop", "--resume", sessionID]
  }

  public func desktopSupport(executable: String) async -> ClaudeDesktopSupport {
    guard FileManager.default.isExecutableFile(atPath: executable),
      let result = try? await CommandRunner.run(
        executable, ["--version"], timeout: 15, environment: ProcessEnvironment.agent()),
      result.status == 0
    else { return .unknown }
    return ClaudeDesktopSupport.classify(versionOutput: result.output)
  }

  /// Opens an existing session in Claude Desktop. Refuses while any process is running the
  /// session, so Desktop and ScreenClip never edit it at once. Throws a user-readable message
  /// when the CLI is too old, so callers can offer the Terminal command instead.
  public func openInDesktop(executable: String, cwd: String, sessionID: String) async throws {
    guard UUID(uuidString: sessionID) != nil else {
      throw ScreenClipError.message("This report has no valid Claude Code session yet.")
    }
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw ScreenClipError.message("Choose a working Claude Code executable in Settings.")
    }
    switch await desktopSupport(executable: executable) {
    case .unsupported(let version):
      throw ScreenClipError.message(
        "Claude Code \(version) cannot open Claude Desktop. Version 2.1.285 or newer is required; "
          + "copy the Terminal command instead.")
    case .unknown:
      throw ScreenClipError.message(
        "Could not read the Claude Code version. Copy the Terminal command instead.")
    case .supported: break
    }
    if try await sessionIsRunning(sessionID: sessionID) {
      throw ScreenClipError.message(
        "This Claude Code session is still running. Wait or cancel it before opening it in Claude Desktop.")
    }
    // `script` supplies the terminal the CLI requires; its output is not a TTY for us.
    let result = try await CommandRunner.run(
      "/usr/bin/script", ["-q", "/dev/null", executable] + Self.desktopArguments(sessionID: sessionID),
      cwd: cwd, timeout: 60, environment: ProcessEnvironment.agent())
    let text = result.output.replacingOccurrences(of: "\u{04}", with: "")
      .replacingOccurrences(of: "\u{8}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.status == 0, text.contains("Opening session") else {
      let detail = (result.error.isEmpty ? text : result.error)
      throw ScreenClipError.message(
        "Claude Desktop did not open the session"
          + (detail.isEmpty ? "." : ": " + String(detail.suffix(500))))
    }
  }
}
