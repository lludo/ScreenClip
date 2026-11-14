import XCTest

@testable import ScreenClipCore

final class DonationPromptTests: XCTestCase {
  private let day: TimeInterval = 24 * 60 * 60

  func testDirectDownloadBuildOffersDonations() {
    XCTAssertTrue(DistributionChannel.offersDonations)
  }

  func testSponsorsLinkIsTheGitHubSponsorsPage() {
    XCTAssertEqual(DonationLinks.sponsors.scheme, "https")
    XCTAssertEqual(DonationLinks.sponsors.host, "github.com")
    XCTAssertEqual(DonationLinks.sponsors.path, "/sponsors/lludo")
  }

  func testPromptWaitsUntilTheFirstWeekOrThreeMergedFixes() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertFalse(
      DonationPromptPolicy.shouldShow(
        at: start, firstLaunchedAt: start, mergedCount: 0, optedOut: false, snoozeUntil: nil))
    XCTAssertFalse(
      DonationPromptPolicy.shouldShow(
        at: start.addingTimeInterval(6 * day), firstLaunchedAt: start, mergedCount: 2,
        optedOut: false, snoozeUntil: nil))
    XCTAssertTrue(
      DonationPromptPolicy.shouldShow(
        at: start.addingTimeInterval(7 * day), firstLaunchedAt: start, mergedCount: 0,
        optedOut: false, snoozeUntil: nil))
    XCTAssertTrue(
      DonationPromptPolicy.shouldShow(
        at: start, firstLaunchedAt: start, mergedCount: 3, optedOut: false, snoozeUntil: nil))
  }

  func testOptOutAndSnoozeSuppressThePrompt() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let later = start.addingTimeInterval(8 * day)
    XCTAssertFalse(
      DonationPromptPolicy.shouldShow(
        at: later, firstLaunchedAt: start, mergedCount: 4, optedOut: true, snoozeUntil: nil))
    let snoozeUntil = later.addingTimeInterval(DonationPromptPolicy.snoozeInterval)
    XCTAssertFalse(
      DonationPromptPolicy.shouldShow(
        at: later.addingTimeInterval(day), firstLaunchedAt: start, mergedCount: 4, optedOut: false,
        snoozeUntil: snoozeUntil))
    XCTAssertTrue(
      DonationPromptPolicy.shouldShow(
        at: snoozeUntil, firstLaunchedAt: start, mergedCount: 0, optedOut: false,
        snoozeUntil: snoozeUntil))
  }

  func testMergedFixCountIncludesVerifiedAndArchivedReportsOnly() {
    var merged = Issue(projectID: nil, title: "Merged", capture: capture())
    merged.status = .merged
    var verified = Issue(projectID: nil, title: "Verified", capture: capture())
    verified.status = .verified
    verified.archived = true
    var open = Issue(projectID: nil, title: "Open", capture: capture())
    open.status = .prOpen
    var canceled = Issue(projectID: nil, title: "Canceled", capture: capture())
    canceled.status = .canceled
    XCTAssertEqual(DonationPromptPolicy.mergedFixCount([merged, verified, open, canceled]), 2)
  }

  func testOlderSettingsDecodeWithoutDonationFields() throws {
    let legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
    let stripped = legacy.filter {
      !["firstLaunchedAt", "donationOptOut", "donationSnoozeUntil"].contains($0.key)
    }
    let decoded = try JSONDecoder().decode(
      AppSettings.self, from: JSONSerialization.data(withJSONObject: stripped))
    XCTAssertNil(decoded.firstLaunchedAt)
    XCTAssertNil(decoded.donationOptOut)
    XCTAssertNil(decoded.donationSnoozeUntil)
    XCTAssertTrue(decoded.shouldHideScreenClipDuringCapture)
  }

  private func capture() -> Capture {
    Capture(note: "A clipped label", imagePath: "/tmp/test.png", context: CaptureContext(appName: "Test"))
  }
}
