import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @ObservedObject var model: AppModel
  let close: () -> Void
  @State private var settings = AppSettings()
  @State private var editProject: Project?
  @State private var tab = 0
  @State private var error: String?
  @State private var webhookURL = ""
  @State private var authorization = ""
  @State private var externalTestResult: String?
  @State private var sendingTest = false
  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $tab) {
        Form {
          Section("Capture") {
            ScreenCapturePermissionControls(model: model, permission: model.capturePermission)
            LabeledContent("Global shortcut") {
              ShortcutRecorder(settings: $settings).frame(width: 180, height: 26)
            }
            Toggle(
              "Hide ScreenClip during capture",
              isOn: Binding(
                get: { settings.shouldHideScreenClipDuringCapture },
                set: { settings.hideScreenClipDuringCapture = $0 }))
            Text(
              "Leave this off to capture ScreenClip's windows and menu bar popover when reporting bugs in ScreenClip."
            )
            .font(.caption).foregroundStyle(.secondary)
            Toggle(
              "Read the active browser URL for project matching", isOn: $settings.browserContext)
            Text(
              "Safari and Chrome may ask for Automation permission. ScreenClip reads only the active tab when you capture."
            ).font(.caption).foregroundStyle(.secondary)
            TextField("Testing session (optional)", text: $settings.sessionName)
            TextField("Tested build or version (optional)", text: $settings.testedVersion)
          }
          Section("Notifications") {
            Toggle("Notify me about questions and merged fixes", isOn: $settings.notifications)
              .onChange(of: settings.notifications) { _, enabled in
                // Ask only when the user turns it on, not when the saved value loads.
                if enabled && !model.snapshot.settings.notifications {
                  UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                  { granted, _ in
                    if !granted {
                      Task { @MainActor in
                        error =
                          "Notifications are disabled. Enable ScreenClip in System Settings to receive alerts."
                      }
                    }
                  }
                }
              }
          }
          Section("Startup") {
            Toggle(
              "Open ScreenClip at login",
              isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enabled in
                  Task {
                    do {
                      if enabled {
                        try SMAppService.mainApp.register()
                      } else {
                        try await SMAppService.mainApp.unregister()
                      }
                    } catch { self.error = error.localizedDescription }
                  }
                }))
          }
          #if !SCREENCLIP_APP_STORE
          Section("Support") {
            Button("Send a tip…") { model.supportAction?() }
            Text("ScreenClip is free. A tip is optional and opens GitHub Sponsors.")
              .font(.caption).foregroundStyle(.secondary)
          }
          #endif
          Section("Local data") {
            HStack {
              Button("Export queue…") { export() }
              Button("Show storage folder") { NSWorkspace.shared.open(model.store.root) }
            }
            Text(
              "Exports include approved screenshots and notes. Deleting evidence in ScreenClip does not delete the agent's own conversation history or PRs."
            ).font(.caption).foregroundStyle(.secondary)
          }
        }.formStyle(.grouped).tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(
          0)
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Projects").font(.title2.weight(.semibold))
              Text("Teach ScreenClip where each observation belongs.").foregroundStyle(.secondary)
            }
            Spacer()
            Button {
              editProject = Project(name: "", path: "")
            } label: {
              Label("Add project", systemImage: "plus")
            }
          }
          if model.snapshot.projects.isEmpty {
            ContentUnavailableView(
              "Add your first repository", systemImage: "folder.badge.plus",
              description: Text("Map a website or Mac app and set the checks a fix must pass."))
          } else {
            List(model.snapshot.projects) { project in
              HStack {
                VStack(alignment: .leading, spacing: 5) {
                  Text(project.name).fontWeight(.medium)
                  Text(project.path).font(.caption).foregroundStyle(.secondary)
                  Text((project.origins + project.bundleIDs).joined(separator: " · ")).font(
                    .caption
                  ).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Edit") { editProject = project }
              }.padding(.vertical, 8)
            }
          }
        }.padding(24).tabItem { Label("Projects", systemImage: "folder") }.tag(1)
        Form {
          Section("AI agent") {
            Picker(
              "Default agent",
              selection: Binding(
                get: { settings.preferredAgent }, set: { settings.defaultAgent = $0 })
            ) {
              ForEach(agentChoices) { kind in
                Text(model.detection(kind)?.label ?? kind.title).tag(kind)
              }
            }
            ForEach(AgentKind.allCases) { kind in
              AgentDetectionRow(kind: kind, detection: model.detection(kind))
            }
            HStack {
              Button(model.detectingAgents ? "Detecting…" : "Detect agents") { detectAgents() }
                .disabled(model.detectingAgents)
              Spacer()
            }
            Stepper(
              "Run up to \(settings.parallelReportLimit) reports per project at once",
              value: Binding(
                get: { settings.parallelReportLimit }, set: { settings.maxParallelReports = $0 }),
              in: AppSettings.parallelReportRange)
            Text(
              "New captures use the default agent. You can pick a different agent for any single report in the capture window. Each issue keeps the agent it started with. Grok Bot is ready when its webhook is saved below."
            ).font(.caption).foregroundStyle(.secondary)
          }
          Section("External assistant") {
            TextField("Webhook URL", text: $webhookURL, prompt: Text("https://"))
            SecureField("Authorization header", text: $authorization)
            Text(
              "Paste the Webhook URL and the Authorization header from the Grok Bot routine panel. ScreenClip sends that header value as the HTTP Authorization header and does not add a prefix. Both are stored in the Keychain, not in the queue database."
            ).font(.caption).foregroundStyle(.secondary)
            HStack {
              Button(sendingTest ? "Sending…" : "Send test") { sendExternalTest() }
                .disabled(
                  sendingTest || webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              if sendingTest { ProgressView().controlSize(.small) }
            }
            if let externalTestResult {
              Text(externalTestResult).font(.caption).foregroundStyle(.secondary).textSelection(
                .enabled)
            }
            Text(
              "Send test posts {\"schema\":\"screenclip.external.v1.test\"} and shows the HTTP result. Grok Bot is listed as Detected once both values are saved; a successful test is optional."
            ).font(.caption).foregroundStyle(.secondary)
          }
          Section("Claude Code") {
            TextField(
              "Claude Code executable",
              text: Binding(get: { settings.claudePath ?? "" }, set: { settings.claudePath = $0 }),
              prompt: Text(AgentDetector.defaultClaudePath().isEmpty
                ? "Not found" : AgentDetector.defaultClaudePath()))
            HStack {
              Button("Choose…") { chooseExecutable { settings.claudePath = $0 } }
              Button("Sign in to Claude") {
                model.saveSettings(settings)
                model.signInToClaude()
              }
              Button("Check") { detectAgents() }
            }
            TextField(
              "Model (empty uses Claude Code's default)",
              text: Binding(get: { settings.claudeModel ?? "" }, set: { settings.claudeModel = $0 }),
              prompt: Text("e.g. opus, sonnet"))
            Text(
              "Runs claude -p in each issue's isolated worktree with edits auto-approved and Bash inside Claude Code's sandbox. git push and gh are blocked; ScreenClip validates, commits, and opens the PR itself. Sign-in opens Terminal for claude auth login."
            ).font(.caption).foregroundStyle(.secondary)
          }
          Section("Codex") {
            TextField("Codex executable", text: $settings.codexPath)
            CodexConnectionControls(
              model: model, authentication: model.worker.authentication,
              choose: { chooseExecutable { settings.codexPath = $0 } },
              check: connect,
              signIn: { method in
                model.saveSettings(settings)
                Task { await model.worker.signIn(method: method) }
              })
            TextField("Model (empty uses Codex's default)", text: $settings.model)
            Text(
              "Use an installed Codex CLI that supports app-server. A detected desktop-bundled runtime can be used for development; it is not redistributed with ScreenClip."
            ).font(.caption).foregroundStyle(.secondary)
          }
          Section("GitHub") {
            TextField("GitHub CLI executable", text: $settings.ghPath)
            Button("Check GitHub sign-in") {
              Task {
                do {
                  _ = try await CommandRunner.checked(settings.ghPath, ["auth", "status"])
                  error = "GitHub sign-in is ready."
                } catch { self.error = "GitHub needs setup: " + error.localizedDescription }
              }
            }
            Text(
              "Authenticate GitHub CLI with gh auth login. Fixes are published from isolated branches; project checks and required reviews govern automatic merge."
            ).font(.caption).foregroundStyle(.secondary)
          }
        }.formStyle(.grouped).tabItem {
          Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
        }.tag(2)
      }
      Divider()
      HStack {
        if let error {
          Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(
            .enabled)
        }
        Spacer()
        Button("Save settings") {
          do {
            try model.saveExternalAssistant(webhookURL: webhookURL, authorization: authorization)
            model.saveSettings(settings)
            Task { await model.refreshAgents() }
            close()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut("s", modifiers: .command)
      }.padding(16)
    }.frame(width: 700, height: 680)
      .onAppear {
        settings = model.snapshot.settings
        let connection = model.loadExternalAssistant()
        webhookURL = connection.webhookURL
        authorization = connection.authorization
        if model.snapshot.projects.isEmpty { tab = 1 }
      }
      .sheet(item: $editProject) { project in ProjectEditor(model: model, project: project) }
  }
  private var agentChoices: [AgentKind] {
    let available = model.availableAgents
    return AgentKind.allCases.filter { available.contains($0) || $0 == settings.preferredAgent }
  }
  private func detectAgents() {
    do {
      try model.saveExternalAssistant(webhookURL: webhookURL, authorization: authorization)
    } catch {
      self.error = error.localizedDescription
      return
    }
    model.saveSettings(settings)
    Task { await model.refreshAgents() }
  }
  private func sendExternalTest() {
    sendingTest = true
    externalTestResult = nil
    let url = webhookURL
    let header = authorization
    Task {
      let result = await model.sendExternalAssistantTest(webhookURL: url, authorization: header)
      externalTestResult = result
      sendingTest = false
    }
  }
  private func chooseExecutable(_ assign: (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.showsHiddenFiles = true
    if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
  }
  private func connect() {
    model.saveSettings(settings)
    Task {
      await model.worker.resetConnection()
      await model.worker.checkConnection()
    }
  }
  private func export() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Export here"
    if panel.runModal() == .OK, let root = panel.url {
      do {
        let folder = root.appendingPathComponent(
          "ScreenClip Export " + Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        )
        try model.store.export(to: folder)
        NSWorkspace.shared.open(folder)
      } catch { self.error = error.localizedDescription }
    }
  }
}
