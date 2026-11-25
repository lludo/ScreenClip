#if os(iOS) && DEBUG
  import ScreenClipWire
  import SwiftUI
  import UIKit
  import os

  let kitLog = Logger(subsystem: "ScreenClipKit", category: "ScreenClip")

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
    static var deviceID: UUID {
      if let text = defaults.string(forKey: "deviceID"), let id = UUID(uuidString: text) { return id }
      let id = UUID()
      defaults.set(id.uuidString, forKey: "deviceID")
      return id
    }
  }

  @MainActor final class KitRuntime {
    static let shared = KitRuntime()
    private(set) var options = ScreenClipOptions()
    private var started = false
    let outbox = Outbox()
    lazy var link = MacLink(outbox: outbox)
    let overlay = OverlayPresenter()
    private var observers: [NSObjectProtocol] = []

    func start(_ options: ScreenClipOptions) {
      self.options = options
      guard !started else { return }
      started = true
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
      overlay.presentSheet(in: scene) { dismiss in
        ComposerView(image: image, link: self.link, outbox: self.outbox) { note, png in
          dismiss()
          self.submit(note: note, image: png, device: device)
        } cancel: {
          dismiss()
        }
      }
    }

    func showSettings() {
      guard !overlay.isPresentingSheet, let scene = Snapshot.activeScene() else { return }
      overlay.presentSheet(in: scene) { dismiss in
        NavigationStack {
          KitSettingsView(link: self.link, outbox: self.outbox)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
      }
    }

    private func submit(note: String, image: Data?, device: DeviceContext) {
      let report = WireReport(note: note, image: image, device: device)
      do {
        try outbox.add(report)
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
#endif
