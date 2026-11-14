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
          Chrome.text(
            "Codex, Claude Code, or Grok Bot. Choose a default.", locale: locale,
            comment: "Welcome step. Product names stay untranslated."))
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
