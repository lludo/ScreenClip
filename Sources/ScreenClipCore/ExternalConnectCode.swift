import Foundation

/// Pasted Grok Bot connection text and `screenclip://` routes.
///
/// The sheet asks for the Webhook URL and the `Authorization` header copied from the
/// ScreenClip reports routine. This parser also accepts JSON, a curl command, the
/// canonical `screenclip-connect:v1:` code, and a `screenclip://connect` link.
///
/// Canonical code: `screenclip-connect:v1:` + base64url(JSON). The JSON object is UTF-8,
/// compact, with keys sorted alphabetically:
/// `{"authorization":"<secret>","url":"https://…"}`.
/// base64url is RFC 4648 §5 with the padding `=` removed.
///
/// Nothing in this type writes the secret to a log. Failures carry a fixed message and
/// do not echo the input.
public enum ExternalConnectCode {
  public static let prefix = "screenclip-connect:v1:"

  public struct Credentials: Equatable, Sendable {
    public var url: String
    public var authorization: String
    /// Optional and not secret. Older setup codes omit it. Unknown values are ignored by older apps.
    public var capabilities: [String]
    public init(url: String, authorization: String, capabilities: [String] = []) {
      self.url = url
      self.authorization = authorization
      self.capabilities = capabilities
    }
  }

  public enum Failure: Equatable, Error {
    case empty
    case unrecognized
    case invalidURL
    case unsafeAuthorization
    case missingURL
    case missingAuthorization

    public var message: String {
      switch self {
      case .empty, .missingAuthorization:
        return "Enter the key from the ScreenClip reports routine."
      case .unrecognized:
        return
          "Paste the Webhook URL on one line and the Authorization header on the next. Copy both from the ScreenClip reports routine in Grok Bot."
      case .invalidURL:
        return "The Webhook URL has to start with https."
      case .unsafeAuthorization:
        return "The key can't contain a line break."
      case .missingURL:
        return
          "Add the webhook URL too. Copy it from the ScreenClip reports routine and paste it with the Authorization header."
      }
    }
  }

  /// The Key field accepts a bare key or the full header from the routine panel.
  /// `Authorization:` is removed. Anything that is not already a `Bearer` value gets that prefix.
  public static func normalizeKey(_ raw: String) -> Result<String, Failure> {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty || isBareScheme(value) { return .failure(.missingAuthorization) }
    if let stripped = strippingPrefix(value, "authorization:") {
      value = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.isEmpty || isBareScheme(value) { return .failure(.missingAuthorization) }
    }
    if let token = strippingPrefix(value, "bearer ") {
      let rest = token.trimmingCharacters(in: .whitespaces)
      if rest.isEmpty { return .failure(.missingAuthorization) }
      value = "Bearer " + rest
    } else {
      value = "Bearer " + value
    }
    guard ExternalAssistantConfiguration.isSafeHeaderValue(value) else {
      return .failure(.unsafeAuthorization)
    }
    return .success(value)
  }

  /// `Bearer` or `Authorization:` with no key after it.
  private static func isBareScheme(_ value: String) -> Bool {
    value.caseInsensitiveCompare("bearer") == .orderedSame
      || value.caseInsensitiveCompare("authorization:") == .orderedSame
      || value.caseInsensitiveCompare("authorization") == .orderedSame
  }

  private static func strippingPrefix(_ value: String, _ prefix: String) -> String? {
    guard value.count >= prefix.count else { return nil }
    let head = String(value.prefix(prefix.count))
    guard head.caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
    return String(value.dropFirst(prefix.count))
  }

  public static func encode(
    url: String, authorization: String, capabilities: [String] = []
  ) -> Result<String, Failure> {
    switch validate(Credentials(url: url, authorization: authorization, capabilities: capabilities)) {
    case .failure(let error):
      return .failure(error)
    case .success(let credentials):
      var fields = [
        "\"authorization\":" + jsonString(credentials.authorization),
        "\"url\":" + jsonString(credentials.url),
      ]
      let capabilities = credentials.capabilities.filter {
        $0.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil
      }
      if !capabilities.isEmpty {
        let list = capabilities.map(jsonString).joined(separator: ",")
        fields.append("\"capabilities\":[\(list)]")
      }
      fields.sort()
      return .success(prefix + base64URLEncode(Data(("{" + fields.joined(separator: ",") + "}").utf8)))
    }
  }

  /// Accepts the canonical code, a `screenclip://connect?code=` link, JSON with `url` and
  /// `authorization` (or `header`), a curl command, or a block that contains both an address
  /// and an `Authorization:` line. A URL with no header, or a bare token with no URL, fails
  /// with a message that names the missing piece.
  public static func parse(_ text: String) -> Result<Credentials, Failure> {
    parse(text, depth: 0)
  }

  private static func parse(_ text: String, depth: Int) -> Result<Credentials, Failure> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .failure(.empty) }
    if let token = prefixedToken(in: trimmed) {
      guard let data = decodeToken(token), let credentials = jsonCredentials(data) else {
        return .failure(.unrecognized)
      }
      return validate(credentials)
    }
    if depth < 2, let code = embeddedConnectCode(in: trimmed), code != trimmed {
      return parse(code, depth: depth + 1)
    }
    switch jsonConnect(in: trimmed) {
    case .absent:
      break
    case .credentials(let credentials):
      return validate(credentials)
    case .missingURL:
      return .failure(.missingURL)
    case .missingAuthorization:
      return .failure(.missingAuthorization)
    }
    return parseLoose(trimmed)
  }

  /// `screenclip://connect?code=<percent-encoded setup code>`.
  public static func deepLink(code: String) -> URL? {
    var components = URLComponents()
    components.scheme = "screenclip"
    components.host = "connect"
    components.queryItems = [URLQueryItem(name: "code", value: code)]
    return components.url
  }

  private static func validate(_ credentials: Credentials) -> Result<Credentials, Failure> {
    let configuration = ExternalAssistantConfiguration(
      webhookURL: credentials.url, authorization: credentials.authorization, testSucceeded: false)
    guard configuration.endpoint != nil else { return .failure(.invalidURL) }
    guard configuration.authorizationIsHeaderSafe else {
      return .failure(configuration.normalizedAuthorization.isEmpty ? .empty : .unsafeAuthorization)
    }
    return .success(
      Credentials(
        url: configuration.normalizedURL, authorization: configuration.normalizedAuthorization,
        capabilities: credentials.capabilities))
  }

  private static func parseLoose(_ text: String) -> Result<Credentials, Failure> {
    let foundURLs = urls(in: text)
    let secrets = authorizationValues(in: text).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    if foundURLs.isEmpty && secrets.isEmpty {
      return .failure(looksLikeBareCredential(text) ? .missingURL : .unrecognized)
    }
    if secrets.isEmpty { return .failure(.missingAuthorization) }
    guard let secret = secrets.first(where: ExternalAssistantConfiguration.isSafeHeaderValue) else {
      return .failure(.unsafeAuthorization)
    }
    guard
      let url = foundURLs.first(where: { candidate in
        ExternalAssistantConfiguration(
          webhookURL: candidate, authorization: secret, testSucceeded: false
        ).endpoint != nil
      })
    else {
      return .failure(foundURLs.isEmpty ? .missingURL : .invalidURL)
    }
    return validate(Credentials(url: url, authorization: secret))
  }

  /// A single pasted token, or `Bearer` plus one token, with no webhook URL.
  private static func looksLikeBareCredential(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return false }
    let token: Substring
    let minimum: Int
    if let space = trimmed.firstIndex(where: \.isWhitespace) {
      let head = trimmed[..<space]
      let rest = trimmed[trimmed.index(after: space)...].drop { $0.isWhitespace }
      guard head.caseInsensitiveCompare("Bearer") == .orderedSame, !rest.isEmpty,
        !rest.contains(where: \.isWhitespace)
      else { return false }
      token = rest
      minimum = 1
    } else {
      token = Substring(trimmed)
      minimum = 8
    }
    guard token.count >= minimum else { return false }
    return token.unicodeScalars.allSatisfy { scalar in
      let value = scalar.value
      return value >= 0x21 && value <= 0x7E
    }
  }

  private static func prefixedToken(in text: String) -> String? {
    guard let range = text.range(of: prefix) else { return nil }
    var token = ""
    var index = range.upperBound
    while index < text.endIndex {
      let character = text[index]
      if character.isWhitespace {
        if token.isEmpty {
          index = text.index(after: index)
          continue
        }
        break
      }
      if isTokenCharacter(character) {
        token.append(character)
        index = text.index(after: index)
      } else {
        break
      }
    }
    return token.isEmpty ? nil : token
  }

  private static func isTokenCharacter(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    if ascii >= 65 && ascii <= 90 { return true }
    if ascii >= 97 && ascii <= 122 { return true }
    if ascii >= 48 && ascii <= 57 { return true }
    return character == "-" || character == "_" || character == "=" || character == "+"
      || character == "/"
  }

  private static func embeddedConnectCode(in text: String) -> String? {
    var search = text.startIndex
    while let range = text.range(
      of: "screenclip://", options: .caseInsensitive, range: search..<text.endIndex)
    {
      var end = range.upperBound
      while end < text.endIndex, !text[end].isWhitespace, text[end] != "<", text[end] != ">" {
        end = text.index(after: end)
      }
      var raw = String(text[range.lowerBound..<end])
      while let last = raw.last, ".,);".contains(last) { raw.removeLast() }
      if let url = URL(string: raw), case .connect(let code) = ScreenClipURL.route(url) {
        return code
      }
      search = end == range.lowerBound ? text.index(after: range.lowerBound) : end
    }
    return nil
  }

  private enum JSONConnect {
    case absent
    case credentials(Credentials)
    case missingURL
    case missingAuthorization
  }

  /// A JSON object with only `authorization` (or `header`) is a key without a URL.
  /// An object with only `url` is an address without a key.
  private static func jsonConnect(in text: String) -> JSONConnect {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
      let data = String(text[start...end]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .absent }
    let url = nonempty(stringValue(object, keys: ["url"]))
    let authorization = nonempty(stringValue(object, keys: ["authorization", "header"]))
    switch (url, authorization) {
    case (nil, nil):
      return .absent
    case (nil, .some):
      return .missingURL
    case (.some, nil):
      return .missingAuthorization
    case let (url?, authorization?):
      return .credentials(
        Credentials(url: url, authorization: authorization, capabilities: capabilityList(object)))
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  private static func jsonCredentials(_ data: Data) -> Credentials? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let url = nonempty(stringValue(object, keys: ["url"])),
      let authorization = nonempty(stringValue(object, keys: ["authorization", "header"]))
    else { return nil }
    return Credentials(url: url, authorization: authorization, capabilities: capabilityList(object))
  }

  /// Only short tokens. A capability is not a secret, and a value that looks like one is dropped.
  private static func capabilityList(_ object: [String: Any]) -> [String] {
    guard
      let match = object.first(where: { $0.key.caseInsensitiveCompare("capabilities") == .orderedSame }),
      let values = match.value as? [Any]
    else { return [] }
    var result: [String] = []
    for value in values {
      guard let text = value as? String else { continue }
      let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard token.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil else {
        continue
      }
      if !result.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
        result.append(token)
      }
    }
    return result
  }

  private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
        let value = match.value as? String
      {
        return value
      }
    }
    return nil
  }

  private static func urls(in text: String) -> [String] {
    var found: [String] = []
    var search = text.startIndex
    while search < text.endIndex {
      let https = text.range(of: "https://", range: search..<text.endIndex)
      let http = text.range(of: "http://", range: search..<text.endIndex)
      let start: String.Index
      switch (https?.lowerBound, http?.lowerBound) {
      case (let a?, let b?): start = min(a, b)
      case (let a?, nil): start = a
      case (nil, let b?): start = b
      case (nil, nil): return found
      }
      var end = start
      while end < text.endIndex, !text[end].isWhitespace, !"\"'<>".contains(text[end]) {
        end = text.index(after: end)
      }
      var raw = String(text[start..<end])
      while let last = raw.last, ".,);]\\".contains(last) { raw.removeLast() }
      if !raw.isEmpty { found.append(raw) }
      search = end < text.endIndex ? text.index(after: end) : text.endIndex
    }
    return found
  }

  private static func authorizationValues(in text: String) -> [String] {
    var values: [String] = []
    var rest = Substring(text)
    while let range = rest.range(of: "authorization", options: .caseInsensitive) {
      var index = range.upperBound
      while index < rest.endIndex, rest[index] == " " || rest[index] == "\t" {
        index = rest.index(after: index)
      }
      guard index < rest.endIndex, rest[index] == ":" else {
        rest = rest[range.upperBound...]
        continue
      }
      index = rest.index(after: index)
      while index < rest.endIndex, rest[index] == " " || rest[index] == "\t" {
        index = rest.index(after: index)
      }
      var value = ""
      if index < rest.endIndex, rest[index] == "\"" || rest[index] == "'" {
        let quote = rest[index]
        index = rest.index(after: index)
        while index < rest.endIndex, rest[index] != quote, rest[index] != "\n", rest[index] != "\r" {
          value.append(rest[index])
          index = rest.index(after: index)
        }
      } else {
        // Stop at a quote so `curl -H "Authorization: Bearer secret" https://…`
        // does not swallow the address that follows the header on the same line.
        while index < rest.endIndex, rest[index] != "\n", rest[index] != "\r", rest[index] != "\"",
          rest[index] != "'"
        {
          value.append(rest[index])
          index = rest.index(after: index)
        }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, "\"'\\".contains(last) {
          trimmed.removeLast()
          trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        value = trimmed
      }
      let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleaned.isEmpty { values.append(cleaned) }
      rest = index < rest.endIndex ? rest[rest.index(after: index)...] : rest[rest.endIndex...]
    }
    return values
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeToken(_ token: String) -> Data? {
    var base = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base.count % 4
    if remainder > 0 { base += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base)
  }

  private static func jsonString(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": output += "\\\\"
      case "\"": output += "\\\""
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      default:
        if scalar.value < 0x20 {
          output += String(format: "\\u%04x", scalar.value)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
    return output
  }
}

/// Links the app is registered to open. `screenclip://issues/<uuid>` opens a report.
/// `screenclip://issues/<uuid>/<action>` runs a report action without opening a window, so a
/// script or agent can recover a report; the unguessable id is what authorizes it.
/// `screenclip://connect?code=` opens the Grok Bot setup sheet with that code.
public enum ScreenClipURL {
  /// The buttons a link may press: Reconcile chat, Continue, or both in that order.
  public enum ReportAction: String, Equatable, Sendable, CaseIterable {
    case reconcile, `continue`, resume
  }
  public enum Route: Equatable, Sendable {
    case issue(UUID)
    case issueAction(UUID, ReportAction)
    case connect(String)
  }

  public static func route(_ url: URL) -> Route? {
    guard url.scheme?.caseInsensitiveCompare("screenclip") == .orderedSame else { return nil }
    guard let host = url.host?.lowercased() else { return nil }
    switch host {
    case "connect":
      guard
        let code = query(url, named: "code")?.trimmingCharacters(in: .whitespacesAndNewlines),
        !code.isEmpty
      else { return nil }
      return .connect(code)
    case "issues":
      let parts = url.pathComponents.filter { $0 != "/" }
      guard let first = parts.first, let id = UUID(uuidString: first) else { return nil }
      if parts.count == 1 { return .issue(id) }
      guard parts.count == 2, let action = ReportAction(rawValue: parts[1].lowercased())
      else { return nil }
      return .issueAction(id, action)
    default:
      return nil
    }
  }

  private static func query(_ url: URL, named name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }?.value
  }
}
