import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

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
