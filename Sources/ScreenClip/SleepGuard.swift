import Foundation
import ScreenClipCore

/// Keeps the Mac from idle-sleeping while ScreenClip has work in flight, or while it is waiting
/// for reports from iOS devices. The display may still sleep. A laptop with its lid closed on
/// battery sleeps regardless.
@MainActor final class SleepGuard {
  enum Reason: Equatable { case work, iosServer }
  private var activity: NSObjectProtocol?
  private(set) var reason: Reason?

  /// Why the Mac should stay awake for this queue, or nil.
  static func reason(for snapshot: StoreSnapshot, iosServerRunning: Bool) -> Reason? {
    let paused = snapshot.settings.paused
    let autoMerge = Set(snapshot.projects.filter(\.autoMerge).map(\.id))
    let busy = snapshot.issues.contains { issue in
      guard !issue.archived else { return false }
      switch issue.status {
      case .working: return true
      case .queued: return !paused
      // An automatic merge waits on checks that ScreenClip polls.
      case .prOpen: return issue.projectID.map(autoMerge.contains) ?? false
      default: return false
      }
    }
    if busy { return .work }
    if iosServerRunning, snapshot.settings.keepAwakeForIOS ?? true { return .iosServer }
    return nil
  }

  func update(_ reason: Reason?) {
    guard reason != self.reason else { return }
    self.reason = reason
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = reason.map {
      ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled],
        reason: $0 == .work ? "ScreenClip is working on reports" : "ScreenClip is receiving reports from iOS devices")
    }
  }
}
