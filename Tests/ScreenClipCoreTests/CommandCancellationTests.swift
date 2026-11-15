import XCTest

@testable import ScreenClipCore

final class CommandCancellationTests: XCTestCase {
  func testCancellingTheTaskStopsTheChildProcess() async throws {
    let started = Date()
    let task = Task {
      try await CommandRunner.run("/bin/sleep", ["30"], timeout: 60)
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("A cancelled command should throw.")
    } catch is CancellationError {
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testGitHubCLIFallsBackWhenTheSavedPathIsGone() {
    var settings = AppSettings()
    settings.ghPath = "/nonexistent/gh"
    XCTAssertNotEqual(AgentDetector.ghPath(settings), "/nonexistent/gh")
  }
}
