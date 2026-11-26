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
    static var deviceID: UUID { deviceID(store: deviceIDStore, defaults: defaults) }
    static let deviceIDStore = PairingKeychain<UUID>(service: "com.mirageteam.screenclip.kit", account: "deviceID")

    /// The id the Mac knows this device by. It lives in the Keychain next to the pairing keys, so
    /// it survives the host app being deleted and reinstalled just as they do; an id kept only in
    /// UserDefaults would be replaced on reinstall and the Mac would ask to pair again. An id
    /// already in UserDefaults moves into the Keychain, so existing pairings keep working.
    static func deviceID(store: PairingKeychain<UUID>, defaults: UserDefaults) -> UUID {
      let saved = defaults.string(forKey: "deviceID").flatMap(UUID.init(uuidString:))
      do {
        if let id = try store.load().first {
          if saved != id { defaults.set(id.uuidString, forKey: "deviceID") }
          return id
        }
        let id = saved ?? UUID()
        defaults.set(id.uuidString, forKey: "deviceID")
        do { try store.save([id]) } catch { kitLog.error("Could not save the device id: \(error.localizedDescription)") }
        return id
      } catch {
        // The Keychain cannot be read yet (before first unlock); never replace a stored id then.
        if let saved { return saved }
        let id = UUID()
        defaults.set(id.uuidString, forKey: "deviceID")
        return id
      }
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
    let attachments = AttachmentProviders()
    private var observers: [NSObjectProtocol] = []
    private(set) var startedAt = Date()

    func start(_ options: ScreenClipOptions) {
      self.options = options
      if options.captureConsoleOutput { ConsoleCapture.shared.start() }
      guard !started else { return }
      started = true
      startedAt = Date()
      NetworkWatcher.shared.start()
      ShakeHook.install { [weak self] scene in self?.shakeDetected(in: scene) }
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

    private func shakeDetected(in scene: UIWindowScene) {
      guard options.triggers.contains(.shake), KitPreferences.shakeEnabled else { return }
      guard !overlay.isPresentingSheet, !Snapshot.anotherOverlayIsShowing(in: scene, ignoring: overlay.windows) else {
        return
      }
      capture(in: scene)
    }

    private func systemScreenshotTaken() {
      guard options.triggers.contains(.screenshot), KitPreferences.screenshotOfferEnabled,
        !overlay.isPresentingSheet
      else { return }
      capture(in: Snapshot.activeScene(), offerFirst: true)
    }

    func capture() { capture(in: Snapshot.activeScene()) }

    private func capture(in scene: UIWindowScene?, offerFirst: Bool = false) {
      guard !overlay.isPresentingSheet, let scene else { return }
      overlay.dismissToast()
      guard let snapshot = Snapshot.capture(in: scene, excluding: overlay.windows)
      else {
        kitLog.error("ScreenClipKit could not find a visible window to capture.")
        return
      }
      let device = DeviceInfo.context(scene: scene)
      // Quick, main-thread facts are taken now, as they were at the moment of capture. Logs are
      // read in the background while the tester annotates.
      let capturedAt = Date()
      var immediate: [DiagnosticFile] = []
      if let window = Snapshot.appWindow(in: scene, excluding: overlay.windows),
        let tree = Diagnostics.viewTree(of: window)
      {
        immediate.append(tree)
      }
      if let state = Diagnostics.deviceState(scene: scene, startedAt: startedAt) { immediate.append(state) }
      if let console = ConsoleCapture.shared.file() { immediate.append(console) }
      if offerFirst {
        overlay.toast("Report this screen to ScreenClip?", in: scene, action: "Report") { [weak self] in
          self?.compose(snapshot: snapshot, in: scene, device: device, capturedAt: capturedAt, immediate: immediate)
        }
      } else {
        compose(snapshot: snapshot, in: scene, device: device, capturedAt: capturedAt, immediate: immediate)
      }
    }

    private func compose(snapshot: Snapshot, in scene: UIWindowScene, device: DeviceContext, capturedAt: Date, immediate: [DiagnosticFile]) {
      guard !overlay.isPresentingSheet, scene.activationState == .foregroundActive else { return }
      let logs = Task.detached(priority: .utility) { Diagnostics.recentLogs(until: capturedAt) }
      let reportID = UUID()
      let context = ScreenClipReportContext(
        reportID: reportID, capturedAt: capturedAt, screenTitle: device.screenTitle, screenPath: device.screenPath)
      var provided: AttachmentProviders.Run?
      func collectAttachments(_ enabled: Bool) {
        if enabled {
          if provided == nil { provided = attachments.start(context) }
        } else {
          provided?.cancel()
          provided = nil
        }
      }
      collectAttachments(KitPreferences.attachDiagnostics)
      overlay.presentSheet(in: scene) { dismiss in
        ComposerView(
          snapshot: snapshot, link: self.link, outbox: self.outbox, followUp: self.followUp,
          stillBroken: { [weak self] entry in self?.followUp.entry = entry },
          diagnosticsChanged: collectAttachments
        ) { note, png, attach, picked in
          let target = self.followUp.entry
          var device = device
          device.pickedScreenshot = picked
          var files: [DiagnosticFile]?
          collectAttachments(attach)
          if attach, let provided {
            let builtIn = Set(["logs.txt"] + immediate.map(\.name))
            async let log = Self.value(of: logs, timeout: 8)
            async let extra = provided.files(avoiding: builtIn)
            let captured = Diagnostics.captureFiles(immediate, picked: picked != nil)
            files = ([await log].compactMap { $0 } + captured + (await extra)).fittingSizeLimit()
          } else {
            logs.cancel()
          }
          var report = WireReport(id: reportID, createdAt: capturedAt, note: note, image: png, device: device, diagnostics: files)
          report.followUpOf = target?.id
          report.destination = target?.destination
          if target == nil, let id = self.link.connectedMacID, let name = self.link.connectedMacName {
            report.destination = ReportDestination(macID: id, name: name)
          }
          try self.outbox.add(report)
          self.followUp.entry = nil
          dismiss()
          self.deliver(report)
        } cancel: {
          logs.cancel()
          collectAttachments(false)
          dismiss()
        }
      }
    }

    /// The task's value, or nil if it takes longer than `timeout`.
    static func value<T: Sendable>(of task: Task<T?, Never>, timeout: TimeInterval) async -> T? {
      // OSLogStore can block inside a synchronous system call. Finishing the stream lets Send
      // proceed even while that call is still unwinding after cancellation.
      let (stream, result) = AsyncStream<T>.makeStream()
      Task {
        if let value = await task.value { result.yield(value) }
        result.finish()
      }
      let deadline = Task {
        try await Task.sleep(for: .seconds(timeout))
        result.finish()
        task.cancel()
      }
      defer { deadline.cancel() }
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
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

    private func deliver(_ report: WireReport) {
      link.sendQueue()
      guard link.isDestination(report.destination) else {
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
