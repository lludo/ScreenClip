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
    if case .number(let v) = self { return Int(v) }
    return nil
  }
  public var object: [String: JSONValue] {
    if case .object(let v) = self { return v }
    return [:]
  }
  public static func text(_ value: String) -> JSONValue { .string(value) }
  public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
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
    guard method == "item/commandExecution/requestApproval",
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
