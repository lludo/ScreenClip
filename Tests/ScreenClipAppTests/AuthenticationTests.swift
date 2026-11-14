import Foundation
import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class AuthenticationTests: XCTestCase {
  @MainActor final class Runtime {
    var account: JSONValue = .object(["account": .null, "requiresOpenaiAuth": .bool(true)])
    var requests: [(String, JSONValue)] = []
    var opened: [URL] = []
    var allowBrowser = true
    var malformed = false
    var onStart: (() -> Void)?
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
      requests.append((method, params))
      if method == "account/read" { return account }
      if method == "account/login/start" {
        onStart?()
        if malformed {
          return .object([
            "type": .string("chatgpt"), "loginId": .string("attempt"),
            "authUrl": .string("file:///tmp/not-a-login"),
          ])
        }
        if params["type"].string == "chatgptDeviceCode" {
          return .object([
            "type": .string("chatgptDeviceCode"), "loginId": .string("device-attempt"),
            "verificationUrl": .string("https://auth.openai.com/codex/device"),
            "userCode": .string("TEST-CODE"),
          ])
        }
        return .object([
          "type": .string("chatgpt"), "loginId": .string("browser-attempt"),
          "authUrl": .string("https://auth.openai.com/authorize"),
        ])
      }
      if method == "account/login/cancel" { return .object(["status": .string("canceled")]) }
      throw ScreenClipError.message("Unexpected test request: " + method)
    }
    func controller(timeout: UInt64 = 300_000_000_000) -> CodexAuthentication {
      CodexAuthentication(
        request: request,
        openURL: { [self] url in
          opened.append(url)
          return allowBrowser
        }, timeoutNanoseconds: timeout)
    }
    func signedIn() {
      account = .object([
        "account": .object(["type": .string("chatgpt")]), "requiresOpenaiAuth": .bool(true),
      ])
    }
  }

  func testSignInReusesExistingSessionWithoutStartingLoginOrOpeningBrowser() async {
    let runtime = Runtime()
    runtime.signedIn()
    let auth = runtime.controller()
    await auth.signIn()
    XCTAssertEqual(auth.state, .ready)
    XCTAssertEqual(runtime.requests.map(\.0), ["account/read"])
    XCTAssertTrue(runtime.opened.isEmpty)
    XCTAssertNil(auth.loginID)
  }
  func testAPIKeyAndNoAuthProviderDoNotStartChatGPTLogin() async {
    for response: JSONValue in [
      .object(["account": .object(["type": .string("apiKey")]), "requiresOpenaiAuth": .bool(true)]),
      .object(["account": .null, "requiresOpenaiAuth": .bool(false)]),
    ] {
      let runtime = Runtime()
      runtime.account = response
      let auth = runtime.controller()
      await auth.signIn()
      XCTAssertEqual(auth.state, .ready)
      XCTAssertTrue(runtime.opened.isEmpty)
      XCTAssertFalse(runtime.requests.contains { $0.0 == "account/login/start" })
    }
  }
  func testUnknownAccountResponseDoesNotClaimAuthentication() async {
    let runtime = Runtime()
    runtime.account = .object([:])
    let auth = runtime.controller()
    await auth.check()
    XCTAssertEqual(auth.state, .signedOut)
  }
  func testFailureNotificationShowsPasskeyErrorAndClearsWaitingState() async {
    let runtime = Runtime()
    let auth = runtime.controller()
    await auth.signIn()
    XCTAssertEqual(auth.state, .awaitingBrowser)
    await auth.handleNotification(
      method: "account/login/completed",
      params: .object([
        "loginId": .string("browser-attempt"), "success": .bool(false),
        "error": .string("invalid_passkey_response"),
      ]))
    guard case .failed(let message) = auth.state else {
      return XCTFail("The browser failure must be visible")
    }
    XCTAssertTrue(message.contains("invalid_passkey_response"))
    XCTAssertNil(auth.loginID)
    XCTAssertNil(auth.loginURL)
    await auth.handleNotification(method: "account/updated", params: .object(["authMode": .null]))
    XCTAssertEqual(auth.state, .failed(message))
  }
  func testDeviceFallbackCancelsOldAttemptAndShowsCode() async {
    let runtime = Runtime()
    let auth = runtime.controller()
    await auth.signIn()
    await auth.signIn(method: .deviceCode)
    XCTAssertTrue(
      runtime.requests.contains {
        $0.0 == "account/login/cancel" && $0.1["loginId"].string == "browser-attempt"
      })
    XCTAssertEqual(auth.state, .awaitingCode)
    XCTAssertEqual(auth.userCode, "TEST-CODE")
    XCTAssertEqual(runtime.opened.last?.absoluteString, "https://auth.openai.com/codex/device")
    await auth.handleNotification(
      method: "account/login/completed",
      params: .object(["loginId": .string("browser-attempt"), "success": .bool(false)]))
    XCTAssertEqual(auth.state, .awaitingCode)
    runtime.signedIn()
    await auth.handleNotification(
      method: "account/login/completed",
      params: .object(["loginId": .string("device-attempt"), "success": .bool(true)]))
    XCTAssertEqual(auth.state, .ready)
    XCTAssertNil(auth.userCode)
    XCTAssertNil(auth.loginURL)
  }
  func testCancellationAndStaleCallbackDoNotChangeSavedSession() async {
    let runtime = Runtime()
    let auth = runtime.controller()
    await auth.signIn()
    await auth.cancel()
    XCTAssertEqual(auth.state, .idle)
    XCTAssertTrue(runtime.requests.contains { $0.0 == "account/login/cancel" })
    XCTAssertFalse(runtime.requests.contains { $0.0 == "account/logout" })
    await auth.handleNotification(
      method: "account/login/completed",
      params: .object(["loginId": .string("browser-attempt"), "success": .bool(true)]))
    XCTAssertEqual(auth.state, .idle)
  }
  func testNoCallbackTimesOutAndCancelsOnlyPendingLogin() async throws {
    let runtime = Runtime()
    let auth = runtime.controller(timeout: 10_000_000)
    await auth.signIn()
    let deadline = Date().addingTimeInterval(2)
    while auth.state.isPending && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard case .failed(let message) = auth.state else {
      return XCTFail("A missing browser callback must time out")
    }
    XCTAssertTrue(message.contains("did not finish"))
    XCTAssertNil(auth.loginID)
    XCTAssertTrue(runtime.requests.contains { $0.0 == "account/login/cancel" })
    XCTAssertFalse(runtime.requests.contains { $0.0 == "account/logout" })
  }
  func testInvalidURLAndBrowserLaunchFailureAreVisibleInSettings() async {
    for malformed in [false, true] {
      let runtime = Runtime()
      runtime.malformed = malformed
      runtime.allowBrowser = false
      let auth = runtime.controller()
      await auth.signIn()
      guard case .failed = auth.state else { return XCTFail("The failure must be shown") }
      XCTAssertNil(auth.loginID)
      XCTAssertTrue(runtime.requests.contains { $0.0 == "account/login/cancel" })
      if malformed { XCTAssertTrue(runtime.opened.isEmpty) }
    }
  }
  func testCheckingPendingLoginCanRecoverAnExistingSignIn() async {
    let runtime = Runtime()
    let auth = runtime.controller()
    await auth.signIn()
    runtime.signedIn()
    await auth.check()
    XCTAssertEqual(auth.state, .ready)
    XCTAssertNil(auth.loginID)
    XCTAssertTrue(runtime.requests.contains { $0.0 == "account/login/cancel" })
  }
}
