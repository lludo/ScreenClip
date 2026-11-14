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
                if enabled {
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
          Section("Local data") {
            HStack {
              Button("Export queue…") { export() }
              Button("Show storage folder") { NSWorkspace.shared.open(model.store.root) }
            }
            Text(
              "Exports include approved screenshots and notes. Deleting evidence in ScreenClip does not delete independent Codex history or PRs."
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
          model.saveSettings(settings)
          close()
        }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut("s", modifiers: .command)
      }.padding(16)
    }.frame(width: 700, height: 590)
      .onAppear {
        settings = model.snapshot.settings
        if model.snapshot.projects.isEmpty { tab = 1 }
      }
      .sheet(item: $editProject) { project in ProjectEditor(model: model, project: project) }
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
struct ScreenCapturePermissionControls: View {
  @ObservedObject var model: AppModel
  @ObservedObject var permission: ScreenCapturePermission
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        permission.message,
        systemImage: permission.state == .available ? "checkmark.circle" : "viewfinder"
      ).font(.caption).foregroundStyle(permission.state == .available ? .green : .secondary)
      HStack {
        Button("Check screen access") { Task { await model.recheckCapturePermission() } }.disabled(
          permission.state == .checking)
        if permission.state != .available {
          Button("Open System Settings") { model.openCaptureSettings() }
          Button("Reopen app") { model.relaunchAction?() }
        }
      }
    }
  }
}
struct CodexConnectionControls: View {
  @ObservedObject var model: AppModel
  @ObservedObject var authentication: CodexAuthentication
  let choose: () -> Void
  let check: () -> Void
  let signIn: (CodexAuthentication.Method) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button("Choose…", action: choose)
        Button("Check connection", action: check).disabled(authentication.state == .checking)
        Button("Sign in…") { signIn(.browser) }.disabled(
          authentication.state == .checking || authentication.state == .ready
            || authentication.loginID != nil)
        if authentication.state != .ready {
          Menu("Other sign-in options") {
            Button("Sign in with a code…") { signIn(.deviceCode) }
            Button("Try browser sign-in again…") { signIn(.browser) }
          }.disabled(authentication.state == .checking)
        }
        if authentication.state == .checking { ProgressView().controlSize(.small) }
      }
      Text(model.connection).font(.caption).foregroundStyle(statusColor).textSelection(.enabled)
      if let description = authentication.accountDescription {
        Text(description).font(.caption).foregroundStyle(.secondary)
      }
      if authentication.loginID != nil {
        if let code = authentication.userCode {
          HStack {
            Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
            Button("Copy code") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code, forType: .string)
            }
          }
          Text(
            "Enter this code on the sign-in page. Device-code login may need to be enabled in your ChatGPT security settings."
          ).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Open sign-in page") { authentication.reopenLoginPage() }
          Button("Cancel sign-in") { Task { await authentication.cancel() } }
        }
        Text(
          "If the browser shows an error, cancel and check the connection or choose another sign-in option."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var statusColor: Color {
    if authentication.state == .ready { return .green }
    if case .failed = authentication.state { return .orange }
    return .secondary
  }
}
struct ProjectEditor: View {
  @ObservedObject var model: AppModel
  @State var project: Project
  @State private var origins = ""
  @State private var bundles = ""
  @State private var error: String?
  @Environment(\.dismiss) var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Project settings").font(.title2.weight(.semibold))
      Form {
        TextField("Name", text: $project.name)
        HStack {
          TextField("Repository root", text: $project.path)
          Button("Choose…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
              project.path = url.path
              if project.name.isEmpty { project.name = url.lastPathComponent }
            }
          }
        }
        TextField("Base branch", text: $project.baseBranch)
        TextField("Websites (one per line)", text: $origins, axis: .vertical).lineLimit(2...4)
        Text(
          "Include the scheme and port, for example http://localhost:3000 or https://example.com/app."
        ).font(.caption).foregroundStyle(.secondary)
        TextField("Mac app bundle IDs (one per line)", text: $bundles, axis: .vertical).lineLimit(
          1...3)
        TextField("Validation command", text: $project.validationCommand, axis: .vertical)
          .lineLimit(2...4).font(.system(.body, design: .monospaced))
        Text(
          "This command runs in the issue's worktree before publishing. Automatic merge also requires passing GitHub checks and required reviews."
        ).font(.caption).foregroundStyle(.secondary)
        Toggle("Merge fixes automatically after checks pass", isOn: $project.autoMerge)
      }.textFieldStyle(.roundedBorder)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        if model.snapshot.projects.contains(where: { $0.id == project.id }) {
          Button("Remove project", role: .destructive) {
            model.perform { try model.commit { $0.projects.removeAll { $0.id == project.id } } }
            dismiss()
          }.disabled(model.snapshot.issues.contains { $0.projectID == project.id })
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save project") { save() }.buttonStyle(.borderedProminent).tint(.orange)
      }
    }.padding(24).frame(width: 620).onAppear {
      origins = project.origins.joined(separator: "\n")
      bundles = project.bundleIDs.joined(separator: "\n")
    }
  }
  private func save() {
    do {
      project.origins = origins.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }
      project.bundleIDs = bundles.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }
      if let old = model.project(project.id), old.path != project.path,
        model.snapshot.issues.contains(where: { $0.projectID == project.id })
      {
        throw ScreenClipError.message(
          "This project has recorded issues. Add a new project to use a different repository.")
      }
      try model.saveProject(project)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
struct ShortcutRecorder: NSViewRepresentable {
  @Binding var settings: AppSettings
  func makeNSView(context: Context) -> RecorderField {
    let field = RecorderField()
    field.isEditable = false
    field.isSelectable = false
    field.isBezeled = true
    field.alignment = .center
    field.focusRingType = .exterior
    return field
  }
  func updateNSView(_ field: RecorderField, context: Context) {
    field.stringValue = settings.shortcutDescription
    field.record = { key, modifiers, label in
      settings.shortcutKey = key
      settings.shortcutModifiers = modifiers
      settings.shortcutDescription = label
    }
  }
}
final class RecorderField: NSTextField {
  var record: ((UInt32, UInt32, String) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    stringValue = "Press shortcut…"
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      window?.makeFirstResponder(nil)
      return
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
      stringValue = "Include ⌘, ⌃ or ⌥"
      return
    }
    var value: UInt32 = 0
    var label = ""
    if flags.contains(.control) {
      value |= 4096
      label += "⌃"
    }
    if flags.contains(.option) {
      value |= 2048
      label += "⌥"
    }
    if flags.contains(.shift) {
      value |= 512
      label += "⇧"
    }
    if flags.contains(.command) {
      value |= 256
      label += "⌘"
    }
    label += event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    record?(UInt32(event.keyCode), value, label)
    stringValue = label
    window?.makeFirstResponder(nil)
  }
}
