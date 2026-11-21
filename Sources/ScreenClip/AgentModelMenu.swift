import ScreenClipCore
import SwiftUI

/// One agent in the composer's agent menu. Choosing the agent keeps its defaults; its submenu
/// chooses a model, and a model's submenu chooses an effort. The default rows say what the
/// default is when the agent reports it.
struct AgentModelMenu: View {
  let kind: AgentKind
  let options: [AgentModelOption]
  let defaultModel: AgentModelOption?
  /// The current model and effort when this agent is the selected one.
  let selected: (model: String?, effort: String?)?
  let isCurrent: Bool
  let locale: Locale
  let choose: (_ model: String?, _ effort: String?) -> Void

  var body: some View {
    if options.isEmpty {
      check(isCurrent, action: { choose(nil, nil) }) { AgentLabel(kind: kind) }
    } else {
      Menu {
        check(isCurrent && selected?.model == nil, action: { choose(nil, nil) }) {
          Text(verbatim: Self.defaultModelTitle(defaultModel, locale: locale))
        }
        Divider()
        ForEach(options) { option in
          if option.efforts.isEmpty {
            check(selected?.model == option.id, action: { choose(option.id, nil) }) {
              Text(verbatim: option.title)
            }
          } else {
            Menu {
              check(
                selected?.model == option.id && selected?.effort == nil,
                action: { choose(option.id, nil) }
              ) {
                Text(verbatim: Self.defaultEffortTitle(option.defaultEffort, locale: locale))
              }
              Divider()
              ForEach(option.efforts, id: \.self) { effort in
                check(
                  selected?.model == option.id && selected?.effort == effort,
                  action: { choose(option.id, effort) }
                ) { Text(verbatim: Self.effortTitle(effort, locale: locale)) }
              }
            } label: {
              Text(verbatim: option.title)
            } primaryAction: {
              choose(option.id, nil)
            }
          }
        }
      } label: {
        AgentLabel(kind: kind)
      } primaryAction: {
        choose(nil, nil)
      }
    }
  }

  /// A menu row with the native checkmark.
  private func check<Label: View>(
    _ on: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label
  ) -> some View {
    Toggle(isOn: Binding(get: { on }, set: { _ in action() }), label: label)
  }

  static func defaultModelTitle(_ model: AgentModelOption?, locale: Locale) -> String {
    guard let model else {
      return Chrome.text("Default model", locale: locale, comment: "Agent menu row that keeps the agent's default model.")
    }
    return Chrome.format(
      "composer.defaultModel", "Default model (\(model.title))", locale: locale,
      comment: "Agent menu row that keeps the agent's default model. %@ is that model's name.")
  }

  static func defaultEffortTitle(_ effort: String?, locale: Locale) -> String {
    guard let effort else {
      return Chrome.text("Default effort", locale: locale, comment: "Agent menu row that keeps the model's default reasoning effort.")
    }
    return Chrome.format(
      "composer.defaultEffort", "Default effort (\(effortTitle(effort, locale: locale)))",
      locale: locale,
      comment: "Agent menu row that keeps the model's default reasoning effort. %@ is that effort level.")
  }

  /// Effort levels the agents use today. An unknown level is shown as the agent spells it.
  static func effortTitle(_ effort: String, locale: Locale) -> String {
    switch effort {
    case "none": return Chrome.text("No reasoning", locale: locale, comment: "Reasoning effort level: none.")
    case "minimal": return Chrome.text("Minimal", locale: locale, comment: "Reasoning effort level.")
    case "low": return Chrome.text("Low", locale: locale, comment: "Reasoning effort level.")
    case "medium": return Chrome.text("Medium", locale: locale, comment: "Reasoning effort level.")
    case "high": return Chrome.text("High", locale: locale, comment: "Reasoning effort level.")
    case "xhigh": return Chrome.text("Extra high", locale: locale, comment: "Reasoning effort level, above high.")
    case "max": return Chrome.text("Max", locale: locale, comment: "Reasoning effort level: the highest.")
    default: return effort.prefix(1).uppercased() + effort.dropFirst()
    }
  }

  /// "Claude Code · Opus · Extra high". A report that keeps the defaults says so, with the
  /// default model when the agent reports it. An agent without model choices shows its name.
  static func summary(
    kind: AgentKind, model: String?, effort: String?, options: [AgentModelOption],
    defaultModel: AgentModelOption?, locale: Locale
  ) -> String {
    var parts = [kind.title]
    if let model {
      parts.append(options.first { $0.id == model }?.title ?? model)
      if let effort { parts.append(effortTitle(effort, locale: locale)) }
    } else if !options.isEmpty {
      parts.append(defaultModelTitle(defaultModel, locale: locale))
    }
    return parts.joined(separator: " · ")
  }
}
