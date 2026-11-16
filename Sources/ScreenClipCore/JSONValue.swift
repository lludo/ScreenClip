import Foundation

/// Untyped JSON for agent protocols and persisted request payloads.
public indirect enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  public subscript(_ key: String) -> JSONValue {
    if case .object(let v) = self { return v[key] ?? .null }
    return .null
  }
  public var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  public var array: [JSONValue] {
    if case .array(let v) = self { return v }
    return []
  }
  public var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  public var int: Int? {
    if case .number(let v) = self { return Int(exactly: v) }
    return nil
  }
  public var object: [String: JSONValue] {
    if case .object(let v) = self { return v }
    return [:]
  }
  public static func text(_ value: String) -> JSONValue { .string(value) }
  public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// Only these app-server requests have a reply UI and response format in ScreenClip.
public enum CodexRequestKind: Equatable, Sendable {
  case userInput, commandApproval, fileApproval, mcpElicitation, unsupported
  public init(method: String?) {
    switch method {
    case "item/tool/requestUserInput": self = .userInput
    case "item/commandExecution/requestApproval": self = .commandApproval
    case "item/fileChange/requestApproval": self = .fileApproval
    case "mcpServer/elicitation/request": self = .mcpElicitation
    default: self = .unsupported
    }
  }
  /// Command and file approvals only; MCP elicitations use a different response format.
  public var isApproval: Bool { self == .commandApproval || self == .fileApproval }
}

/// One `mcpServer/elicitation/request`. ScreenClip owns the chat, so Codex Desktop cannot answer it.
public struct CodexMcpElicitation {
  public let params: JSONValue
  public init(params: JSONValue) { self.params = params }
  /// A yes/no tool permission (for example Computer Use asking to control an app): nothing to fill in.
  public var isToolApproval: Bool {
    params["mode"].string == "form"
      && params["_meta"]["codex_approval_kind"].string == "mcp_tool_call"
      && params["requestedSchema"]["properties"].object.isEmpty
  }
  /// Remember choices Codex offered for this request: `session` and/or `always`.
  public func offersPersist(_ scope: String) -> Bool {
    let offered = params["_meta"]["persist"]
    return offered.string == scope || offered.array.contains(.string(scope))
  }
  /// Tool and displayed arguments, for example `get_app_state · App: WindowManager`.
  public var detail: String? {
    let meta = params["_meta"]
    let arguments = meta["tool_params_display"].array.compactMap { item -> String? in
      guard let value = item["value"].string else { return nil }
      return (item["display_name"].string ?? item["name"].string).map { "\($0): \(value)" } ?? value
    }
    let parts = [meta["tool_name"].string].compactMap { $0 } + arguments
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
  /// The response for a decision, or nil when Codex did not offer it. Never invents form content.
  public func response(allow: Bool, persist: String? = nil, cancel: Bool = false) -> JSONValue? {
    guard allow else { return .object(["action": .string(cancel ? "cancel" : "decline")]) }
    guard isToolApproval else { return nil }
    var result: [String: JSONValue] = ["action": .string("accept"), "content": .object([:])]
    if let persist {
      guard offersPersist(persist) else { return nil }
      result["_meta"] = .object(["persist": .string(persist)])
    }
    return .object(result)
  }
}

/// Decisions offered by Codex for one approval request. Never invent a command rule.
public struct CodexApprovalOptions {
  public let params: JSONValue
  public let method: String
  public init(method: String, params: JSONValue) {
    self.method = method
    self.params = params
  }
  public func permits(_ decision: String) -> Bool {
    let offered = params["availableDecisions"]
    return offered == .null || offered.array.contains(.string(decision))
  }
  public var commandRule: [String]? {
    guard CodexRequestKind(method: method) == .commandApproval,
      params["networkApprovalContext"] == .null else { return nil }
    let proposed = params["proposedExecpolicyAmendment"].array
    guard !proposed.isEmpty, proposed.allSatisfy({ $0.string != nil }) else { return nil }
    let offered = params["availableDecisions"]
    let rule = JSONValue.object(["acceptWithExecpolicyAmendment": .object([
      "execpolicy_amendment": .array(proposed)
    ])])
    guard offered == .null || offered.array.contains(rule) else { return nil }
    return proposed.compactMap(\.string)
  }
  public var ruleDecision: JSONValue? {
    guard let commandRule else { return nil }
    return .object(["acceptWithExecpolicyAmendment": .object([
      "execpolicy_amendment": .array(commandRule.map(JSONValue.string))
    ])])
  }
}
