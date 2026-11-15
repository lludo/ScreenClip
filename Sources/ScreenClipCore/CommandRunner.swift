import Darwin
import Foundation

public struct CommandResult {
  public let output: String
  public let error: String
  public let status: Int32
}

public enum CommandRunner {
  /// How long to keep reading output after the command exits. A background grandchild
  /// that inherited the pipes (an SSH ControlPersist master, `npm run dev &`) would
  /// otherwise keep them open forever.
  static let drainGrace: TimeInterval = 3

  public static func run(
    _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 120,
    environment: [String: String]? = nil
  ) async throws -> CommandResult {
    // A dedicated thread, not the cooperative pool: commands can run for minutes.
    let handle = CancelHandle()
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(
            with: Result {
              try runBlocking(
                executable, arguments, cwd: cwd, timeout: timeout, environment: environment,
                handle: handle)
            })
        }
      }
    } onCancel: {
      handle.cancel()
    }
    // The process was killed on cancel; report that instead of a misleading exit status.
    try Task.checkCancellation()
    return result
  }

  /// Lets task cancellation reach the child process, whichever side gets there first.
  private final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false

    func attach(_ pid: pid_t) {
      lock.lock()
      self.pid = pid
      let kill = cancelled
      lock.unlock()
      if kill { CommandRunner.terminateTree(pid) }
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let pid = self.pid
      lock.unlock()
      if let pid { CommandRunner.terminateTree(pid) }
    }
  }

  private static func runBlocking(
    _ executable: String, _ arguments: [String], cwd: String?, timeout: TimeInterval,
    environment custom: [String: String]?, handle: CancelHandle
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var environment = custom ?? ProcessEnvironment.tools()
    environment["GIT_LFS_SKIP_SMUDGE"] = "1"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    let out = OutputBuffer()
    let err = OutputBuffer()
    let drained = DispatchGroup()
    for (pipe, buffer) in [(stdout, out), (stderr, err)] {
      drained.enter()
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          drained.leave()
        } else {
          buffer.append(chunk)
        }
      }
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      throw error
    }
    handle.attach(process.processIdentifier)
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      terminateTree(process.processIdentifier)
      _ = exited.wait(timeout: .now() + 5)
      stopReading(stdout, stderr)
      throw ScreenClipError.message(
        "Command timed out after \(Int(timeout))s: \(URL(fileURLWithPath: executable).lastPathComponent)"
      )
    }
    if drained.wait(timeout: .now() + drainGrace) == .timedOut { stopReading(stdout, stderr) }
    return CommandResult(
      output: String(decoding: out.data, as: UTF8.self),
      error: String(decoding: err.data, as: UTF8.self), status: process.terminationStatus)
  }

  private static func stopReading(_ pipes: Pipe...) {
    for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
  }

  /// SIGTERM the process and its descendants (a validation shell's test runners, for
  /// example), then SIGKILL anything still alive after a short grace period.
  static func terminateTree(_ root: pid_t, grace: TimeInterval = 0.5) {
    var pids = [root]
    var index = 0
    while index < pids.count {
      pids += childPIDs(of: pids[index])
      index += 1
    }
    for pid in pids { kill(pid, SIGTERM) }
    let deadline = Date().addingTimeInterval(grace)
    while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
      Thread.sleep(forTimeInterval: 0.05)
    }
    for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
  }

  private static func childPIDs(of parent: pid_t) -> [pid_t] {
    let count = proc_listchildpids(parent, nil, 0)
    guard count > 0 else { return [] }
    var children = [pid_t](repeating: 0, count: Int(count) * 2)
    let filled = children.withUnsafeMutableBytes { buffer in
      proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return [] }
    // proc_listchildpids reports a PID count, not a byte count.
    return Array(children.prefix(Int(filled))).filter { $0 > 0 }
  }

  public static func checked(
    _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 120
  ) async throws -> String {
    let result = try await run(executable, arguments, cwd: cwd, timeout: timeout)
    guard result.status == 0 else {
      throw ScreenClipError.message(
        String((result.error.isEmpty ? result.output : result.error).suffix(4000)))
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class OutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()
  func append(_ chunk: Data) {
    lock.lock()
    storage.append(chunk)
    lock.unlock()
  }
  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
