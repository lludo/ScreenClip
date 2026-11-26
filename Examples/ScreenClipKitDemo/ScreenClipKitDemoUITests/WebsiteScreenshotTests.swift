import XCTest

/// Screenshots for the website and the SDK documentation. Skipped unless run by
/// `scripts/sdk_screenshots.py`, which sets `SCREENCLIP_SCREENSHOTS` and exports the attachments.
final class WebsiteScreenshotTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREENCLIP_SCREENSHOTS"] == "1", "Run scripts/sdk_screenshots.py")
    continueAfterFailure = false
  }

  @MainActor func testCaptureWebsiteScreenshots() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-simulateShakeAfter", "14"]
    app.launch()
    // Reopen from the Home Screen, so the status bar has no "back to the test runner" link.
    XCUIDevice.shared.press(.home)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let icon = springboard.icons["ScreenClip Demo"]
    XCTAssertTrue(icon.waitForExistence(timeout: 10))
    icon.tap()

    // A screen with a clipped button to report.
    let croissant = app.cells.element(boundBy: 1)
    XCTAssertTrue(croissant.waitForExistence(timeout: 10))
    croissant.tap()
    XCTAssertTrue(app.navigationBars["Croissant"].waitForExistence(timeout: 5))

    // The report sheet, marked up, with a note.
    let note = app.descendants(matching: .any).matching(identifier: "screenclip.note").firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 20))
    note.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    note.typeText("The price is cut off in the Add to order button.")
    app.buttons["Dismiss keyboard"].tap()
    let canvas = app.descendants(matching: .any).matching(identifier: "screenclip.canvas").firstMatch
    draw("Rectangle", on: canvas, from: CGVector(dx: 0.24, dy: 0.62), to: CGVector(dx: 0.76, dy: 0.7))
    draw("Arrow", on: canvas, from: CGVector(dx: 0.8, dy: 0.88), to: CGVector(dx: 0.62, dy: 0.72))
    attach("composer", after: 1)
  }

  @MainActor private func draw(_ tool: String, on canvas: XCUIElement, from start: CGVector, to end: CGVector) {
    XCUIApplication().buttons[tool].tap()
    Thread.sleep(forTimeInterval: 0.5)
    canvas.coordinate(withNormalizedOffset: start)
      .press(forDuration: 0.2, thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.1)
  }

  @MainActor private func attach(_ name: String, after seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
