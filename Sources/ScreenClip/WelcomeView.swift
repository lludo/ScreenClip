import ScreenClipCore
import SwiftUI

struct WelcomeView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Image(systemName: "viewfinder").font(.system(size: 45, weight: .light)).foregroundStyle(
        .orange)
      VStack(alignment: .leading, spacing: 10) {
        Text("File bugs as you go, without breaking your flow.")
          .font(.system(size: 28, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text("Capture what you notice. Follow the fix here.").font(.title3).foregroundStyle(
          .secondary)
      }
      VStack(alignment: .leading, spacing: 18) {
        step("1", "Add your projects", "Map a website or Mac app to its repository.")
        step("2", "Connect an agent", agentStepText)
        step("3", "Capture an observation", "Select a region, add a note, and submit.")
      }
      HStack {
        Button("Set up ScreenClip") { model.settingsAction?() }.buttonStyle(.borderedProminent)
          .tint(.orange)
        Button("Take a capture") { model.captureAction?() }
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
    case 2: list = "\(names[0]) and \(names[1])"
    default: list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
    }
    let prefix = ready.isEmpty ? "Works with" : "Connected:"
    return "\(prefix) \(list). Choose a default."
  }
  func step(_ number: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number).font(.caption.weight(.semibold)).frame(width: 24, height: 24).background(
        .quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title).fontWeight(.medium)
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
