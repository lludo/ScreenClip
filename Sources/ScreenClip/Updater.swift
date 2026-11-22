import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates for the direct-download build, through Sparkle.
///
/// The feed, the EdDSA public key, and the defaults (check daily, download and install without asking)
/// are in `Resources/Info.plist`. A downloaded update installs when ScreenClip quits. A menu bar app
/// rarely quits, so a found update also shows an "Update" button in the menu bar popover.
/// `swift build` has no Sparkle, so the package build compiles this as a no-op.
@MainActor
final class Updater: NSObject, ObservableObject {
  static let shared = Updater()

  /// True once the updater is running. Update controls are hidden otherwise.
  @Published private(set) var isAvailable = false
  @Published private(set) var canCheckForUpdates = false
  /// A version found by a background check that the person has not looked at yet.
  @Published private(set) var pendingVersion: String?

  #if canImport(Sparkle)
  private var controller: SPUStandardUpdaterController?
  private var cancellable: AnyCancellable?
  /// Sparkle's handler to install a downloaded update now and relaunch.
  private var installNow: (() -> Void)?
  #endif

  /// Starts background checks. Debug builds stay quiet unless launched with `--check-updates`,
  /// so a development copy in /Applications is not replaced by the public release.
  func start() {
    #if canImport(Sparkle)
    guard controller == nil else { return }
    guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
    #if DEBUG
    guard ProcessInfo.processInfo.arguments.contains("--check-updates") else { return }
    #endif
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    self.controller = controller
    cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.canCheckForUpdates = $0 }
    isAvailable = true
    #endif
  }

  /// Starts a check, or brings forward an update Sparkle is already holding. The popover button
  /// clears when Sparkle reports that the person saw the update.
  func checkForUpdates() {
    #if canImport(Sparkle)
    controller?.checkForUpdates(nil)
    #endif
  }

  /// Installs the pending update and relaunches. Quitting goes through the usual checks, so an open
  /// capture or running agent work can still stop it.
  func installPendingUpdate() {
    #if canImport(Sparkle)
    // Kept after use: if quitting is refused (an open capture, running work), the button
    // stays and a second click tries again.
    if let installNow {
      installNow()
    } else {
      checkForUpdates()
    }
    #endif
  }

  /// Download and install updates without asking. On by default (`SUAutomaticallyUpdate`).
  var automaticallyInstallsUpdates: Bool {
    get {
      #if canImport(Sparkle)
      return controller?.updater.automaticallyDownloadsUpdates ?? false
      #else
      return false
      #endif
    }
    set {
      #if canImport(Sparkle)
      objectWillChange.send()
      controller?.updater.automaticallyChecksForUpdates = true
      controller?.updater.automaticallyDownloadsUpdates = newValue
      #endif
    }
  }
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
  // An automatic download finished. It installs at quit; until then the popover offers it.
  nonisolated func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    let version = item.displayVersionString
    MainActor.assumeIsolated {
      pendingVersion = version
      installNow = immediateInstallHandler
    }
    return true
  }
}

extension Updater: SPUStandardUserDriverDelegate {
  // ScreenClip is a menu bar app. Gentle reminders keep a scheduled update from stealing focus;
  // the popover's Update button is the reminder instead.
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    let version = update.displayVersionString
    let userInitiated = state.userInitiated
    MainActor.assumeIsolated {
      if !userInitiated { pendingVersion = version }
    }
  }

  nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    MainActor.assumeIsolated { if installNow == nil { pendingVersion = nil } }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    // A downloaded update waiting for quit outlives its session; keep offering it.
    MainActor.assumeIsolated { if installNow == nil { pendingVersion = nil } }
  }
}
#endif
