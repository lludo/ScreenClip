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
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isExisting ? "Project settings" : "New project").font(.title2.weight(.semibold))
      Form {
        TextField("Name", text: $project.name)
        ProjectSymbolPicker(symbol: $project.symbol)
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
        LabeledContent("Validation command") {
          TextField("Validation command", text: $project.validationCommand, axis: .vertical)
            .labelsHidden().lineLimit(2...4).font(.system(.body, design: .monospaced))
        }
        Text(
          "This command runs in the issue's worktree before publishing. Automatic merge also requires passing GitHub checks and required reviews."
        ).font(.caption).foregroundStyle(.secondary)
        Toggle("Merge fixes automatically after checks pass", isOn: $project.autoMerge)
        Toggle(
          "Allow sending screenshots to the external assistant",
          isOn: Binding(
            get: { project.sendsExternalScreenshots },
            set: { project.allowExternalScreenshots = $0 }))
        Text(
          "Grok Bot receives approved screenshots as files on a screenclip/ branch in this repository. Leave this off unless that is acceptable. Public repositories need this too, because those files would be readable by anyone who can see the repository, and pushed files stay in GitHub history even after the branch is deleted. The toggle is off until you turn it on."
        ).font(.caption).foregroundStyle(.secondary)
      }.textFieldStyle(.roundedBorder)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        if isExisting {
          Button("Remove project", role: .destructive) {
            model.perform { try model.commit { $0.projects.removeAll { $0.id == project.id } } }
            close(removed: true)
          }.disabled(model.snapshot.issues.contains { $0.projectID == project.id })
            .help(
              model.snapshot.issues.contains { $0.projectID == project.id }
                ? "Projects with reports can't be removed." : "")
        }
        Spacer()
        if embedded {
          if savedAt != nil, error == nil {
            Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
          }
          if isExisting {
            Button("Revert") { load(model.project(project.id) ?? project) }
          }
        } else {
          Button("Cancel", role: .cancel) { dismiss() }
        }
        Button(isExisting || !embedded ? "Save project" : "Add project") { save() }
          .buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut("s", modifiers: .command)
      }
    }.padding(24).frame(width: embedded ? nil : 620).onAppear { load(project) }
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
