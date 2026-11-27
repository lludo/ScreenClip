import XCTest

final class ComposerInteractionTests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  @MainActor func testDismissKeyboardAndUseAnnotationHistory() throws {
    // These tests check positions; a simulator left in landscape would move everything.
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launch()
    let settings = app.buttons["Settings"].firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    app.buttons["Report this screen"].tap()
    let note = app.descendants(matching: .any).matching(identifier: "screenclip.note").firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 10))
    let canvas = app.descendants(matching: .any).matching(identifier: "screenclip.canvas").firstMatch
    let red = app.buttons["Red"], white = app.buttons["White"]
    let arrow = app.buttons["Arrow"], redact = app.buttons["Redact"]
    XCTAssertLessThanOrEqual(red.frame.maxX, canvas.frame.minX)
    XCTAssertGreaterThanOrEqual(arrow.frame.minX, canvas.frame.maxX)
    XCTAssertLessThan(red.frame.midY, white.frame.midY)
    XCTAssertLessThan(arrow.frame.midY, redact.frame.midY)
    XCTAssertEqual(red.frame.midX, white.frame.midX, accuracy: 1)
    XCTAssertEqual(arrow.frame.midX, redact.frame.midX, accuracy: 1)
    attachScreenshot(name: "Report composer")
    note.tap()
    note.typeText("First line\nSecond line")
    let keyboard = app.keyboards.firstMatch
    // iPad can host its keyboard outside the app’s accessibility hierarchy. In both
    // cases the editor must offer dismissal, preserve the note, and relinquish focus.
    let dismissButton = app.buttons["Dismiss keyboard"]
    XCTAssertTrue(dismissButton.exists)
    if keyboard.exists { XCTAssertLessThanOrEqual(note.frame.maxY, keyboard.frame.minY) }
    attachScreenshot(name: "Editing the note")
    dismissButton.tap()
    let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    XCTAssertFalse(dismissButton.exists)
    XCTAssertEqual(note.value as? String, "First line\nSecond line")

    let undo = app.buttons["Undo"]
    let redo = app.buttons["Redo"]
    for button in [undo, redo] {
      XCTAssertGreaterThanOrEqual(button.frame.width, 44)
      XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }
    XCTAssertGreaterThanOrEqual(redo.frame.minX - undo.frame.maxX, 8)
    XCTAssertFalse(undo.isEnabled)
    XCTAssertFalse(redo.isEnabled)
    redact.tap()
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
      .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55)))
    XCTAssertTrue(undo.isEnabled)
    undo.tap()
    XCTAssertFalse(undo.isEnabled)
    XCTAssertTrue(redo.isEnabled)
    redo.tap()
    XCTAssertTrue(undo.isEnabled)
    XCTAssertFalse(redo.isEnabled)
  }

  @MainActor func testPickingAPhotoReplacesTheCaptureAndCanBeUndone() throws {
    // These tests check positions; a simulator left in landscape would move everything.
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-simulateShakeAfter", "1"]
    app.launch()
    let pick = app.buttons["screenclip.pickScreenshot"]
    XCTAssertTrue(pick.waitForExistence(timeout: 10))
    XCTAssertGreaterThanOrEqual(pick.frame.width, 44)
    pick.tap()
    // The system picker runs out of process and exposes little to UI tests. It opens on the
    // Screenshots grid; scripts/test_ios_sdk.py adds one, the first cell below the privacy banner.
    XCTAssertTrue(app.staticTexts["Screenshots"].waitForExistence(timeout: 15))
    attachScreenshot(name: "Photos picker over the composer")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.42)).tap()
    let banner = app.descendants(matching: .any).matching(identifier: "screenclip.pickedBanner").firstMatch
    XCTAssertTrue(banner.waitForExistence(timeout: 15))
    attachScreenshot(name: "Composer with a picked screenshot")
    app.buttons["Use the live capture instead"].tap()
    let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
  }

  @MainActor private func attachScreenshot(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
