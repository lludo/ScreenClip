import Foundation

public actor CodexClient {
  private var process: Process?
  private var input: FileHandle?
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var buffer = Data()
  private var continuation: AsyncStream<JSONValue>.Continuation?
  private var generation = UUID()
  private var ownedThreads = Set<String>()
  public init() {}
  deinit { process?.terminate() }
  public func connect(path: String) async throws -> AsyncStream<JSONValue> {
    stop()
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw ScreenClipError.message("Choose a working Codex executable in Settings.")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = ["app-server", "--listen", "stdio://"]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] =
      "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    proc.environment = env
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = stderr
    let token = UUID()
    generation = token
    let stream = AsyncStream<JSONValue> { continuation = $0 }
    proc.terminationHandler = { [weak self] _ in Task { await self?.disconnected(token: token) } }
    try proc.run()
    process = proc
    input = stdin.fileHandleForWriting
    Task.detached { [weak self] in
      while true {
        let data = stdout.fileHandleForReading.availableData
        if data.isEmpty { break }
        await self?.consume(data, token: token)
      }
    }
    Task.detached { while !stderr.fileHandleForReading.availableData.isEmpty {} }
    _ = try await request(
      "initialize",
      params: .object([
        "clientInfo": .object([
          "name": .string("screenclip"), "title": .string("ScreenClip"),
          "version": .string("0.1.5"),
        ]), "capabilities": .object(["experimentalApi": .bool(true)]),
      ]))
    try send(.object(["method": .string("initialized"), "params": .object([:])]))
    return stream
  }
  public func resumeThread(_ threadID: String, params: [String: JSONValue]) async throws -> JSONValue {
    if ownedThreads.contains(threadID) {
      return try await request("thread/read", params: .object(["threadId": .string(threadID)]))
    }
    var options = params
    options["threadId"] = .string(threadID)
    options["excludeTurns"] = .bool(true)
    do {
      return try await request("thread/resume", params: .object(options), timeout: 60)
    } catch {
      // A deliberate Continue action also restores a previously archived issue chat.
      guard error.localizedDescription.localizedCaseInsensitiveContains("archived") else { throw error }
      _ = try await request("thread/unarchive", params: .object(["threadId": .string(threadID)]))
      return try await request("thread/resume", params: .object(options), timeout: 60)
    }
  }
  public func request(_ method: String, params: JSONValue = .object([:]), timeout: UInt64 = 30)
    async throws -> JSONValue
  {
    let id = nextID
    nextID += 1
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try send(.object(["id": .number(Double(id)), "method": .string(method), "params": params]))
      } catch {
        pending.removeValue(forKey: id)?.resume(throwing: error)
        return
      }
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
        await self?.expire(id)
      }
    }
    if ["thread/start", "thread/resume"].contains(method), let threadID = result["thread"]["id"].string {
      ownedThreads.insert(threadID)
    }
    return result
  }
  public func respond(id: JSONValue, result: JSONValue) throws {
    try send(.object(["id": id, "result": result]))
  }
  public func reject(id: JSONValue, message: String) throws {
    try send(
      .object(["id": id, "error": .object(["code": .number(-32601), "message": .string(message)])]))
  }
  private func send(_ message: JSONValue) throws {
    guard let input, process?.isRunning == true else {
      throw ScreenClipError.message("Codex is disconnected.")
    }
    var data = message.data
    data.append(10)
    try input.write(contentsOf: data)
  }
  private func consume(_ data: Data, token: UUID) {
    guard token == generation else { return }
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 10) {
      let line = buffer[..<newline]
      buffer.removeSubrange(...newline)
      guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
      if let id = message["id"].int, message["method"].string == nil,
        let callback = pending.removeValue(forKey: id)
      {
        if message["error"] != .null {
          callback.resume(
            throwing: ScreenClipError.message(
              message["error"]["message"].string ?? "Codex request failed"))
        } else {
          callback.resume(returning: message["result"])
        }
      } else {
        continuation?.yield(message)
      }
    }
  }
  private func expire(_ id: Int) {
    pending.removeValue(forKey: id)?.resume(
      throwing: ScreenClipError.message(
        "Codex did not acknowledge the request. Check the existing chat before retrying."))
  }
  private func disconnected(token: UUID) {
    guard token == generation else { return }
    ownedThreads.removeAll()
    for callback in pending.values {
      callback.resume(throwing: ScreenClipError.message("Codex disconnected."))
    }
    pending.removeAll()
    continuation?.yield(.object(["method": .string("screenclip/disconnected")]))
    continuation?.finish()
    continuation = nil
  }
  public func stop() {
    ownedThreads.removeAll()
    generation = UUID()
    process?.terminationHandler = nil
    try? input?.close()
    input = nil
    process?.terminate()
    process = nil
    buffer = Data()
    for callback in pending.values { callback.resume(throwing: CancellationError()) }
    pending.removeAll()
    continuation?.finish()
    continuation = nil
  }
}
