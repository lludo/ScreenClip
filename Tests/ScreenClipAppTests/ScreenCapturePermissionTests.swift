import ScreenCaptureKit
import XCTest

@testable import ScreenClip

@MainActor final class ScreenCapturePermissionTests: XCTestCase {
  func testActualCaptureSucceedsDespiteFalsePreflight() async throws {
    let permission = ScreenCapturePermission(preflight: { false })
    let result = try await permission.obtain { 42 }
    XCTAssertEqual(result, 42)
    XCTAssertEqual(permission.state, .available)
  }
  func testActualDenialSurvivesReportingAndRecheckRecovers() async throws {
    var denied = true
    let permission = ScreenCapturePermission(
      preflight: { true },
      probe: {
        if denied {
          throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }
      })
    do {
      try await permission.obtain {
        throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
      }
      XCTFail("Expected macOS denial")
    } catch {
      XCTAssertTrue(permission.report(error).contains("macOS"))
      XCTAssertEqual(permission.state, .blocked)
    }
    denied = false
    let available = await permission.recheck()
    XCTAssertTrue(available)
    XCTAssertEqual(permission.state, .available)
  }
  func testChangedExecutableRequiresReopenBeforeCapture() async {
    let permission = ScreenCapturePermission(replaced: { true })
    var attempted = false
    do {
      try await permission.obtain { attempted = true }
      XCTFail("Expected restart request")
    } catch { _ = permission.report(error) }
    XCTAssertFalse(attempted)
    XCTAssertEqual(permission.state, .needsRestart)
  }
  func testOtherCaptureErrorsDoNotClaimPermissionWasDenied() async {
    let permission = ScreenCapturePermission()
    do {
      try await permission.obtain {
        throw NSError(
          domain: "CaptureTest", code: 42,
          userInfo: [NSLocalizedDescriptionKey: "Display disconnected"])
      }
      XCTFail("Expected display error")
    } catch {
      XCTAssertEqual(permission.report(error), "Display disconnected")
      XCTAssertEqual(permission.state, .unknown)
    }
  }
}
