import AppKit
import Foundation
import OSLog
import ScreenCaptureKit
import ScreenClipCore

@MainActor final class ScreenCapturePermission: ObservableObject {
  enum State: Equatable { case unknown, checking, available, blocked, needsRestart }
  @Published private(set) var state: State = .unknown
  @Published private(set) var message = "Screen capture has not been checked yet."
  private let preflight: () -> Bool
  private let replaced: () -> Bool
  private let probe: () async throws -> Void
  private let log: (String, [String: String]) -> Void

  init(
    preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
    replaced: @escaping () -> Bool = { false },
    probe: @escaping () async throws -> Void = {
      _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }, log: @escaping (String, [String: String]) -> Void = { _, _ in }
  ) {
    self.preflight = preflight
    self.replaced = replaced
    self.probe = probe
    self.log = log
  }
  func obtain<T>(_ operation: () async throws -> T) async throws -> T {
    log("capture.access.check", ["preflight": String(preflight())])
    if replaced() {
      state = .needsRestart
      message =
        "This running copy of ScreenClip was rebuilt. Reopen it to refresh screen-capture access."
      log("capture.build.replaced", [:])
      throw ScreenClipError.message(message)
    }
    state = .checking
    do {
      // CG preflight is a hint; the actual ScreenCaptureKit operation decides availability.
      let result = try await operation()
      state = .available
      message = "Screen capture is ready."
      log("capture.access.available", [:])
      return result
    } catch {
      _ = report(error)
      throw error
    }
  }
  @discardableResult func recheck() async -> Bool {
    guard state != .checking else { return false }
    do {
      try await obtain(probe)
      return true
    } catch { return false }
  }
  func report(_ error: Error) -> String {
    if state == .needsRestart { return message }
    let value = error as NSError
    log(
      "capture.access.error",
      [
        "domain": value.domain, "code": String(value.code),
        "description": value.localizedDescription,
      ])
    if value.domain == SCStreamErrorDomain && value.code == SCStreamError.Code.userDeclined.rawValue
    {
      state = .blocked
      message =
        "macOS has not made screen capture available to this copy of ScreenClip. If access is already enabled in System Settings, reopen the app and check again. A rebuilt development copy may need to be allowed again."
    } else {
      state = .unknown
      message = value.localizedDescription
    }
    return message
  }
}

@MainActor final class CaptureDiagnostics {
  private let file: URL
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.mirageteam.screenclip", category: "capture")
  init(root: URL) { file = root.appendingPathComponent("capture-diagnostics.log") }
  func record(_ event: String, _ fields: [String: String] = [:]) {
    logger.notice("\(event,privacy:.public)")
    var entry = fields
    entry["event"] = event
    entry["time"] = Date().formatted(.iso8601)
    entry["pid"] = String(ProcessInfo.processInfo.processIdentifier)
    guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    else { return }
    data.append(10)
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512_000 {
      try? Data().write(to: file, options: .atomic)
    }
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(
        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  }
}
