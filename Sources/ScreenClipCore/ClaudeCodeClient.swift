import Foundation

/// One headless Claude Code turn for an issue.
public struct ClaudeTurnRequest: Sendable {
  public var executable: String
  public var cwd: String
  public var sessionID: String
  /// Resume `sessionID` instead of creating it.
  public var resume: Bool
  public var name: String?
  public var model: String?
  public var prompt: String
  public var images: [Data]
  public var schema: JSONValue
  public init(
    executable: String, cwd: String, sessionID: String, resume: Bool, name: String? = nil,
    model: String? = nil, prompt: String, images: [Data], schema: JSONValue
  ) {
    self.executable = executable
    self.cwd = cwd
    self.sessionID = sessionID
    self.resume = resume
    self.name = name
    self.model = model
    self.prompt = prompt
    self.images = images
    self.schema = schema
  }
}

public struct ClaudeTurnResult: Sendable, Equatable {
  /// Schema-validated output when Claude Code returns it.
  public var structured: JSONValue?
  public var text: String
  public var sessionID: String?
  public var isError: Bool
  public var costUSD: Double?
  public var inputTokens: Int
  public var outputTokens: Int
  public var permissionDenials: [String]
  /// The structured result as JSON text, falling back to JSON found in the final message.
  public var outputJSON: String? {
    if let structured, structured != .null {
      return String(decoding: structured.data, as: UTF8.self)
    }
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("```") {
      body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        .joined(separator: "\n")
      if body.hasSuffix("```") { body = String(body.dropLast(3)) }
    }
    guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start <= end else {
      return nil
    }
    let candidate = String(body[start...end])
    return (try? JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8))) != nil
      ? candidate : nil
  }
  public var usageSummary: String {
    var parts = ["\(inputTokens.formatted()) in / \(outputTokens.formatted()) out tokens"]
    if let costUSD, costUSD > 0 { parts.append(String(format: "$%.2f", costUSD)) }
    return parts.joined(separator: " · ")
  }
}

/// Drives `claude -p` with stream-json input and output. One process per turn; the
/// session ID keeps a single Claude Code conversation per issue across turns.
public actor ClaudeCodeClient {
  private var processes: [String: Process] = [:]
  private var canceled = Set<String>()
  public init() {}

  /// Bash runs inside Claude Code's sandbox: writes stay in the worktree and the
  /// unsandboxed escape hatch is off, comparable to Codex's workspace-write mode.
  public static let sandboxSettings: JSONValue = .object([
    "sandbox": .object([
      "enabled": .bool(true), "autoAllowBashIfSandboxed": .bool(true),
      "allowUnsandboxedCommands": .bool(false),
    ])
  ])
  public static let disallowedTools = ["Bash(git push:*)", "Bash(gh:*)"]

  public static func arguments(for request: ClaudeTurnRequest) -> [String] {
    var arguments = [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--json-schema", String(decoding: request.schema.data, as: UTF8.self),
      "--settings", String(decoding: sandboxSettings.data, as: UTF8.self),
      "--disallowedTools",
    ]
    arguments += disallowedTools
    arguments += ["--permission-mode", "acceptEdits"]
    arguments += request.resume ? ["--resume", request.sessionID] : ["--session-id", request.sessionID]
    if let name = request.name, !name.isEmpty { arguments += ["--name", name] }
    if let model = request.model, !model.isEmpty { arguments += ["--model", model] }
    return arguments
  }

  public static func userMessage(for request: ClaudeTurnRequest) -> JSONValue {
    var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(request.prompt)])]
    for image in request.images {
      content.append(
        .object([
          "type": .string("image"),
          "source": .object([
            "type": .string("base64"), "media_type": .string("image/png"),
            "data": .string(image.base64EncodedString()),
          ]),
        ]))
    }
    return .object([
      "type": .string("user"),
      "message": .object(["role": .string("user"), "content": .array(content)]),
    ])
  }

  /// Runs a turn to completion. `progress` receives Claude's intermediate messages.
  public func run(
    _ request: ClaudeTurnRequest, progress: @escaping @Sendable (String) async -> Void
  ) async throws -> ClaudeTurnResult {
    guard FileManager.default.isExecutableFile(atPath: request.executable) else {
      throw ScreenClipError.message("Choose a working Claude Code executable in Settings.")
    }
    guard processes[request.sessionID] == nil else {
      throw ScreenClipError.message("This Claude Code session already has a running turn.")
    }
    canceled.remove(request.sessionID)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = Self.arguments(for: request)
    process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] =
      "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
    // Never inherit a parent Claude Code session's identity when ScreenClip is launched from one.
    for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_SESSION") {
      environment.removeValue(forKey: key)
    }
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let errors = StderrBuffer()
    stderr.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }
    try process.run()
    processes[request.sessionID] = process
    defer {
      stderr.fileHandleForReading.readabilityHandler = nil
      processes.removeValue(forKey: request.sessionID)
    }
    var line = Self.userMessage(for: request).data
    line.append(10)
    try? stdin.fileHandleForWriting.write(contentsOf: line)
    try? stdin.fileHandleForWriting.close()

    var result: ClaudeTurnResult?
    var sessionID: String?
    var buffer = Data()
    let reader = stdout.fileHandleForReading
    while true {
      let data = await Task.detached { reader.availableData }.value
      if data.isEmpty {
        if buffer.isEmpty { break }
        // EOF can terminate the last JSON record without a newline.
        buffer.append(10)
      } else {
        buffer.append(data)
      }
      while let newline = buffer.firstIndex(of: 10) {
        let raw = buffer[..<newline]
        buffer.removeSubrange(...newline)
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: raw) else { continue }
        switch message["type"].string {
        case "system":
          if message["subtype"].string == "init" { sessionID = message["session_id"].string }
        case "assistant":
          for block in message["message"]["content"].array
          where block["type"].string == "text" {
            if let text = block["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
            {
              await progress(text)
            }
          }
        case "result":
          result = Self.parseResult(message, sessionID: sessionID)
        default: break
        }
      }
      if data.isEmpty { break }
    }
    await Task.detached { process.waitUntilExit() }.value
    if canceled.remove(request.sessionID) != nil { throw CancellationError() }
    if let result, process.terminationStatus == 0 || result.isError { return result }
    let detail = errors.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = result == nil
      ? "without a result (status \(process.terminationStatus))"
      : "with status \(process.terminationStatus)"
    throw ScreenClipError.message(
      "Claude Code exited \(reason)"
        + (detail.isEmpty ? "." : ": " + String(detail.suffix(2000))))
  }

  public static func parseResult(_ message: JSONValue, sessionID: String?) -> ClaudeTurnResult {
    let usage = message["usage"]
    var cost: Double?
    if case .number(let value) = message["total_cost_usd"] { cost = value }
    let input =
      (usage["input_tokens"].int ?? 0) + (usage["cache_creation_input_tokens"].int ?? 0)
      + (usage["cache_read_input_tokens"].int ?? 0)
    let denials = message["permission_denials"].array.map { denial -> String in
      let tool = denial["tool_name"].string ?? "tool"
      let command = denial["tool_input"]["command"].string ?? denial["tool_input"]["file_path"].string
      return command.map { "\(tool): \($0)" } ?? tool
    }
    let structured = message["structured_output"]
    return ClaudeTurnResult(
      structured: structured == .null ? nil : structured, text: message["result"].string ?? "",
      sessionID: message["session_id"].string ?? sessionID,
      isError: message["is_error"].bool == true || message["subtype"].string?.hasPrefix("error") == true,
      costUSD: cost, inputTokens: input, outputTokens: usage["output_tokens"].int ?? 0,
      permissionDenials: denials)
  }

  public func cancel(sessionID: String) {
    guard let process = processes[sessionID] else { return }
    canceled.insert(sessionID)
    process.terminate()
  }

  public func isRunning(sessionID: String) -> Bool { processes[sessionID] != nil }
}

private final class StderrBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    data.append(chunk)
    if data.count > 64_000 { data.removeFirst(data.count - 64_000) }
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }
}
