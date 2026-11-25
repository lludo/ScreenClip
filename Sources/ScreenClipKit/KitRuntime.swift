#if os(iOS) && DEBUG
  import ScreenClipWire
  import SwiftUI
  import UIKit
  import os

  let kitSubsystem = "ScreenClipKit"
  let kitLog = Logger(subsystem: kitSubsystem, category: "ScreenClip")

  /// Persisted SDK preferences, kept apart from the host app's defaults.
  struct KitPreferences {
    static let defaults = UserDefaults(suiteName: "com.mirageteam.screenclip.kit") ?? .standard
    static var shakeEnabled: Bool {
      get { defaults.object(forKey: "shake") as? Bool ?? true }
      set { defaults.set(newValue, forKey: "shake") }
    }
    static var screenshotOfferEnabled: Bool {
      get { defaults.object(forKey: "screenshotOffer") as? Bool ?? true }
      set { defaults.set(newValue, forKey: "screenshotOffer") }
    }
    static var attachDiagnostics: Bool {
      get { defaults.object(forKey: "attachDiagnostics") as? Bool ?? true }
      set { defaults.set(newValue, forKey: "attachDiagnostics") }
    }
    static var deviceID: UUID {
      if let text = defaults.string(forKey: "deviceID"), let id = UUID(uuidString: text) { return id }
      let id = UUID()
      defaults.set(id.uuidString, forKey: "deviceID")
      return id
    }
  }

  /// The sent report the next capture follows up on ("Still broken").
  @MainActor @Observable final class FollowUpTarget {
    var entry: SentLog.Entry?
  }

  @MainActor final class KitRuntime {
    static let shared = KitRuntime()
    private(set) var options = ScreenClipOptions()
    private var started = false
    let outbox = Outbox()
    let sent = SentLog()
    let followUp = FollowUpTarget()
    lazy var link = MacLink(outbox: outbox, sent: sent)
    let overlay = OverlayPresenter()
    private var observers: [NSObjectProtocol] = []
    private(set) var startedAt = Date()

    func start(_ options: ScreenClipOptions) {
      self.options = options
      if options.captureConsoleOutput { ConsoleCapture.shared.start() }
      guard !started else { return }
      started = true
      startedAt = Date()
      NetworkWatcher.shared.start()
      ShakeHook.install { [weak self] in self?.shakeDetected() }
      let center = NotificationCenter.default
      observers.append(
        center.addObserver(
          forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.systemScreenshotTaken() } })
      observers.append(
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.link.resume() } })
      observers.append(
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.link.suspend() } })
      link.resume()
      kitLog.info("ScreenClipKit started. Shake or take a screenshot to report.")
    }

    private func shakeDetected() {
      guard options.triggers.contains(.shake), KitPreferences.shakeEnabled else { return }
      guard !overlay.isPresentingSheet, !Snapshot.anotherOverlayIsShowing(ignoring: overlay.windows) else {
        return
      }
      capture()
    }

    private func systemScreenshotTaken() {
      guard options.triggers.contains(.screenshot), KitPreferences.screenshotOfferEnabled,
        !overlay.isPresentingSheet
      else { return }
      overlay.toast("Report this screen to ScreenClip?", action: "Report") { [weak self] in
        self?.capture()
      }
    }

    func capture() {
      guard !overlay.isPresentingSheet else { return }
      overlay.dismissToast()
      guard let scene = Snapshot.activeScene(), let image = Snapshot.image(of: scene, excluding: overlay.windows)
      else {
        kitLog.error("ScreenClipKit could not find a visible window to capture.")
        return
      }
      let device = DeviceInfo.context(scene: scene)
      // Quick, main-thread facts are taken now, as they were at the moment of capture. Logs are
      // read in the background while the tester annotates.
      let capturedAt = Date()
      var immediate: [DiagnosticFile] = []
      // The app's views stay as they were under the composer window, so the tree can be read a
      // moment later when SwiftUI needs time to build its accessibility elements.
      let appWindow = Snapshot.appWindow(in: scene, excluding: overlay.windows)
      let enabled = Diagnostics.AppAccessibility.enableTemporarily()
      let tree = Task { @MainActor () -> DiagnosticFile? in
        if enabled { try? await Task.sleep(nanoseconds: 500_000_000) }
        defer { if enabled { Diagnostics.AppAccessibility.restore() } }
        return appWindow.flatMap { Diagnostics.viewTree(of: $0) }
      }
      if let state = Diagnostics.deviceState(scene: scene, startedAt: startedAt) { immediate.append(state) }
      if let console = ConsoleCapture.shared.file() { immediate.append(console) }
      let logs = Task.detached(priority: .utility) { Diagnostics.recentLogs(until: capturedAt) }
      overlay.presentSheet(in: scene) { dismiss in
        ComposerView(
          image: image, link: self.link, outbox: self.outbox, followUp: self.followUp,
          stillBroken: { [weak self] entry in self?.followUp.entry = entry }
        ) { note, png, attach in
          dismiss()
          Task { @MainActor in
            var files: [DiagnosticFile]?
            if attach {
              let log = await Self.value(of: logs, timeout: 8)
              let viewTree = await tree.value
              files = ([log, viewTree].compactMap { $0 } + immediate).fittingSizeLimit()
            } else {
              logs.cancel()
            }
            let followUpOf = self.followUp.entry?.id
            self.followUp.entry = nil
            self.submit(note: note, image: png, device: device, diagnostics: files, followUpOf: followUpOf)
          }
        } cancel: {
          logs.cancel()
          dismiss()
        }
      }
    }

    /// The task's value, or nil if it takes longer than `timeout`.
    static func value<T: Sendable>(of task: Task<T?, Never>, timeout: TimeInterval) async -> T? {
      await withTaskGroup(of: T?.self) { group in
        group.addTask { await task.value }
        group.addTask {
          try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }

    func showSettings() {
      guard !overlay.isPresentingSheet, let scene = Snapshot.activeScene() else { return }
      overlay.presentSheet(in: scene) { dismiss in
        NavigationStack {
          KitSettingsView(link: self.link, outbox: self.outbox) { [weak self] entry in
            guard let self else { return }
            self.followUp.entry = entry
            dismiss()
            let number = entry.state?.reportNumber.map { " #\($0)" } ?? ""
            self.overlay.toast("Go to the broken screen and shake. The capture is added to report\(number).")
          }
            .toolbar {
              ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
      }
    }

    private func submit(
      note: String, image: Data?, device: DeviceContext, diagnostics: [DiagnosticFile]?, followUpOf: UUID?
    ) {
      var report = WireReport(note: note, image: image, device: device, diagnostics: diagnostics)
      report.followUpOf = followUpOf
      do {
        try outbox.add(report)
        link.sendQueue()
      } catch {
        overlay.toast("Could not save the report: \(error.localizedDescription)")
        return
      }
      guard link.isConnected else {
        overlay.toast(
          link.hasPairing
            ? "Saved. It will be sent when your Mac is reachable."
            : "Saved. Pair a Mac in ScreenClip settings to send it.")
        return
      }
      overlay.toast("Sending to \(link.connectedMacName ?? "your Mac")…")
      link.flush()
      link.whenDelivered(report.id, timeout: 8) { [weak self] delivered in
        guard let self else { return }
        self.overlay.toast(
          delivered
            ? "Sent to \(self.link.connectedMacName ?? "your Mac")."
            : "Saved. It will be sent when your Mac is reachable.")
      }
    }
  }

  extension Array where Element == DiagnosticFile {
    /// Drops the largest files until the total fits what the Mac accepts.
    func fittingSizeLimit() -> [DiagnosticFile] {
      var files = self
      while files.reduce(0, { $0 + $1.data.count }) > DiagnosticFile.maximumTotalBytes,
        let largest = files.indices.max(by: { files[$0].data.count < files[$1].data.count })
      {
        files.remove(at: largest)
      }
      return files
    }
  }
#endif
