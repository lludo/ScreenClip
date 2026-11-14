import ScreenClipCore
import SwiftUI

struct WelcomeView: View {
  @ObservedObject var model: AppModel
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Image(systemName: "viewfinder").font(.system(size: 45, weight: .light)).foregroundStyle(
        .orange)
      VStack(alignment: .leading, spacing: 10) {
        Text(
          chrome: "File bugs as you go, without breaking your flow.",
          comment: "Welcome headline when no report is selected."
        )
        .font(.system(size: 28, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        Text(
          chrome: "Capture what you notice. Follow the fix here.",
          comment: "Welcome subtitle."
        )
        .font(.title3).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 18) {
        step(
          "1",
          Chrome.text("Add your projects", locale: locale, comment: "Welcome step title."),
          Chrome.text(
            "Map a website or Mac app to its repository.", locale: locale,
            comment: "Welcome step explaining project setup."))
        step(
          "2",
          Chrome.text("Connect an agent", locale: locale, comment: "Welcome step title."),
          agentStepText)
        step(
          "3",
          Chrome.text("Capture an observation", locale: locale, comment: "Welcome step title."),
          Chrome.text(
            "Select a region, add a note, and submit.", locale: locale,
            comment: "Welcome step explaining capture."))
      }
      FlowLayout(spacing: 10) {
        Button {
          model.settingsAction?()
        } label: {
          Text(chrome: "Set up ScreenClip", comment: "Opens Settings from the welcome pane.")
        }.buttonStyle(.borderedProminent).tint(.orange)
        Button {
          model.captureAction?()
        } label: {
          Text(chrome: "Take a capture", comment: "Starts a capture from the welcome pane.")
        }
      }
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
  /// Names every agent detected and ready, equally; falls back to all supported agents.
  private var agentStepText: String {
    let ready = model.agentStatuses.filter(\.ready).map { $0.kind.title }
    let names = ready.isEmpty ? AgentKind.allCases.map(\.title) : ready
    let list: String
    switch names.count {
    case 1: list = names[0]
    case 2:
      list = Chrome.format(
        "welcome.pair", "\(names[0]) and \(names[1])", locale: locale,
        comment: "Two agent names joined in a sentence. Both %@ values stay untranslated.")
    default:
      list = Chrome.format(
        "welcome.list", "\(names.dropLast().joined(separator: ", ")), and \(names.last!)",
        locale: locale,
        comment: "Three or more agent names. Both %@ values stay untranslated.")
    }
    let prefix = ready.isEmpty
      ? Chrome.text("Works with", locale: locale, comment: "Welcome step when no agent is connected yet.")
      : Chrome.text("Connected:", locale: locale, comment: "Welcome step listing agents that are ready.")
    return Chrome.format(
      "welcome.agents", "\(prefix) \(list). Choose a default.", locale: locale,
      comment: "Welcome step. %@ is a localized prefix plus agent names.")
  }
  func step(_ number: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(verbatim: number).font(.caption.weight(.semibold)).frame(width: 24, height: 24)
        .background(.quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
