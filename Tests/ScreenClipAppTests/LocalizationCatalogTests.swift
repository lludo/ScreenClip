import XCTest
@testable import ScreenClip
@testable import ScreenClipCore

final class LocalizationCatalogTests: XCTestCase {
  func testDynamicLabelsUseRequestedLocale() {
    let german = Locale(identifier: "de")
    XCTAssertEqual(Chrome.stored("Screen capture is ready.", locale: german), "Die Bildschirmaufnahme ist bereit.")
    XCTAssertNotEqual(IssueStatus.working.localizedTitle(locale: german), IssueStatus.working.title)
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
