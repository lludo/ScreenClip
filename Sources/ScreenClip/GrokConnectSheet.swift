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
  @State private var sendingTest = false
  @State private var testResult: String?
  @State private var testOK = false
  private var saved: ExternalAssistantConfiguration { model.loadExternalAssistant() }
  private var connected: Bool { saved.isConfigured }
  private var statusText: String {
    let host = saved.endpoint?.host ?? ""
    return connected && !host.isEmpty ? "Connected · \(host)" : "Not connected — Connect Grok Bot"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Image(systemName: connected ? "checkmark.circle.fill" : "xmark.circle")
          .foregroundStyle(connected ? Color.green : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          AgentLabel(kind: .external)
          Text(statusText)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if let testResult {
            Text(testResult).font(.caption).foregroundStyle(testOK ? Color.green : Color.secondary)
              .textSelection(.enabled)
          }
        }
        Spacer(minLength: 12)
        if connected {
          Button(sendingTest ? "Checking…" : "Test again") { testAgain() }.disabled(sendingTest)
          Button("Disconnect") { disconnect() }
        } else {
          Button("Connect Grok Bot", action: onConnect)
        }
      }
      DisclosureGroup("Advanced") {
        TextField("Webhook URL", text: $webhookURL, prompt: Text("https://"))
        SecureField("Authorization header", text: $authorization)
        HStack {
          Button("Disconnect") { disconnect() }
            .disabled(!connected && webhookURL.isEmpty && authorization.isEmpty)
          if sendingTest { ProgressView().controlSize(.small) }
        }
        Text(
          "The address and secret, if you already have them. ScreenClip keeps both in the Keychain and sends the secret unchanged. Save settings stores edits here. Disconnect removes the saved connection."
        ).font(.caption).foregroundStyle(.secondary)
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
      Text("Connect Grok Bot").font(.title2.weight(.semibold))
      step("1", "Ask Grok Bot") {
        Text("In Grok Bot, open your ScreenClip assistant and ask it: \"\(ExternalConnectCode.askPhrase)\"")
        HStack(spacing: 8) {
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ExternalConnectCode.askPhrase, forType: .string)
            copied = true
          }
          if copied {
            Text("Copied").font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("Grok Bot replies with a setup code.").font(.caption).foregroundStyle(.secondary)
      }
      step("2", "Paste the setup code") {
        TextField("Paste the setup code here", text: $code, axis: .vertical)
          .lineLimit(2...5)
          .font(.system(.body, design: .monospaced))
          .textFieldStyle(.roundedBorder)
        if let clipboardOffer, clipboardOffer != code {
          Button("Use code from clipboard") {
            lastAttempt = ""
            if code == clipboardOffer {
              consider(clipboardOffer, aggressive: true)
            } else {
              code = clipboardOffer
            }
          }
        }
      }
      step("3", "Check the connection") {
        if checking {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking the connection…").foregroundStyle(.secondary)
          }
        } else if let outcome {
          if outcome.connected {
            Text("✅ Connected").font(.body.weight(.semibold)).foregroundStyle(.green)
            if let host = outcome.host, !host.isEmpty {
              Text("Grok Bot is connected at \(host).").font(.caption).foregroundStyle(.secondary)
            }
          } else {
            Text(outcome.message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
          }
        } else {
          Text("The check runs as soon as the setup code is in the field.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      projectToggle
      DisclosureGroup("Advanced") {
        TextField("Webhook URL", text: $advancedURL, prompt: Text("https://"))
          .textFieldStyle(.roundedBorder)
        SecureField("Authorization header", text: $advancedAuthorization)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button(checking ? "Checking…" : "Check connection") {
            run(url: advancedURL, authorization: advancedAuthorization)
          }.disabled(checking)
          Button("Disconnect") { disconnect() }
        }
        Text(
          "The address and secret, if you already have them. ScreenClip keeps both in the Keychain and sends the secret unchanged."
        ).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 520)
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
        "Add a project in Settings, then turn on sharing screenshots for it. Approved annotated screenshots are pushed to a branch in the project's GitHub repo. A private repo is recommended."
      ).font(.caption).foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        if model.snapshot.projects.count > 1 {
          Picker("Project", selection: projectSelection) {
            ForEach(model.snapshot.projects) { project in
              Text(project.name.isEmpty ? "Untitled project" : project.name).tag(project.id)
            }
          }
        }
        Toggle(
          "Turn on for this project",
          isOn: Binding(
            get: { model.project(projectSelection.wrappedValue)?.sendsExternalScreenshots == true },
            set: { allowed in
              do {
                try model.setProjectSendsScreenshots(projectSelection.wrappedValue, allowed: allowed)
                projectError = nil
              } catch {
                projectError = error.localizedDescription
              }
            }))
        Text(
          "Approved annotated screenshots are pushed to a branch in the project's GitHub repo. A private repo is recommended."
        ).font(.caption).foregroundStyle(.secondary)
        if let projectError {
          Text(projectError).font(.caption).foregroundStyle(.red)
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
        Text(title).fontWeight(.semibold)
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
      run(url: credentials.url, authorization: credentials.authorization)
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
  private func run(url: String, authorization: String) {
    checkID += 1
    let id = checkID
    checking = true
    outcome = nil
    Task {
      let result = await model.checkGrokConnection(webhookURL: url, authorization: authorization)
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
