import XCTest
@testable import ScreenClip
@testable import ScreenClipCore

final class LocalizationCatalogTests: XCTestCase {
  func testDynamicLabelsUseRequestedLocale() {
    let german = Locale(identifier: "de")
    XCTAssertEqual(Chrome.stored("Screen capture is ready.", locale: german), "Die Bildschirmaufnahme ist bereit.")
    XCTAssertNotEqual(IssueStatus.working.localizedTitle(locale: german), IssueStatus.working.title)
  }

  func testMovedFromKeepsTheReportReference() {
    let german = Locale(identifier: "de")
    XCTAssertEqual(Chrome.stored("Moved from Shop (#12)", locale: german), "Verschoben von Shop (#12)")
    XCTAssertEqual(Chrome.stored("Moved from Shop", locale: german), "Verschoben von Shop")
  }

  func testAppGeneratedErrorsAreTranslated() {
    let german = Locale(identifier: "de")
    for english in [
      "Unable to load image attachment.",
      "Connected, but the result could not be saved to the Keychain.",
      "Opened in Claude Desktop. Continue there, and let it finish before ScreenClip runs again.",
    ] {
      XCTAssertNotEqual(Chrome.stored(english, locale: german), english)
    }
  }

  func testShortcutLabelsNameNonPrintingKeys() {
    XCTAssertEqual(RecorderField.keyLabel(keyCode: 49, characters: " "), "Space")
    XCTAssertEqual(RecorderField.keyLabel(keyCode: 123, characters: "\u{F702}"), "←")
    XCTAssertEqual(RecorderField.keyLabel(keyCode: 111, characters: "\u{F70F}"), "F12")
    XCTAssertEqual(RecorderField.keyLabel(keyCode: 105, characters: "\u{F710}"), "Key 105")
    XCTAssertEqual(RecorderField.keyLabel(keyCode: 1, characters: "s"), "S")
  }

  func testStringCatalogsCoverEveryInterfaceString() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [root.appendingPathComponent("scripts/check_localizations.py").path]
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, output)
  }
}
