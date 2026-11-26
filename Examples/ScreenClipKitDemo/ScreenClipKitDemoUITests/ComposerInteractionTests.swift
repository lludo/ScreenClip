import XCTest

final class ComposerInteractionTests: XCTestCase {
  @MainActor func testDismissKeyboardAndUseAnnotationHistory() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-simulateShakeAfter", "1"]
    app.launch()
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
    XCTAssertTrue(keyboard.exists)
    XCTAssertLessThanOrEqual(note.frame.maxY, keyboard.frame.minY)
    attachScreenshot(name: "Editing the note")
    app.buttons["Dismiss keyboard"].tap()
    let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
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

  @MainActor private func attachScreenshot(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
