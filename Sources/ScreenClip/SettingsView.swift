import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @ObservedObject var model: AppModel
  let close: () -> Void
  var initialTab = 0
  @Environment(\.locale) private var locale
  @State private var settings = AppSettings()
  @State private var editProject: Project?
  @State private var tab = 0
  @State private var error: String?
  @State private var webhookURL = ""
  @State private var authorization = ""
  @State private var showingGrokConnect = false
  @State private var grokConnectCode: String?
  @State private var grokConnectPresentation = 0
  @State private var testingGrok = false
  @State private var grokTestResult: String?
  @State private var grokTestOK = false
  var body: some View {
    VStack(spacing: 0) {
      Group {
        if tab == 0 { generalSettings }
        else if tab == 1 { projectSettings }
        else { connectionSettings }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack {
        if let error {
          Text(verbatim: Chrome.stored(error, locale: locale)).font(.caption)
            .foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        Spacer()
        Button {
          do {
            try model.saveExternalAssistant(webhookURL: webhookURL, authorization: authorization)
            model.saveSettings(settings)
            Task { await model.refreshAgents() }
            close()
          } catch { self.error = error.localizedDescription }
        } label: {
          Text(chrome: "Save settings", comment: "Saves settings and closes the window.")
        }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut("s", modifiers: .command)
      }.padding(16)
    }.frame(minWidth: 720, idealWidth: 780, minHeight: 680)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker(selection: $tab) {
            ForEach(Array(["General", "Projects", "Connections"].enumerated()), id: \.offset) {
              index, title in
              Text(verbatim: Chrome.stored(title, locale: locale)).tag(index)
            }
          } label: {
            Text(verbatim: Chrome.stored("Settings", locale: locale))
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .buttonBorderShape(.capsule)
        }
      }
      .onAppear {
        settings = model.snapshot.settings
        reloadGrokConnection()
        if model.snapshot.projects.isEmpty { tab = 1 }
        if initialTab != 0 { tab = initialTab }
        presentGrokConnectIfNeeded()
      }
      .onChange(of: model.grokConnectRequest?.id) { _, id in
        guard id != nil else { return }
        presentGrokConnectIfNeeded()
      }
      .sheet(item: $editProject) { project in ProjectEditor(model: model, project: project) }
      .background {
        Color.clear.sheet(isPresented: $showingGrokConnect, onDismiss: {
          model.grokConnectRequest = nil
        }) {
          GrokConnectSheet(
            model: model, initialCode: grokConnectCode, projectID: nil, onSaved: reloadGrokConnection
          ).id(grokConnectPresentation)
        }
      }
  }
  private var generalSettings: some View {
        Form {
          Section {
            ScreenCapturePermissionControls(model: model, permission: model.capturePermission)
            LabeledContent {
              ShortcutRecorder(settings: $settings).frame(minWidth: 160, idealWidth: 200).frame(height: 26)
            } label: {
              Text(chrome: "Global shortcut", comment: "Settings label for the capture shortcut.")
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(
              get: { settings.shouldHideScreenClipDuringCapture },
              set: { settings.hideScreenClipDuringCapture = $0 })) {
              Text(chrome: "Hide ScreenClip during capture", comment: "Hides ScreenClip windows while capturing.")
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
              chrome:
                "Leave this off to capture ScreenClip's windows and menu bar popover when reporting bugs in ScreenClip.",
              comment: "Explains the hide-during-capture setting."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $settings.browserContext) {
              Text(
                chrome: "Read the active browser URL for project matching",
                comment: "Enables optional browser URL routing."
              ).fixedSize(horizontal: false, vertical: true)
            }
            Text(
              chrome:
                "Safari and Chrome may ask for Automation permission. ScreenClip reads only the active tab when you capture.",
              comment: "Explains browser automation permission. Keep Safari and Chrome."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(
              "", text: $settings.sessionName,
              prompt: Text(chrome: "Testing session (optional)", comment: "Optional testing session name."))
            TextField(
              "", text: $settings.testedVersion,
              prompt: Text(
                chrome: "Tested build or version (optional)", comment: "Optional tested build label."))
          } header: {
            Text(chrome: "Capture", comment: "Settings section for capture preferences.")
          }
          Section {
            Toggle(isOn: $settings.notifications) {
              Text(
                chrome: "Notify me about questions and merged fixes",
                comment: "Enables notifications for questions and merges."
              ).fixedSize(horizontal: false, vertical: true)
            }
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
          } header: {
            Text(chrome: "Notifications", comment: "Settings section for notifications.")
          }
          Section {
            Toggle(
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
                })) {
              Text(chrome: "Open ScreenClip at login", comment: "Launches ScreenClip when you log in.")
                .fixedSize(horizontal: false, vertical: true)
            }
          } header: {
            Text(chrome: "Startup", comment: "Settings section for login behavior.")
          }
          #if !SCREENCLIP_APP_STORE
          Section {
            Button { model.supportAction?() } label: {
              Text(chrome: "Send a tip…", comment: "Opens the optional tip window.")
            }
            Text(
              chrome: "ScreenClip is free. A tip is optional and opens GitHub Sponsors.",
              comment: "Explains that tips are optional. Keep GitHub Sponsors."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "Support", comment: "Settings section for optional tips.")
          }
          #endif
          Section {
            FlowLayout {
              Button { export() } label: {
                Text(chrome: "Export queue…", comment: "Exports the local report queue.")
              }
              Button { NSWorkspace.shared.open(model.store.root) } label: {
                Text(chrome: "Show storage folder", comment: "Opens the Application Support folder.")
              }
            }
            Text(
              chrome:
                "Exports include approved screenshots and notes. Deleting evidence in ScreenClip does not delete the agent's own conversation history or PRs.",
              comment: "Explains export contents. Keep PRs."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "Local data", comment: "Settings section for the local queue.")
          }
        }.formStyle(.grouped)
  }
  private var projectSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(chrome: "Projects", comment: "Projects settings title.").font(.title2.weight(.semibold))
              Text(
                chrome: "Teach ScreenClip where each observation belongs.",
                comment: "Projects settings subtitle."
              ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
              editProject = Project(name: "", path: "")
            } label: {
              Label {
                Text(chrome: "Add project", comment: "Adds a project.")
              } icon: {
                Image(systemName: "plus")
              }
            }
          }
          if model.snapshot.projects.isEmpty {
            ContentUnavailableView {
              Label {
                Text(chrome: "Add your first repository", comment: "Empty projects list.")
              } icon: {
                Image(systemName: "folder.badge.plus")
              }
            } description: {
              Text(
                chrome: "Map a website or Mac app and set the checks a fix must pass.",
                comment: "Empty projects explanation.")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            List(model.snapshot.projects) { project in
              HStack {
                HStack(alignment: .top) {
                  Image(systemName: project.displaySymbol).foregroundStyle(.orange)
                    .frame(width: 20)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(project.name).fontWeight(.medium)
                    Text(project.path).font(.caption).foregroundStyle(.secondary)
                    Text((project.origins + project.bundleIDs).joined(separator: " · ")).font(
                      .caption
                    ).foregroundStyle(.tertiary)
                  }
                }
                Spacer()
                Button { editProject = project } label: {
                  Text(chrome: "Edit", comment: "Edits a project.")
                }.fixedSize()
              }.padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
            }
          }
        }.padding(24)
  }
  private var connectionSettings: some View {
        Form {
          Section {
            Picker(
              selection: Binding(
                get: { settings.preferredAgent }, set: { settings.defaultAgent = $0 })
            ) {
              ForEach(agentChoices) { kind in
                AgentLabel(
                  kind: kind
                ).tag(kind)
              }
            } label: {
              Text(chrome: "System default", comment: "Picker for the system-wide default provider.")
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AgentKind.allCases) { kind in
              AgentDetectionRow(kind: kind, detection: model.detection(kind))
            }
            HStack {
              Button { detectAgents() } label: {
                if model.detectingAgents {
                  Text(chrome: "Detecting…", comment: "Agent detection is running.")
                } else {
                  Text(chrome: "Detect agents", comment: "Looks for installed coding agents.")
                }
              }.disabled(model.detectingAgents)
              Spacer()
            }
            Stepper(
              value: Binding(
                get: { settings.parallelReportLimit }, set: { settings.maxParallelReports = $0 }),
              in: AppSettings.parallelReportRange
            ) {
              Text(verbatim: Chrome.format(
                "settings.parallel",
                "Run up to \(settings.parallelReportLimit) reports per project at once",
                locale: locale,
                comment: "Parallel report limit. %lld is the number of reports."))
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
              chrome:
                "The system default applies until a project sets its own. A capture starts from the project default, and you can pick another provider for that report. Connect each provider in its section.",
              comment: "Explains the system default, project default, and per-capture choice."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "AI agent", comment: "Settings section for the default agent.")
          }
          Section {
            TextField(
              text: Binding(get: { settings.claudePath ?? "" }, set: { settings.claudePath = $0 }),
              prompt: Text(verbatim: AgentDetector.defaultClaudePath().isEmpty
                ? Chrome.text("Not found", locale: locale, comment: "No Claude Code executable was found.")
                : AgentDetector.defaultClaudePath())
            ) {
              Text(chrome: "Claude Code executable", comment: "Path to the Claude Code CLI.")
                .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout {
              Button { chooseExecutable { settings.claudePath = $0 } } label: {
                Text(chrome: "Choose…", comment: "Picks the Claude Code executable.")
              }
              Button {
                model.saveSettings(settings)
                model.signInToClaude()
              } label: {
                Text(verbatim: ProviderPhrase.signIn.localized(.claude, locale: locale))
              }
              Button { detectAgents() } label: {
                Text(chrome: "Check", comment: "Checks the Claude Code installation.")
              }
            }
            TextField(
              text: Binding(get: { settings.claudeModel ?? "" }, set: { settings.claudeModel = $0 }),
              prompt: Text(chrome: "e.g. opus, sonnet", comment: "Example Claude Code model names. Keep opus and sonnet.")
            ) {
              Text(
                chrome: "Model (empty uses Claude Code's default)",
                comment: "Optional Claude Code model. Keep Claude Code."
              ).fixedSize(horizontal: false, vertical: true)
            }
            Text(
              chrome:
                "Runs claude -p in each issue's isolated worktree with edits auto-approved and Bash inside Claude Code's sandbox. git push and gh are blocked; ScreenClip validates, commits, and opens the PR itself. Sign-in opens Terminal for claude auth login.",
              comment: "Explains Claude Code. Keep command names and PR."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "Claude Code", comment: "Settings section. Do not translate Claude Code.")
          }
          Section {
            TextField(text: $settings.codexPath) {
              Text(chrome: "Codex executable", comment: "Path to the Codex CLI.")
                .fixedSize(horizontal: false, vertical: true)
            }
            CodexConnectionControls(
              model: model, authentication: model.worker.authentication,
              choose: { chooseExecutable { settings.codexPath = $0 } },
              check: connect,
              signIn: { method in
                model.saveSettings(settings)
                Task { await model.worker.signIn(method: method) }
              })
            TextField(text: $settings.model) {
              Text(
                chrome: "Model (empty uses Codex's default)",
                comment: "Optional Codex model. Keep Codex."
              ).fixedSize(horizontal: false, vertical: true)
            }
            Text(
              chrome:
                "Use an installed Codex CLI that supports app-server. A detected desktop-bundled runtime can be used for development; it is not redistributed with ScreenClip.",
              comment: "Explains the Codex CLI requirement. Keep Codex and app-server."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "Codex", comment: "Settings section. Do not translate Codex.")
          }
          Section {
            TextField(text: $webhookURL, prompt: Text(verbatim: "https://")) {
              Text(chrome: "Webhook URL", comment: "Grok Bot address field.")
                .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
              if grokKeyIsSet {
                Text(chrome: "Set", comment: "The Grok Bot key is saved. The value is never shown.")
                  .foregroundStyle(.secondary)
              } else {
                Text(chrome: "Not set", comment: "The Grok Bot key is not saved.")
                  .foregroundStyle(.secondary)
              }
            } label: {
              Text(chrome: "Key", comment: "Grok Bot key field.")
                .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
              Text(verbatim: grokCapabilityText).foregroundStyle(.secondary)
            } label: {
              Text(
                chrome: "Capabilities",
                comment: "Saved Grok Bot capabilities. Not a secret."
              ).fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout {
              if grokConnected {
                Button { testGrokConnection() } label: {
                  if testingGrok {
                    Text(chrome: "Checking…", comment: "A Grok Bot check is in progress.")
                  } else {
                    Text(chrome: "Test connection", comment: "Rechecks the saved Grok Bot webhook and key.")
                  }
                }.disabled(testingGrok)
              } else {
                Button { openGrokConnect(code: nil) } label: {
                  Text(verbatim: ProviderPhrase.connect.localized(.external, locale: locale))
                }
              }
              Button { disconnectGrok() } label: {
                Text(verbatim: ProviderPhrase.disconnect.localized(.external, locale: locale))
              }.disabled(!grokConnected && webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !grokKeyIsSet)
              if testingGrok { ProgressView().controlSize(.small) }
            }
            if let grokTestResult {
              Text(verbatim: Chrome.stored(grokTestResult, locale: locale)).font(.caption)
                .foregroundStyle(grokTestOK ? Color.green : Color.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
              chrome:
                "Reports go to the ScreenClip reports routine through a webhook. Grok Bot opens the pull request. Screenshots are sent only when the project allows it.",
              comment: "Explains Grok Bot. Keep ScreenClip, Grok Bot, and the routine name ScreenClip reports."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "Grok Bot", comment: "Settings section. Do not translate Grok Bot.")
          }
          Section {
            TextField(text: $settings.ghPath) {
              Text(chrome: "GitHub CLI executable", comment: "Path to the GitHub CLI. Keep GitHub.")
                .fixedSize(horizontal: false, vertical: true)
            }
            Button {
              Task {
                do {
                  _ = try await CommandRunner.checked(settings.ghPath, ["auth", "status"])
                  error = "GitHub sign-in is ready."
                } catch { self.error = "GitHub needs setup: " + error.localizedDescription }
              }
            } label: {
              Text(chrome: "Check GitHub sign-in", comment: "Checks gh auth status. Keep GitHub.")
            }
            Text(
              chrome:
                "Authenticate GitHub CLI with gh auth login. Fixes are published from isolated branches; project checks and required reviews govern automatic merge.",
              comment: "Explains GitHub CLI setup. Keep gh auth login."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          } header: {
            Text(chrome: "GitHub", comment: "Settings section. Do not translate GitHub.")
          }
        }.formStyle(.grouped)
  }
  private var grokSaved: ExternalAssistantConfiguration { model.loadExternalAssistant() }
  private var grokConnected: Bool { grokSaved.isConfigured }
  private var grokKeyIsSet: Bool {
    !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private var grokCapabilityText: String {
    let names = grokSaved.capabilities
    if names.isEmpty {
      return Chrome.text("None", locale: locale, comment: "No Grok Bot capabilities are saved.")
    }
    return names.joined(separator: ", ")
  }
  private func testGrokConnection() {
    let secret = model.loadExternalAssistant().authorization
    testingGrok = true
    grokTestResult = nil
    Task {
      let result = await model.checkGrokConnection(webhookURL: webhookURL, authorization: secret)
      grokTestOK = result.connected
      if result.connected, let host = result.host, !host.isEmpty {
        grokTestResult = ProviderPhrase.readyDetail(kind: .external, extra: host)
      } else if result.connected {
        grokTestResult = ProviderPhrase.ready.english(.external)
      } else {
        grokTestResult = result.message
      }
      testingGrok = false
      reloadGrokConnection()
    }
  }
  private func disconnectGrok() {
    do {
      try model.disconnectExternalAssistant()
      webhookURL = ""
      authorization = ""
      grokTestResult = nil
      Task { await model.refreshAgents() }
    } catch {
      grokTestOK = false
      grokTestResult = error.localizedDescription
    }
  }
  private func reloadGrokConnection() {
    let connection = model.loadExternalAssistant()
    webhookURL = connection.webhookURL
    authorization = connection.authorization
  }
  private func openGrokConnect(code: String?) {
    grokConnectCode = code
    grokConnectPresentation += 1
    tab = 2
    showingGrokConnect = true
  }
  private func presentGrokConnectIfNeeded() {
    guard let request = model.grokConnectRequest else { return }
    if showingGrokConnect && grokConnectCode == request.code { return }
    openGrokConnect(code: request.code)
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
    panel.prompt = Chrome.text("Export here", locale: locale, comment: "Open-panel button for choosing an export folder.")
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

