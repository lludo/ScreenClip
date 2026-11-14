import ScreenClipCore
import SwiftUI

struct GrokConnectSheet: View {
  @ObservedObject var model: AppModel
  let initialCode: String?
  let onSaved: () -> Void
  init(model: AppModel, initialCode: String?, projectID: UUID?, onSaved: @escaping () -> Void) {
    self.model = model
    self.initialCode = initialCode
    self.onSaved = onSaved
    _ = projectID
  }
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var webhookURL = ""
  @State private var key = ""
  @State private var checking = false
  @State private var checkID = 0
  @State private var outcome: GrokConnectionCheck?
  @State private var applyingPaste = false
  @State private var pastedCapabilities: [String]?
  private let placeholder = "https://api2.cursor.sh/automations/webhook/…"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: ProviderPhrase.connect.localized(.external, locale: locale))
        .font(.title2.weight(.semibold))
      Text(
        chrome:
          "In Grok Bot, open your ScreenClip assistant's info pane, open the ScreenClip reports routine, and copy these two values.",
        comment: "Where to copy the Grok Bot webhook. Keep ScreenClip, Grok Bot, and ScreenClip reports."
      ).fixedSize(horizontal: false, vertical: true)
      labeledField(
        title: Chrome.text("Webhook URL", locale: locale, comment: "Grok Bot address field."),
        help: Chrome.text("Copy 'POST to'.", locale: locale, comment: "Copy the POST to row from the Grok Bot routine.")
      ) {
        TextField(text: $webhookURL, prompt: Text(verbatim: placeholder)) {
          Text(chrome: "Webhook URL", comment: "Grok Bot address field.")
        }
        .textFieldStyle(.roundedBorder)
      }
      labeledField(
        title: Chrome.text("Key", locale: locale, comment: "Grok Bot key field."),
        help: Chrome.text(
          "Copy 'key' (or 'header').", locale: locale,
          comment: "Copy the key or header row from the Grok Bot routine.")
      ) {
        SecureField(text: $key) {
          Text(chrome: "Key", comment: "Grok Bot key field.")
        }
        .textFieldStyle(.roundedBorder)
      }
      HStack(spacing: 12) {
        Button(action: connect) {
          Text(verbatim: ProviderPhrase.connect.localized(.external, locale: locale))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(checking)
        if checking {
          ProgressView().controlSize(.small)
          Text(chrome: "Checking the connection…", comment: "A Grok Bot check is in progress.")
            .foregroundStyle(.secondary)
        }
      }
      if let outcome {
        if outcome.connected {
          Text(chrome: "✅ Connected", comment: "The Grok Bot check succeeded.")
            .font(.body.weight(.semibold)).foregroundStyle(.green)
          if let host = outcome.host, !host.isEmpty {
            Text(
              verbatim: ProviderPhrase.readyDetailLocalized(kind: .external, extra: host, locale: locale)
            ).font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Text(verbatim: Chrome.stored(outcome.message, locale: locale))
            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Spacer()
        Button { dismiss() } label: {
          Text(chrome: "Done", comment: "Closes the Grok Bot setup sheet.")
        }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(minWidth: 520, idealWidth: 640, maxWidth: 720)
    .onAppear(perform: load)
    .onChange(of: webhookURL) { _, newValue in
      guard !applyingPaste else { return }
      guard case .success(let credentials) = ExternalConnectCode.parse(newValue) else { return }
      applyingPaste = true
      webhookURL = credentials.url
      key = credentials.authorization
      pastedCapabilities = credentials.capabilities
      applyingPaste = false
    }
  }

  private func labeledField<Content: View>(
    title: String, help: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: title).fontWeight(.semibold)
      content()
      Text(verbatim: help).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func load() {
    let saved = model.loadExternalAssistant()
    webhookURL = saved.webhookURL
    key = saved.authorization
    guard let initialCode, !initialCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      case .success(let credentials) = ExternalConnectCode.parse(initialCode)
    else { return }
    applyingPaste = true
    webhookURL = credentials.url
    key = credentials.authorization
    pastedCapabilities = credentials.capabilities
    applyingPaste = false
  }

  private func connect() {
    let url = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpoint = ExternalAssistantConfiguration(
      webhookURL: url, authorization: "Bearer check", testSucceeded: false
    ).endpoint
    guard endpoint != nil else {
      outcome = GrokConnectionCheck(
        connected: false, message: ExternalConnectCode.Failure.invalidURL.message, host: nil,
        stored: false)
      return
    }
    switch ExternalConnectCode.normalizeKey(key) {
    case .failure(let error):
      outcome = GrokConnectionCheck(
        connected: false, message: error.message, host: nil, stored: false)
    case .success(let authorization):
      checkID += 1
      let id = checkID
      checking = true
      outcome = nil
      let capabilities = pastedCapabilities
      Task {
        let result = await model.checkGrokConnection(
          webhookURL: url, authorization: authorization, capabilities: capabilities)
        guard id == checkID else { return }
        checking = false
        outcome = result
        if result.stored {
          let saved = model.loadExternalAssistant()
          webhookURL = saved.webhookURL
          key = saved.authorization
          onSaved()
        }
      }
    }
  }
}
