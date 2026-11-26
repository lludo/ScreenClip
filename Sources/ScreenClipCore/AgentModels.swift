import Foundation

/// A model an agent can run, with the reasoning efforts it accepts. An empty `efforts`
/// means the model has no effort choice.
public struct AgentModelOption: Equatable, Hashable, Identifiable, Sendable {
  /// The value passed to the agent (`--model` for Claude Code, `model` for Codex).
  public var id: String
  public var title: String
  public var efforts: [String]
  /// The agent's own default effort for this model, when it reports one.
  public var defaultEffort: String?
  /// The agent's default model, when it reports one.
  public var isDefault: Bool
  public init(
    id: String, title: String, efforts: [String] = [], defaultEffort: String? = nil,
    isDefault: Bool = false
  ) {
    self.id = id
    self.title = title
    self.efforts = efforts
    self.defaultEffort = defaultEffort
    self.isDefault = isDefault
  }
}

/// The model and effort choices offered after picking an agent.
public enum AgentModelCatalog {
  /// Claude Code has no command that lists models, so its aliases are listed here. Each alias
  /// follows the latest model of that family. Update this list when Claude Code adds a family
  /// or changes which efforts `--effort` accepts.
  public static let claude: [AgentModelOption] = [
    AgentModelOption(id: "fable", title: "Fable", efforts: allClaudeEfforts),
    AgentModelOption(id: "opus", title: "Opus", efforts: allClaudeEfforts),
    AgentModelOption(id: "sonnet", title: "Sonnet", efforts: ["low", "medium", "high", "max"]),
    AgentModelOption(id: "haiku", title: "Haiku"),
  ]
  static let allClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]

  /// Models to try, in order, when Claude Code reports a usage limit on `model`. A report
  /// should get done on the next best model rather than fail because one model is used up.
  /// `nil` (Claude Code's own default) falls back through the same chain.
  public static func claudeFallbacks(after model: String?) -> [String] {
    let chain = ["fable", "opus", "sonnet"]
    let current = model?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard let index = chain.firstIndex(where: { current.contains($0) })
    else { return current.isEmpty ? ["opus", "sonnet"] : [] }
    return Array(chain[(index + 1)...])
  }

  /// Parses the Codex app-server `model/list` result. Hidden models are left out.
  public static func codex(fromModelList result: JSONValue) -> [AgentModelOption] {
    result["data"].array.compactMap { entry in
      if entry["hidden"].bool == true { return nil }
      guard let id = entry["model"].string ?? entry["id"].string, !id.isEmpty else { return nil }
      let efforts = entry["supportedReasoningEfforts"].array.compactMap {
        $0.string ?? $0["reasoningEffort"].string ?? $0["effort"].string
      }
      let title = entry["displayName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? id
      return AgentModelOption(
        id: id, title: title, efforts: efforts,
        defaultEffort: entry["defaultReasoningEffort"].string,
        isDefault: entry["isDefault"].bool == true)
    }
  }

  /// The model the agent uses when the report does not choose one: the Settings value,
  /// otherwise the model the agent reports as its default.
  public static func defaultModel(
    in options: [AgentModelOption], configured: String?
  ) -> AgentModelOption? {
    if let configured = configured?.trimmingCharacters(in: .whitespaces), !configured.isEmpty {
      return options.first { $0.id == configured }
        ?? AgentModelOption(id: configured, title: configured)
    }
    return options.first(where: \.isDefault)
  }

  /// Keeps a stored choice only while the catalog still offers it. An empty catalog (not
  /// loaded yet) keeps the choice, so a slow `model/list` does not clear it.
  public static func reconcile(
    model: String?, effort: String?, in options: [AgentModelOption]
  ) -> (model: String?, effort: String?) {
    guard let model else { return (nil, nil) }
    if options.isEmpty { return (model, effort) }
    guard let option = options.first(where: { $0.id == model }) else { return (nil, nil) }
    guard let effort, option.efforts.contains(effort) else { return (model, nil) }
    return (model, effort)
  }
}
