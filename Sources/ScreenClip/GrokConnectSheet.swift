import ScreenClipCore
import SwiftUI

struct GrokBotConnectionRow: View {
  @ObservedObject var model: AppModel
  @Binding var webhookURL: String
  @Binding var authorization: String
  let onConnect: () -> Void
  init(
    model: AppModel, webhookURL: Binding<String>, authorization: Binding<String>,
    onConnect: @escaping () -> Void
  ) {
    self.model = model
    self._webhookURL = webhookURL
    self._authorization = authorization
    self.onConnect = onConnect
  }
  @Environment(\.locale) private var locale
  @State private var sendingTest = false
  @State private var testResult: String?
  @State private var testOK = false
  private var saved: ExternalAssistantConfiguration { model.loadExternalAssistant() }
  private var connected: Bool { saved.isConfigured }
  private var statusText: String {
    let host = saved.endpoint?.host ?? ""
    if connected && !host.isEmpty {
      return Chrome.format(
        "grok.connectedHost", "Connected · \(host)", locale: locale,
        comment: "Grok Bot is connected. %@ is the webhook host.")
    }
    return Chrome.text(
      "Not connected — Connect Grok Bot", locale: locale,
      comment: "Grok Bot has not been connected.")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Image(systemName: connected ? "checkmark.circle.fill" : "xmark.circle")
          .foregroundStyle(connected ? Color.green : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          AgentLabel(kind: .external)
          Text(verbatim: statusText)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if let testResult {
            Text(verbatim: Chrome.stored(testResult, locale: locale))
              .font(.caption).foregroundStyle(testOK ? Color.green : Color.secondary)
              .textSelection(.enabled)
          }
        }
        Spacer(minLength: 12)
        if connected {
          Button {
            testAgain()
          } label: {
            if sendingTest {
              Text(chrome: "Checking…", comment: "A Grok Bot check is in progress.")
            } else {
              Text(chrome: "Test again", comment: "Rechecks the saved Grok Bot connection.")
            }
          }.disabled(sendingTest)
          Button { disconnect() } label: {
            Text(chrome: "Disconnect", comment: "Removes the saved Grok Bot connection.")
          }
        } else {
          Button(action: onConnect) {
            Text(chrome: "Connect Grok Bot", comment: "Opens the Grok Bot setup sheet.")
          }
        }
      }
      DisclosureGroup {
        TextField(text: $webhookURL, prompt: Text(verbatim: "https://")) {
          Text(chrome: "Webhook URL", comment: "Grok Bot address field.")
        }
        SecureField(text: $authorization) {
          Text(chrome: "Authorization header", comment: "Grok Bot secret field.")
        }
        HStack {
          Button { disconnect() } label: {
            Text(chrome: "Disconnect", comment: "Removes the saved Grok Bot connection.")
          }.disabled(!connected && webhookURL.isEmpty && authorization.isEmpty)
          if sendingTest { ProgressView().controlSize(.small) }
        }
        Text(
          chrome:
            "The address and secret, if you already have them. ScreenClip keeps both in the Keychain and sends the secret unchanged. Save settings stores edits here. Disconnect removes the saved connection.",
          comment: "Explains the advanced Grok Bot fields. Keep ScreenClip and Keychain."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } label: {
        Text(chrome: "Advanced", comment: "Shows the saved Grok Bot address and secret.")
      }
    }
  }
  private func testAgain() {
    let saved = model.loadExternalAssistant()
    sendingTest = true
    testResult = nil
    Task {
      let result = await model.checkGrokConnection(
        webhookURL: saved.webhookURL, authorization: saved.authorization)
      testOK = result.connected
      testResult = result.connected ? "✅ Connected" : result.message
      sendingTest = false
    }
  }
  private func disconnect() {
    do {
      try model.disconnectExternalAssistant()
      webhookURL = ""
      authorization = ""
      testResult = nil
      Task { await model.refreshAgents() }
    } catch {
      testOK = false
      testResult = error.localizedDescription
    }
  }
}

struct GrokConnectSheet: View {
  @ObservedObject var model: AppModel
  let initialCode: String?
  let projectID: UUID?
  let onSaved: () -> Void
  init(model: AppModel, initialCode: String?, projectID: UUID?, onSaved: @escaping () -> Void) {
    self.model = model
    self.initialCode = initialCode
    self.projectID = projectID
    self.onSaved = onSaved
  }
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var code = ""
  @State private var copied = false
  @State private var clipboardOffer: String?
  @State private var checking = false
  @State private var checkID = 0
  @State private var outcome: GrokConnectionCheck?
  @State private var selectedProjectID: UUID?
  @State private var projectError: String?
  @State private var advancedURL = ""
  @State private var advancedAuthorization = ""
  @State private var lastAttempt = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(chrome: "Connect Grok Bot", comment: "Setup sheet title.").font(.title2.weight(.semibold))
      step("1", Chrome.text("Ask Grok Bot", locale: locale, comment: "First setup step.")) {
        Text(
          verbatim: Chrome.format(
            "grok.ask",
            "In Grok Bot, open your ScreenClip assistant and ask it: \"\(ExternalConnectCode.askPhrase)\"",
            locale: locale,
            comment: "Tells the person what to ask. %@ is the English phrase sent to Grok Bot.")
        ).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ExternalConnectCode.askPhrase, forType: .string)
            copied = true
          } label: {
            Text(chrome: "Copy", comment: "Copies the English phrase to ask Grok Bot.")
          }
          if copied {
            Text(chrome: "Copied", comment: "The phrase is on the clipboard.").font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(chrome: "Grok Bot replies with a setup code.", comment: "What comes back from Grok Bot.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      step("2", Chrome.text("Paste the setup code", locale: locale, comment: "Second setup step.")) {
        TextField(text: $code, axis: .vertical) {
          Text(chrome: "Paste the setup code here", comment: "Setup code field.")
        }
          .lineLimit(2...5)
          .font(.system(.body, design: .monospaced))
          .textFieldStyle(.roundedBorder)
        if let clipboardOffer, clipboardOffer != code {
          Button {
            lastAttempt = ""
            if code == clipboardOffer {
              consider(clipboardOffer, aggressive: true)
            } else {
              code = clipboardOffer
            }
          } label: {
            Text(chrome: "Use code from clipboard", comment: "Fills the setup code from the clipboard.")
          }
        }
      }
      step("3", Chrome.text("Check the connection", locale: locale, comment: "Third setup step.")) {
        if checking {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(chrome: "Checking the connection…", comment: "A Grok Bot check is in progress.")
              .foregroundStyle(.secondary)
          }
        } else if let outcome {
          if outcome.connected {
            Text(chrome: "✅ Connected", comment: "The Grok Bot check succeeded.")
              .font(.body.weight(.semibold)).foregroundStyle(.green)
            if let host = outcome.host, !host.isEmpty {
              Text(
                verbatim: Chrome.format(
                  "grok.connectedAt", "Grok Bot is connected at \(host).", locale: locale,
                  comment: "Successful check. %@ is the webhook host.")
              ).font(.caption).foregroundStyle(.secondary)
            }
          } else {
            Text(verbatim: Chrome.stored(outcome.message, locale: locale))
              .font(.callout).foregroundStyle(.red).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          Text(
            chrome: "The check runs as soon as the setup code is in the field.",
            comment: "The connection check starts automatically."
          ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Divider()
      projectToggle
      DisclosureGroup {
        TextField(text: $advancedURL, prompt: Text(verbatim: "https://")) {
          Text(chrome: "Webhook URL", comment: "Grok Bot address field.")
        }.textFieldStyle(.roundedBorder)
        SecureField(text: $advancedAuthorization) {
          Text(chrome: "Authorization header", comment: "Grok Bot secret field.")
        }.textFieldStyle(.roundedBorder)
        HStack {
          Button {
            run(url: advancedURL, authorization: advancedAuthorization)
          } label: {
            if checking {
              Text(chrome: "Checking…", comment: "A Grok Bot check is in progress.")
            } else {
              Text(chrome: "Check connection", comment: "Checks the address and secret typed above.")
            }
          }.disabled(checking)
          Button { disconnect() } label: {
            Text(chrome: "Disconnect", comment: "Removes the saved Grok Bot connection.")
          }
        }
        Text(
          chrome:
            "The address and secret, if you already have them. ScreenClip keeps both in the Keychain and sends the secret unchanged.",
          comment: "Explains the advanced Grok Bot fields. Keep ScreenClip and Keychain."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } label: {
        Text(chrome: "Advanced", comment: "Shows the saved Grok Bot address and secret.")
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
    .onAppear {
      let saved = model.loadExternalAssistant()
      advancedURL = saved.webhookURL
      advancedAuthorization = saved.authorization
      if let projectID, model.project(projectID) != nil {
        selectedProjectID = projectID
      } else {
        selectedProjectID = model.snapshot.projects.first?.id
      }
      if let text = NSPasteboard.general.string(forType: .string), text.count <= 4_000,
        case .success = ExternalConnectCode.parse(text)
      {
        clipboardOffer = text
      }
      if let initialCode, !initialCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        code = initialCode
        consider(initialCode, aggressive: true)
      }
    }
    .onChange(of: code) { old, new in
      let jump = abs(new.count - old.count) > 1 || new.contains("\n")
      consider(new, aggressive: jump)
    }
  }
  private var projectSelection: Binding<UUID> {
    Binding(
      get: { selectedProjectID ?? model.snapshot.projects.first?.id ?? UUID() },
      set: { selectedProjectID = $0 })
  }
  @ViewBuilder private var projectToggle: some View {
    if model.snapshot.projects.isEmpty {
      Text(
        chrome:
          "Add a project in Settings, then turn on sharing screenshots for it. Approved annotated screenshots are pushed to a branch in the project's GitHub repo. A private repo is recommended.",
        comment: "Shown when no project exists yet. Keep GitHub."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        if model.snapshot.projects.count > 1 {
          Picker(selection: projectSelection) {
            ForEach(model.snapshot.projects) { project in
              Text(verbatim: project.name.isEmpty
                ? Chrome.text("Untitled project", locale: locale, comment: "A project with no name.")
                : project.name
              ).tag(project.id)
            }
          } label: {
            Text(chrome: "Project", comment: "Project picker in the Grok Bot sheet.")
          }
        }
        Toggle(
          isOn: Binding(
            get: { model.project(projectSelection.wrappedValue)?.sendsExternalScreenshots == true },
            set: { allowed in
              do {
                try model.setProjectSendsScreenshots(projectSelection.wrappedValue, allowed: allowed)
                projectError = nil
              } catch {
                projectError = error.localizedDescription
              }
            })) {
          Text(chrome: "Turn on for this project", comment: "Opts this project into sharing screenshots.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          chrome:
            "Approved annotated screenshots are pushed to a branch in the project's GitHub repo. A private repo is recommended.",
          comment: "Explains screenshot sharing. Keep GitHub."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let projectError {
          Text(verbatim: Chrome.stored(projectError, locale: locale)).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
  private func step<Content: View>(
    _ number: String, _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number).font(.caption.weight(.semibold)).frame(width: 22, height: 22).background(
        .quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
        content()
      }
    }
  }
  private func consider(_ raw: String, aggressive: Bool) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      checkID += 1
      checking = false
      outcome = nil
      lastAttempt = ""
      return
    }
    if trimmed == lastAttempt && (checking || outcome?.connected == true) { return }
    switch ExternalConnectCode.parse(trimmed) {
    case .success(let credentials):
      lastAttempt = trimmed
      run(
        url: credentials.url, authorization: credentials.authorization,
        capabilities: credentials.capabilities)
    case .failure(let error):
      let show = aggressive || trimmed.count >= ExternalConnectCode.prefix.count
      guard show else { return }
      checkID += 1
      checking = false
      lastAttempt = trimmed
      outcome = GrokConnectionCheck(
        connected: false, message: error.message, host: nil, stored: false)
    }
  }
  private func run(url: String, authorization: String, capabilities: [String]? = nil) {
    checkID += 1
    let id = checkID
    checking = true
    outcome = nil
    Task {
      let result = await model.checkGrokConnection(
        webhookURL: url, authorization: authorization, capabilities: capabilities)
      guard id == checkID else { return }
      checking = false
      outcome = result
      if result.stored {
        let saved = model.loadExternalAssistant()
        advancedURL = saved.webhookURL
        advancedAuthorization = saved.authorization
        onSaved()
      }
    }
  }
  private func disconnect() {
    checkID += 1
    checking = false
    do {
      try model.disconnectExternalAssistant()
      advancedURL = ""
      advancedAuthorization = ""
      code = ""
      outcome = nil
      lastAttempt = ""
      onSaved()
      Task { await model.refreshAgents() }
    } catch {
      outcome = GrokConnectionCheck(
        connected: false, message: error.localizedDescription, host: nil, stored: false)
    }
  }
}
