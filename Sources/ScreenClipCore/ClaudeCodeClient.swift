import Foundation
import os

/// One headless Claude Code turn for an issue.
public struct ClaudeTurnRequest: Sendable {
  public var executable: String
  public var cwd: String
  public var sessionID: String
  /// Resume `sessionID` instead of creating it.
  public var resume: Bool
  public var name: String?
  public var model: String?
  /// `--effort` level. Nil keeps the model's default.
  public var effort: String?
  public var prompt: String
  public var images: [Data]
  public var schema: JSONValue
  /// A turn running longer than this is terminated.
  public var timeout: TimeInterval = 45 * 60
  public init(
    executable: String, cwd: String, sessionID: String, resume: Bool, name: String? = nil,
    model: String? = nil, effort: String? = nil, prompt: String, images: [Data],
    schema: JSONValue
  ) {
    self.executable = executable
    self.cwd = cwd
    self.sessionID = sessionID
    self.resume = resume
    self.name = name
    self.model = model
    self.effort = effort
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
  private var timedOut = Set<String>()
  public init() { ProcessEnvironment.ignoreBrokenPipes() }

  /// Prefer sandboxed Bash. Auto mode reviews extra access (including unsandboxed
  /// retries for builds and dependency tools) instead of denying every headless ask.
  public static let sandboxSettings: JSONValue = .object([
    "sandbox": .object([
      "enabled": .bool(true), "autoAllowBashIfSandboxed": .bool(true),
      "allowUnsandboxedCommands": .bool(true),
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
    arguments += ["--permission-mode", "auto"]
    arguments += request.resume ? ["--resume", request.sessionID] : ["--session-id", request.sessionID]
    if let name = request.name, !name.isEmpty { arguments += ["--name", name] }
    if let model = request.model, !model.isEmpty { arguments += ["--model", model] }
    if let effort = request.effort, !effort.isEmpty { arguments += ["--effort", effort] }
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
    process.environment = ProcessEnvironment.agent()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let errors = StderrBuffer()
    let exit = ExitSignal()
    let output = Self.stream(stdout)
    let errorOutput = Self.stream(stderr)
    // A process Claude started can inherit its pipes and keep them open after Claude exits.
    // Stop reading shortly after exit instead of waiting for an end of file that never comes.
    let grace = Self.drainGrace
    process.terminationHandler = { _ in
      exit.signal()
      DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
        output.stop()
        errorOutput.stop()
      }
    }
    do {
      try process.run()
    } catch {
      output.stop()
      errorOutput.stop()
      throw error
    }
    let errorReader = Task.detached {
      for await chunk in errorOutput.chunks { errors.append(chunk) }
    }
    processes[request.sessionID] = process
    let pid = process.processIdentifier
    Self.live.withLock { $0.insert(pid) }
    defer {
      processes.removeValue(forKey: request.sessionID)
      Self.live.withLock { _ = $0.remove(pid) }
    }
    var line = Self.userMessage(for: request).data
    line.append(10)
    // Screenshots can make this several megabytes; write off the actor so cancel() stays responsive.
    // SIGPIPE is ignored, so a Claude that exits early makes this write fail instead of the app.
    let input = stdin.fileHandleForWriting
    Task.detached {
      try? input.write(contentsOf: line)
      try? input.close()
    }
    let session = request.sessionID
    let watchdog = Task { [weak self] in
      try await Task.sleep(nanoseconds: UInt64(max(1, request.timeout) * 1_000_000_000))
      await self?.expire(sessionID: session)
    }
    defer { watchdog.cancel() }

    var result: ClaudeTurnResult?
    var sessionID: String?
    var buffer = Data()
    var chunks = output.chunks.makeAsyncIterator()
    while true {
      let data = await chunks.next() ?? Data()
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
    await exit.wait()
    await errorReader.value
    if timedOut.remove(request.sessionID) != nil {
      throw ScreenClipError.message(
        "Claude Code did not finish within \(Int(request.timeout / 60)) minutes and was stopped.")
    }
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

  /// How long to keep reading after Claude exits, and how long Claude gets to save its
  /// session after SIGTERM before it and the processes it started are killed.
  static let drainGrace: TimeInterval = 3

  private func expire(sessionID: String) {
    guard let process = processes[sessionID] else { return }
    timedOut.insert(sessionID)
    Self.stop(process)
  }

  public func cancel(sessionID: String) {
    guard let process = processes[sessionID] else { return }
    canceled.insert(sessionID)
    Self.stop(process)
  }

  private static let live = OSAllocatedUnfairLock(initialState: Set<pid_t>())

  /// Stops every running turn before the app exits. A turn cannot report to a quit app, and
  /// an orphan would keep editing the worktree and block the session after relaunch.
  public static func terminateAllForQuit(grace: TimeInterval = 2) {
    let pids = live.withLock { $0 }
    guard !pids.isEmpty else { return }
    let group = DispatchGroup()
    for pid in pids {
      DispatchQueue.global(qos: .userInitiated).async(group: group) {
        CommandRunner.terminateTree(pid, grace: grace)
      }
    }
    group.wait()
  }

  /// SIGTERM Claude and everything it started, then SIGKILL whatever ignores it.
  private static func stop(_ process: Process) {
    let pid = process.processIdentifier
    DispatchQueue.global(qos: .userInitiated).async {
      CommandRunner.terminateTree(pid, grace: drainGrace)
    }
  }

  /// Delivers a pipe's output as chunks until end of file or `stop()`.
  private static func stream(_ pipe: Pipe) -> PipeStream {
    let (chunks, continuation) = AsyncStream<Data>.makeStream()
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        continuation.finish()
      } else {
        continuation.yield(chunk)
      }
    }
    return PipeStream(chunks: chunks) {
      handle.readabilityHandler = nil
      continuation.finish()
    }
  }

  public func isRunning(sessionID: String) -> Bool { processes[sessionID] != nil }

  /// A child can survive a ScreenClip crash, or be resumed in Terminal. Check
  /// those processes before allowing a recovered session to run again.
  public func sessionIsRunning(sessionID: String) async throws -> Bool {
    if processes[sessionID] != nil { return true }
    let listing = try await CommandRunner.checked("/bin/ps", ["-axww", "-o", "command="])
    let pattern = "(?:--session-id|--resume)(?:=|\\s+)"
      + NSRegularExpression.escapedPattern(for: sessionID) + "(?=\\s|$)"
    return processes[sessionID] != nil || listing.split(separator: "\n").contains {
      $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }
}

private struct PipeStream: Sendable {
  let chunks: AsyncStream<Data>
  let stop: @Sendable () -> Void
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

/// Resumes waiters once the process terminates, without blocking a thread in waitUntilExit.
private final class ExitSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var exited = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func signal() {
    lock.lock()
    exited = true
    let pending = waiters
    waiters = []
    lock.unlock()
    pending.forEach { $0.resume() }
  }
  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if exited {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}
