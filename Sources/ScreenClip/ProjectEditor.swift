import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct ProjectEditor: View {
  @ObservedObject var model: AppModel
  @State var project: Project
  /// Set when the editor is embedded in the main window instead of shown as a sheet.
  var onSaved: ((UUID) -> Void)? = nil
  var onRemoved: (() -> Void)? = nil
  var embedded: Bool { onSaved != nil }
  @State private var savedAt: Date?
  @State private var origins = ""
  @State private var bundles = ""
  @State private var error: String?
  @Environment(\.dismiss) var dismiss
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Group {
        if isExisting {
          Text(chrome: "Project settings", comment: "Project editor title.")
        } else {
          Text(chrome: "New project", comment: "Title when creating a project.")
        }
      }.font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
      Form {
        TextField(text: $project.name) {
          Text(chrome: "Name", comment: "Project name field.")
        }
        ProjectSymbolPicker(symbol: $project.symbol)
        HStack {
          TextField(text: $project.path) {
            Text(chrome: "Repository root", comment: "Git repository path field.")
          }
          Button {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
              project.path = url.path
              if project.name.isEmpty { project.name = url.lastPathComponent }
            }
          } label: {
            Text(chrome: "Choose…", comment: "Picks a repository folder.")
          }
        }
        TextField(text: $project.baseBranch) {
          Text(chrome: "Base branch", comment: "Git base branch field. The branch name itself is not translated.")
        }
        TextField(
          text: $origins,
          prompt: Text(chrome: "One per line", comment: "Placeholder for a multiline list."),
          axis: .vertical
        ) {
          Text(chrome: "Websites", comment: "Website origins used for project routing.")
        }.lineLimit(2...4)
        Text(
          chrome:
            "Include the scheme and port, for example http://localhost:3000 or https://example.com/app.",
          comment: "Example website origins. Keep the example URLs."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        TextField(
          text: $bundles,
          prompt: Text(chrome: "One per line", comment: "Placeholder for a multiline list."),
          axis: .vertical
        ) {
          Text(chrome: "Mac app bundle IDs", comment: "Native app bundle identifiers.")
        }.lineLimit(1...3)
        LabeledContent {
          TextField("", text: $project.validationCommand, axis: .vertical)
            .labelsHidden().lineLimit(2...4).font(.system(.body, design: .monospaced))
        } label: {
          Text(chrome: "Validation command", comment: "Command that must pass before publishing.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          chrome:
            "This command runs in the issue's worktree before publishing. Automatic merge also requires passing GitHub checks and required reviews.",
          comment: "Explains validation. Keep GitHub."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Picker(
          selection: Binding(
            get: { project.defaultAgent },
            set: { project.defaultAgent = $0 })
        ) {
          Text(
            verbatim: Chrome.format(
              "agent.systemDefault",
              "System default (\(model.snapshot.settings.preferredAgent.title))",
              locale: locale,
              comment: "Project default that follows the system default. %@ is the current provider name.")
          ).tag(nil as AgentKind?)
          ForEach(providerChoices) { kind in
            AgentLabel(kind: kind).tag(Optional(kind))
          }
        } label: {
          Text(chrome: "Project default", comment: "Picker for this project's default provider.")
            .fixedSize(horizontal: false, vertical: true)
        }
        if showsGrokOptInNote {
          Text(verbatim: Chrome.stored(AgentSelection.grokOptInNote, locale: locale))
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        Picker(selection: $project.codexApprovalMode) {
          Text(chrome: "Automatic review (recommended)", comment: "Codex reviews permission requests automatically.")
            .tag(CodexApprovalMode.automaticReview)
          Text(chrome: "Ask me", comment: "Codex permission mode with manual approval.")
            .tag(CodexApprovalMode.ask)
          Text(chrome: "Full access (no approval prompts)", comment: "Codex permission mode without sandbox or approval prompts.")
            .tag(CodexApprovalMode.fullAccess)
        } label: {
          Text(chrome: "Codex permissions", comment: "Project permission mode for Codex.")
        }
        Group {
          switch project.codexApprovalMode {
          case .automaticReview:
            Text(chrome: "Codex reviews permission requests automatically while keeping the workspace sandbox. Questions about the fix still come to you. Applies to the next turn.", comment: "Explains automatic Codex approval review.")
          case .ask:
            Text(chrome: "Codex asks you when a command needs extra access. Applies to the next turn.", comment: "Explains manual Codex approvals.")
          case .fullAccess:
            Text(chrome: "Commands can access your Mac and the network without approval prompts. Use only for projects you trust. Applies to the next turn.", comment: "Explains full access for Codex.")
          }
        }.font(.caption).foregroundStyle(project.codexApprovalMode == .fullAccess ? .orange : .secondary)
          .fixedSize(horizontal: false, vertical: true)
        Toggle(isOn: $project.autoMerge) {
          Text(
            chrome: "Merge fixes automatically after checks pass",
            comment: "Enables automatic merge."
          ).fixedSize(horizontal: false, vertical: true)
        }
        Toggle(
          isOn: Binding(
            get: { project.sendsExternalScreenshots },
            set: { project.allowExternalScreenshots = $0 })) {
          Text(
            chrome: "Allow sending screenshots to the external assistant",
            comment: "Project opt-in for sending screenshots to Grok Bot."
          ).fixedSize(horizontal: false, vertical: true)
        }
        Text(
          chrome:
            "Grok Bot receives approved screenshots as files on a screenclip/ branch in this repository. Leave this off unless that is acceptable. Public repositories need this too, because those files would be readable by anyone who can see the repository, and pushed files stay in GitHub history even after the branch is deleted. The toggle is off until you turn it on.",
          comment: "Explains the screenshot opt-in. Keep Grok Bot, screenclip/, and GitHub."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.textFieldStyle(.roundedBorder)
      if let error {
        Text(verbatim: Chrome.stored(error, locale: locale)).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if isExisting {
          Button(role: .destructive) {
            model.perform { try model.commit { $0.projects.removeAll { $0.id == project.id } } }
            close(removed: true)
          } label: {
            Text(chrome: "Remove project", comment: "Removes a project that has no reports.")
          }.disabled(model.snapshot.issues.contains { $0.projectID == project.id })
            .help(
              Text(
                verbatim: model.snapshot.issues.contains { $0.projectID == project.id }
                  ? Chrome.text(
                    "Projects with reports can't be removed.", locale: locale,
                    comment: "Why the remove button is disabled.")
                  : "")
            )
        }
        Spacer()
        if embedded {
          if savedAt != nil, error == nil {
            Label {
              Text(chrome: "Saved", comment: "Confirms an embedded project editor saved.")
            } icon: {
              Image(systemName: "checkmark")
            }.font(.caption).foregroundStyle(.secondary)
          }
          if isExisting {
            Button { load(model.project(project.id) ?? project) } label: {
              Text(chrome: "Revert", comment: "Restores the saved project fields.")
            }
          }
        } else {
          Button(role: .cancel) { dismiss() } label: {
            Text(chrome: "Cancel", comment: "Closes project settings without saving.")
          }
        }
        Button { save() } label: {
          if isExisting || !embedded {
            Text(chrome: "Save project", comment: "Saves the project.")
          } else {
            Text(chrome: "Add project", comment: "Adds a project.")
          }
        }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut("s", modifiers: .command)
      }
    }.padding(24).frame(minWidth: embedded ? 0 : 620, idealWidth: embedded ? nil : 720)
      .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
      .onAppear { load(project) }
  }
  private var providerChoices: [AgentKind] {
    let connected = AgentKind.allCases.filter { model.detection($0)?.usable == true }
    guard let chosen = project.defaultAgent, !connected.contains(chosen) else { return connected }
    return connected + [chosen]
  }
  private var showsGrokOptInNote: Bool {
    AgentSelection.projectDefault(project, system: model.snapshot.settings.preferredAgent) == .external
      && !project.sendsExternalScreenshots
  }
  private var isExisting: Bool { model.snapshot.projects.contains(where: { $0.id == project.id }) }
  private func load(_ value: Project) {
    project = value
    origins = value.origins.joined(separator: "\n")
    bundles = value.bundleIDs.joined(separator: "\n")
    error = nil
  }
  private func close(removed: Bool) {
    if embedded {
      if removed { onRemoved?() }
    } else {
      dismiss()
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
      error = nil
      savedAt = Date()
      if let onSaved { onSaved(project.id) } else { dismiss() }
    } catch { self.error = error.localizedDescription }
  }
}
