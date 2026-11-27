import ScreenClipCore
import SwiftUI

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
  /// App bundle IDs declared in the repository's source (Xcode projects, xcconfigs, manifests).
  @State private var detectedBundles: [String] = []
  /// The repository's default branch, and whether the typed base branch exists in it.
  @State private var defaultBranch: String?
  @State private var baseBranchMissing = false
  @State private var error: String?
  @Environment(\.dismiss) var dismiss
  @Environment(\.locale) private var locale
  private var hasReports: Bool { model.snapshot.issues.contains { $0.projectID == project.id } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Group {
        if isExisting {
          Text(chrome: "Project settings", comment: "Project editor title.")
        } else {
          Text(chrome: "New project", comment: "Title when creating a project.")
        }
      }.font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        row {
          Text(chrome: "Name", comment: "Project name field.")
        } content: {
          TextField(text: $project.name) {
            Text(chrome: "Name", comment: "Project name field.")
          }.labelsHidden()
        }
        row {
          Text(chrome: "Icon", comment: "Project icon field.")
        } content: {
          ProjectSymbolPicker(symbol: $project.symbol).labelsHidden()
        }
        row {
          Text(chrome: "Repository root", comment: "Git repository path field.")
        } content: {
          HStack {
            TextField(text: $project.path) {
              Text(chrome: "Repository root", comment: "Git repository path field.")
            }.labelsHidden().truncationMode(.head)
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
            }.fixedSize()
          }
        }
        row {
          Text(chrome: "Base branch", comment: "Git base branch field. The branch name itself is not translated.")
        } content: {
          TextField(text: $project.baseBranch) {
            Text(chrome: "Base branch", comment: "Git base branch field. The branch name itself is not translated.")
          }.labelsHidden()
        }
        if baseBranchMissing {
          note {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
              Text(verbatim: missingBranchText)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
              if let defaultBranch {
                Button {
                  project.baseBranch = defaultBranch
                } label: {
                  Text(verbatim: Chrome.format(
                    "project.useBranch", "Use \(defaultBranch)", locale: locale,
                    comment: "Sets the base branch to the repository's default. %@ is a branch name and stays unchanged."))
                }.controlSize(.small).fixedSize()
              }
            }
          }
        }
        row {
          Text(chrome: "Websites", comment: "Website origins used for project routing.")
        } content: {
          TextField(
            text: $origins,
            prompt: Text(chrome: "One per line", comment: "Placeholder for a multiline list."),
            axis: .vertical
          ) {
            Text(chrome: "Websites", comment: "Website origins used for project routing.")
          }.labelsHidden().lineLimit(2...4)
        }
        note {
          caption(Text(
            chrome:
              "Include the scheme and port, for example http://localhost:3000 or https://example.com/app.",
            comment: "Example website origins. Keep the example URLs."
          ))
        }
        row {
          Text(chrome: "App bundle IDs (Mac and iOS)", comment: "Native app bundle identifiers used for routing.")
        } content: {
          TextField(
            text: $bundles,
            prompt: Text(chrome: "One per line", comment: "Placeholder for a multiline list."),
            axis: .vertical
          ) {
            Text(chrome: "App bundle IDs (Mac and iOS)", comment: "Native app bundle identifiers used for routing.")
          }.labelsHidden().lineLimit(1...4)
        }
        if !suggestedBundles.isEmpty {
          note {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              caption(Text(verbatim: Chrome.format(
                "project.detectedBundles", "Found in this repository: \(suggestedBundles.joined(separator: ", "))",
                locale: locale, comment: "App bundle IDs found in the project's source. %@ is a list of identifiers.")))
                .textSelection(.enabled)
              Button {
                let current = bundles.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                  .filter { !$0.isEmpty }
                bundles = (current + suggestedBundles).joined(separator: "\n")
              } label: {
                Text(chrome: "Add", comment: "Adds the detected bundle IDs to the project.")
              }.controlSize(.small).fixedSize()
            }
          }
        }
        row {
          Text(chrome: "Validation command", comment: "Command that must pass before publishing.")
        } content: {
          TextField("", text: $project.validationCommand, axis: .vertical)
            .labelsHidden().lineLimit(2...4).font(.system(.body, design: .monospaced))
        }
        note {
          caption(Text(
            chrome:
              "This command runs in the issue's worktree before publishing. Automatic merge also requires passing GitHub checks and required reviews.",
            comment: "Explains validation. Keep GitHub."
          ))
        }
        row {
          Text(chrome: "Project default", comment: "Picker for this project's default provider.")
        } content: {
          Picker(selection: $project.defaultAgent) {
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
          }.labelsHidden().fixedSize()
        }
        note {
          Toggle(isOn: $project.reuseLastAgentChoice) {
            Text(chrome: "Use the last agent, model, and effort for new reports",
              comment: "Project setting to start new reports with the last submitted agent choice.")
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        row {
          Text(chrome: "Codex permissions", comment: "Project permission mode for Codex.")
        } content: {
          Picker(selection: $project.codexApprovalMode) {
            Text(chrome: "Automatic review (recommended)", comment: "Codex reviews permission requests automatically.")
              .tag(CodexApprovalMode.automaticReview)
            Text(chrome: "Ask me", comment: "Codex permission mode with manual approval.")
              .tag(CodexApprovalMode.ask)
            Text(chrome: "Full access (no approval prompts)", comment: "Codex permission mode without sandbox or approval prompts.")
              .tag(CodexApprovalMode.fullAccess)
          } label: {
            Text(chrome: "Codex permissions", comment: "Project permission mode for Codex.")
          }.labelsHidden().fixedSize()
        }
        note {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        note {
          Toggle(isOn: $project.autoMerge) {
            Text(
              chrome: "Merge fixes automatically after checks pass",
              comment: "Enables automatic merge."
            ).fixedSize(horizontal: false, vertical: true)
          }
        }
        note {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $project.commitsScreenshots) {
              Text(
                chrome: "Commit screenshots to the repository",
                comment: "Project setting: commit Before / After screenshots with each fix."
              ).fixedSize(horizontal: false, vertical: true)
            }
            Group {
              if project.commitsScreenshots {
                Text(chrome: "Before / After screenshots are committed under .screenclip/ with each fix so the pull request description can show them. They stay in the repository until you remove them.", comment: "Explains committing screenshots to the repository.")
              } else {
                Text(chrome: "Pull requests describe Before / After in words, without images. Nothing is committed under .screenclip/.", comment: "Explains not committing screenshots.")
              }
            }.font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
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
          }.disabled(hasReports)
            .help(
              Text(
                verbatim: hasReports
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
    }.padding(24)
      // A sheet gets one fixed width so the label column and wrapped notes never spill past its edges.
      .frame(width: embedded ? nil : 640)
      .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
      .onAppear { load(project) }
      // An accepted settings proposal changes the saved project while this form is open.
      // Without this, the next Save would write the old values back.
      .onChange(of: model.project(project.id)?.validationCommand) { old, new in
        if let new, project.validationCommand == (old ?? "") { project.validationCommand = new }
      }
      .onChange(of: model.project(project.id)?.baseBranch) { old, new in
        if let new, project.baseBranch == (old ?? Project.defaultBaseBranch) { project.baseBranch = new }
      }
      // Filing a capture from a new app teaches the project that app's bundle ID, and "Allow and
      // automate this project" changes the Codex approval mode. Keep both through the next Save.
      .onChange(of: model.project(project.id)?.bundleIDs) { old, new in
        guard let new else { return }
        let listed = Set(bundles.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let learned = new.filter { !(old ?? []).contains($0) && !listed.contains($0) }
        if !learned.isEmpty {
          bundles = (bundles.split(separator: "\n").map(String.init) + learned).joined(separator: "\n")
        }
      }
      .onChange(of: model.project(project.id)?.codexApprovalMode) { old, new in
        if let new, project.codexApprovalMode == old { project.codexApprovalMode = new }
      }
      .task(id: project.path) { await detectBundles() }
      .task(id: project.path + "\u{0}" + project.baseBranch) { await checkBaseBranch() }
  }
  /// Width of the trailing-aligned label column. Longer translations wrap instead of widening it.
  private let labelWidth: CGFloat = 190

  /// A labeled row: the label sits in a fixed trailing column, the control fills the rest.
  private func row<Label: View, Content: View>(
    @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      label()
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: labelWidth, alignment: .trailing)
      content().frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// A row with no label: help text, warnings and toggles aligned with the controls above.
  private func note<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    GridRow {
      Color.clear.frame(width: labelWidth, height: 0)
      content().frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func caption(_ text: Text) -> some View {
    text.font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var providerChoices: [AgentKind] {
    let connected = AgentKind.allCases.filter { model.detection($0)?.usable == true }
    guard let chosen = project.defaultAgent, !connected.contains(chosen) else { return connected }
    return connected + [chosen]
  }
  /// Detected identifiers not already listed. Only fully resolved ones are offered.
  private var suggestedBundles: [String] {
    let listed = Set(bundles.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    return detectedBundles.filter { !listed.contains($0) }
  }
  private var missingBranchText: String {
    if let defaultBranch {
      return Chrome.format(
        "project.missingBranchDefault",
        "This repository has no branch “\(project.baseBranch)”. Its default branch is “\(defaultBranch)”.",
        locale: locale,
        comment: "Base branch warning. The first %@ is the typed branch, the second the repository's default. Branch names stay unchanged.")
    }
    return Chrome.format(
      "project.missingBranch", "This repository has no branch “\(project.baseBranch)”.", locale: locale,
      comment: "Base branch warning. %@ is the typed branch name and stays unchanged.")
  }

  /// Picks up the repository's default branch for a new folder, and flags a base branch the
  /// repository does not have, so a report never fails on git's "invalid reference".
  private func checkBaseBranch() async {
    let path = project.path
    let base = project.baseBranch.trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path + "/.git") else {
      defaultBranch = nil
      baseBranchMissing = false
      return
    }
    try? await Task.sleep(nanoseconds: 250_000_000)  // settle while typing
    guard !Task.isCancelled else { return }
    let detected = await GitWorkspace.defaultBranch(at: path)
    let exists = base.isEmpty ? false : await GitWorkspace.branchExists(base, at: path)
    guard path == project.path, base == project.baseBranch.trimmingCharacters(in: .whitespaces) else { return }
    defaultBranch = detected
    if !exists, !isExisting, base.isEmpty || base == Project.defaultBaseBranch, let detected {
      // A new project takes the repository's default instead of assuming "main".
      project.baseBranch = detected
      baseBranchMissing = false
    } else {
      baseBranchMissing = !exists
    }
  }

  private func detectBundles() async {
    let path = project.path
    guard !path.isEmpty else { return detectedBundles = [] }
    let found = await Task.detached(priority: .utility) {
      BundleIDScanner.scan(root: URL(fileURLWithPath: path)).filter(\.isResolved).map(\.identifier)
    }.value
    guard path == project.path else { return }
    detectedBundles = found.filter { !$0.hasSuffix("Tests") && !$0.hasSuffix("UITests") }.sorted()
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
