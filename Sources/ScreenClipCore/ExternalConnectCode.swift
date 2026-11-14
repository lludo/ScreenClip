import Foundation

/// The copy-paste setup code and `screenclip://` routes for connecting Grok Bot.
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
  public static let askPhrase = "Connect ScreenClip"

  public struct Credentials: Equatable, Sendable {
    public var url: String
    public var authorization: String
    public init(url: String, authorization: String) {
      self.url = url
      self.authorization = authorization
    }
  }

  public enum Failure: Equatable, Error {
    case empty
    case unrecognized
    case invalidURL
    case unsafeAuthorization

    public var message: String {
      switch self {
      case .empty:
        return "Paste the setup code Grok Bot gave you."
      case .unrecognized:
        return
          "That doesn't look like a setup code. In Grok Bot, ask \"\(ExternalConnectCode.askPhrase)\" and paste the reply."
      case .invalidURL:
        return "The address has to start with https. Ask Grok Bot for a new setup code."
      case .unsafeAuthorization:
        return "The secret can't contain a line break. Ask Grok Bot for a new setup code."
      }
    }
  }

  public static func encode(url: String, authorization: String) -> Result<String, Failure> {
    switch validate(Credentials(url: url, authorization: authorization)) {
    case .failure(let error):
      return .failure(error)
    case .success(let credentials):
      let json =
        "{\"authorization\":" + jsonString(credentials.authorization) + ",\"url\":"
        + jsonString(credentials.url) + "}"
      return .success(prefix + base64URLEncode(Data(json.utf8)))
    }
  }

  /// Accepts the canonical code, a `screenclip://connect?code=` link, JSON with `url` and
  /// `authorization` (or `header`), a curl command, or a block that contains both an address
  /// and an `Authorization:` line.
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
    if let credentials = jsonObjectCredentials(in: trimmed) {
      return validate(credentials)
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
      Credentials(url: configuration.normalizedURL, authorization: configuration.normalizedAuthorization))
  }

  private static func parseLoose(_ text: String) -> Result<Credentials, Failure> {
    let foundURLs = urls(in: text)
    let secrets = authorizationValues(in: text).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !foundURLs.isEmpty || !secrets.isEmpty else { return .failure(.unrecognized) }
    guard let secret = secrets.first(where: ExternalAssistantConfiguration.isSafeHeaderValue) else {
      return .failure(secrets.isEmpty ? .unrecognized : .unsafeAuthorization)
    }
    guard
      let url = foundURLs.first(where: { candidate in
        ExternalAssistantConfiguration(
          webhookURL: candidate, authorization: secret, testSucceeded: false
        ).endpoint != nil
      })
    else {
      return .failure(foundURLs.isEmpty ? .unrecognized : .invalidURL)
    }
    return validate(Credentials(url: url, authorization: secret))
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

  private static func jsonObjectCredentials(in text: String) -> Credentials? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
    else { return nil }
    guard let data = String(text[start...end]).data(using: .utf8) else { return nil }
    return jsonCredentials(data)
  }

  private static func jsonCredentials(_ data: Data) -> Credentials? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let url = stringValue(object, keys: ["url"]),
      let authorization = stringValue(object, keys: ["authorization", "header"])
    else { return nil }
    return Credentials(url: url, authorization: authorization)
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
        while index < rest.endIndex, rest[index] != "\n", rest[index] != "\r" {
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
/// `screenclip://connect?code=` opens the Grok Bot setup sheet with that code.
public enum ScreenClipURL {
  public enum Route: Equatable, Sendable {
    case issue(UUID)
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
      guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
      return .issue(id)
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
