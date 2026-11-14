import XCTest

@testable import ScreenClipCore

final class ExternalConnectCodeTests: XCTestCase {
  private let canonical =
    "screenclip-connect:v1:eyJhdXRob3JpemF0aW9uIjoiQmVhcmVyIHNlY3JldCIsInVybCI6Imh0dHBzOi8vYXNzaXN0YW50LmV4YW1wbGUvaG9vayJ9"
  private let secret = "super-secret-value-9f3a"

  func testCanonicalSetupCodeRoundTripsAndOmitsTheRawSecret() {
    guard
      case .success(let code) = ExternalConnectCode.encode(
        url: " https://assistant.example/hook ", authorization: " Bearer secret ")
    else {
      return XCTFail("Expected a setup code")
    }
    XCTAssertEqual(code, canonical)
    XCTAssertFalse(code.contains("Bearer secret"))
    XCTAssertFalse(code.contains(" "))
    guard case .success(let credentials) = ExternalConnectCode.parse(code) else {
      return XCTFail("Expected the setup code to parse")
    }
    XCTAssertEqual(credentials.url, "https://assistant.example/hook")
    XCTAssertEqual(credentials.authorization, "Bearer secret")
    guard case .success(let again) = ExternalConnectCode.encode(
      url: credentials.url, authorization: credentials.authorization)
    else {
      return XCTFail("Expected to re-encode")
    }
    XCTAssertEqual(again, code)
    guard case .success(let wrapped) = ExternalConnectCode.parse("  \(code)\n") else {
      return XCTFail("Expected surrounding space to be ignored")
    }
    XCTAssertEqual(wrapped, credentials)
  }

  func testEncoderUsesBase64URLAndAcceptsTheStandardAlphabetAndPadding() {
    guard
      case .success(let code) = ExternalConnectCode.encode(
        url: "https://a.example/h", authorization: "Bearer >>")
    else {
      return XCTFail("Expected a setup code")
    }
    XCTAssertEqual(
      code,
      "screenclip-connect:v1:eyJhdXRob3JpemF0aW9uIjoiQmVhcmVyID4-IiwidXJsIjoiaHR0cHM6Ly9hLmV4YW1wbGUvaCJ9")
    XCTAssertFalse(code.contains("+"))
    XCTAssertFalse(code.contains("/"))
    let standard =
      "screenclip-connect:v1:eyJhdXRob3JpemF0aW9uIjoiQmVhcmVyID4+IiwidXJsIjoiaHR0cHM6Ly9hLmV4YW1wbGUvaCJ9"
    guard case .success(let fromStandard) = ExternalConnectCode.parse(standard) else {
      return XCTFail("Expected the standard base64 alphabet to parse")
    }
    XCTAssertEqual(fromStandard.authorization, "Bearer >>")
    let padded =
      "screenclip-connect:v1:eyJhdXRob3JpemF0aW9uIjoiYWIiLCJ1cmwiOiJodHRwczovL2Fzc2lzdGFudC5leGFtcGxlL2hvb2sifQ=="
    guard case .success(let fromPadding) = ExternalConnectCode.parse(padded) else {
      return XCTFail("Expected padding to be accepted")
    }
    XCTAssertEqual(fromPadding.url, "https://assistant.example/hook")
    XCTAssertEqual(fromPadding.authorization, "ab")
    guard
      case .success(let special) = ExternalConnectCode.encode(
        url: "https://assistant.example/hook?x=1&y=2", authorization: "Bearer a/b+c=")
    else {
      return XCTFail("Expected a setup code with reserved characters")
    }
    guard case .success(let decoded) = ExternalConnectCode.parse("Use this code: \(special).") else {
      return XCTFail("Expected the code inside a sentence to parse")
    }
    XCTAssertEqual(decoded.url, "https://assistant.example/hook?x=1&y=2")
    XCTAssertEqual(decoded.authorization, "Bearer a/b+c=")
  }

  func testLenientParsingAcceptsJSONCurlAndHeaderBlocks() {
    let json = """
      {"url":"https://assistant.example/hook","header":"Bearer secret"}
      """
    guard case .success(let fromHeader) = ExternalConnectCode.parse(json) else {
      return XCTFail("Expected JSON with a header key")
    }
    XCTAssertEqual(fromHeader.authorization, "Bearer secret")
    let block = """
      Webhook address: https://assistant.example/hook
      Authorization: Bearer secret
      """
    guard case .success(let fromBlock) = ExternalConnectCode.parse(block) else {
      return XCTFail("Expected a URL and Authorization line")
    }
    XCTAssertEqual(fromBlock.url, "https://assistant.example/hook")
    XCTAssertEqual(fromBlock.authorization, "Bearer secret")
    let curl = "curl -H \"Authorization: Bearer secret\" https://assistant.example/hook"
    guard case .success(let fromCurl) = ExternalConnectCode.parse(curl) else {
      return XCTFail("Expected a curl command")
    }
    XCTAssertEqual(fromCurl, fromBlock)
    let quoted = "curl --header 'Authorization: Bearer secret' https://assistant.example/hook"
    guard case .success(let fromQuoted) = ExternalConnectCode.parse(quoted) else {
      return XCTFail("Expected a single-quoted curl header")
    }
    XCTAssertEqual(fromQuoted.authorization, "Bearer secret")
    guard
      case .success(let local) = ExternalConnectCode.parse(
        "Authorization: Bearer secret\nhttp://127.0.0.1:8080/hook")
    else {
      return XCTFail("Expected a loopback address")
    }
    XCTAssertEqual(local.url, "http://127.0.0.1:8080/hook")
  }

  func testLenientParsingRejectsUnsafeInputWithoutEchoingTheSecret() {
    XCTAssertEqual(connectError(ExternalConnectCode.parse("")), .empty)
    XCTAssertEqual(connectError(ExternalConnectCode.parse("   ")), .empty)
    XCTAssertEqual(connectError(ExternalConnectCode.parse("not a code")), .unrecognized)
    let http = "Authorization: Bearer \(secret)\nhttp://evil.example/hook"
    let rejected = ExternalConnectCode.parse(http)
    XCTAssertEqual(connectError(rejected), .invalidURL)
    assertNoSecret(connectError(rejected)?.message ?? "")
    // `\n` inside `\none` is a JSON newline, so the secret is rejected.
    let broken = "{\"url\":\"https://assistant.example/hook\",\"authorization\":\"Bearer \(secret)\\none\"}"
    let newline = #"{"url":"https://assistant.example/hook","authorization":"Bearer \#(secret)\nmore"}"#
    XCTAssertEqual(connectError(ExternalConnectCode.parse(newline)), .unsafeAuthorization)
    assertNoSecret(connectError(ExternalConnectCode.parse(newline))?.message ?? "")
    XCTAssertEqual(
      connectError(ExternalConnectCode.encode(url: "http://evil.example/hook", authorization: secret)),
      .invalidURL)
    XCTAssertEqual(
      connectError(
        ExternalConnectCode.encode(url: "https://assistant.example/hook", authorization: "one\ntwo")),
      .unsafeAuthorization)
    assertNoSecret(ExternalConnectCode.Failure.invalidURL.message)
    assertNoSecret(ExternalConnectCode.Failure.unsafeAuthorization.message)
    assertNoSecret(ExternalConnectCode.Failure.unrecognized.message)
    XCTAssertEqual(connectError(ExternalConnectCode.parse(broken)), .unsafeAuthorization)
    assertNoSecret(String(describing: connectError(ExternalConnectCode.parse(broken))))
  }

  func testCapabilitiesAreOptionalAndAreNotPartOfTheSecret() {
    let json = """
      {"authorization":"Bearer secret","capabilities":["cancel","not a secret","cancel"],"url":"https://assistant.example/hook"}
      """
    guard case .success(let credentials) = ExternalConnectCode.parse(json) else {
      return XCTFail("Expected capabilities to be read")
    }
    XCTAssertEqual(credentials.authorization, "Bearer secret")
    XCTAssertEqual(credentials.capabilities, ["cancel"])
    guard
      case .success(let code) = ExternalConnectCode.encode(
        url: credentials.url, authorization: credentials.authorization, capabilities: ["cancel"])
    else { return XCTFail("Expected a setup code with capabilities") }
    guard case .success(let again) = ExternalConnectCode.parse(code) else {
      return XCTFail("Expected the setup code to parse")
    }
    XCTAssertEqual(again.capabilities, ["cancel"])
    XCTAssertFalse(code.contains("Bearer secret"))
    guard case .success(let older) = ExternalConnectCode.parse(canonical) else {
      return XCTFail("Expected an older setup code to parse")
    }
    XCTAssertEqual(older.capabilities, [])
    XCTAssertEqual(
      ExternalConnectCode.encode(url: older.url, authorization: older.authorization),
      .success(canonical))
  }

  func testConnectURLCarriesTheSetupCodeAndIssueLinksStillOpen() throws {
    let code = canonical
    let link = try XCTUnwrap(ExternalConnectCode.deepLink(code: code))
    XCTAssertEqual(link.scheme, "screenclip")
    XCTAssertEqual(link.host, "connect")
    XCTAssertEqual(ScreenClipURL.route(link), .connect(code))
    guard case .success(let credentials) = ExternalConnectCode.parse(link.absoluteString) else {
      return XCTFail("Expected a pasted connect link to parse")
    }
    XCTAssertEqual(credentials.authorization, "Bearer secret")
    let encoded =
      "screenclip://connect?code=screenclip-connect%3Av1%3AeyJhdXRob3JpemF0aW9uIjoiQmVhcmVyIHNlY3JldCIsInVybCI6Imh0dHBzOi8vYXNzaXN0YW50LmV4YW1wbGUvaG9vayJ9"
    let encodedURL = try XCTUnwrap(URL(string: encoded))
    XCTAssertEqual(ScreenClipURL.route(encodedURL), .connect(code))
    guard case .success = ExternalConnectCode.parse("Open \(encoded).") else {
      return XCTFail("Expected a link inside a sentence to parse")
    }
    let upper = try XCTUnwrap(URL(string: "SCREENCLIP://Connect?CODE=\(code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"))
    XCTAssertEqual(ScreenClipURL.route(upper), .connect(code))
    XCTAssertNil(ScreenClipURL.route(try XCTUnwrap(URL(string: "screenclip://connect"))))
    XCTAssertNil(ScreenClipURL.route(try XCTUnwrap(URL(string: "screenclip://connect?code="))))
    XCTAssertNil(ScreenClipURL.route(try XCTUnwrap(URL(string: "https://assistant.example/hook"))))
    let issue = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
    XCTAssertEqual(
      ScreenClipURL.route(try XCTUnwrap(URL(string: "screenclip://issues/\(issue.uuidString)"))),
      .issue(issue))
    XCTAssertEqual(
      ScreenClipURL.route(try XCTUnwrap(URL(string: "screenclip://Issues/\(issue.uuidString.lowercased())"))),
      .issue(issue))
    XCTAssertNil(ScreenClipURL.route(try XCTUnwrap(URL(string: "screenclip://issues/not-a-uuid"))))
    if case .success = ExternalConnectCode.parse("screenclip://issues/\(issue.uuidString)") {
      XCTFail("An issue link is not a setup code")
    }
  }

  private func assertNoSecret(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(text.contains(secret), text, file: file, line: line)
  }

  private func connectError<Value>(
    _ result: Result<Value, ExternalConnectCode.Failure>
  ) -> ExternalConnectCode.Failure? {
    if case .failure(let error) = result { return error }
    return nil
  }
}
