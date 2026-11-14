import Foundation

/// Direct-download builds can link to a tip page. An App Store build must not.
public enum DistributionChannel {
  public static var offersDonations: Bool {
    #if SCREENCLIP_APP_STORE
    false
    #else
    true
    #endif
  }
}

/// Where the tip buttons go. GitHub Sponsors is the only destination until another page exists.
public enum DonationLinks {
  public static let sponsors = URL(string: "https://github.com/sponsors/lludo")!
}

/// When the automatic tip prompt may appear. Opening it from Settings or the menu ignores this.
public enum DonationPromptPolicy {
  public static let mergedThreshold = 3
  public static let minimumAge: TimeInterval = 7 * 24 * 60 * 60
  public static let snoozeInterval: TimeInterval = 30 * 24 * 60 * 60
  public static let suggestedAmounts = [3, 5, 10]

  /// A merged or verified fix counts. Archived reports still count. Open and canceled reports do not.
  public static func mergedFixCount(_ issues: [Issue]) -> Int {
    issues.filter { $0.status == .merged || $0.status == .verified }.count
  }

  public static func shouldShow(
    at now: Date, firstLaunchedAt: Date?, mergedCount: Int, optedOut: Bool, snoozeUntil: Date?
  ) -> Bool {
    if optedOut { return false }
    if let snoozeUntil, now < snoozeUntil { return false }
    if mergedCount >= mergedThreshold { return true }
    guard let firstLaunchedAt else { return false }
    return now.timeIntervalSince(firstLaunchedAt) >= minimumAge
  }
}
