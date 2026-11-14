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
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(chrome: "Project settings", comment: "Project editor title.").font(.title2.weight(.semibold))
      Form {
        TextField(text: $project.name) {
          Text(chrome: "Name", comment: "Project name field.")
        }
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
          text: $origins, axis: .vertical
        ) {
          Text(chrome: "Websites (one per line)", comment: "Website origins used for project routing.")
        }.lineLimit(2...4)
        Text(
          chrome:
            "Include the scheme and port, for example http://localhost:3000 or https://example.com/app.",
          comment: "Example website origins. Keep the example URLs."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        TextField(text: $bundles, axis: .vertical) {
          Text(chrome: "Mac app bundle IDs (one per line)", comment: "Native app bundle identifiers.")
        }.lineLimit(1...3)
        TextField(text: $project.validationCommand, axis: .vertical) {
          Text(chrome: "Validation command", comment: "Command that must pass before publishing.")
        }.lineLimit(2...4).font(.system(.body, design: .monospaced))
        Text(
          chrome:
            "This command runs in the issue's worktree before publishing. Automatic merge also requires passing GitHub checks and required reviews.",
          comment: "Explains validation. Keep GitHub."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        if model.snapshot.projects.contains(where: { $0.id == project.id }) {
          Button(role: .destructive) {
            model.perform { try model.commit { $0.projects.removeAll { $0.id == project.id } } }
            dismiss()
          } label: {
            Text(chrome: "Remove project", comment: "Removes a project that has no reports.")
          }.disabled(model.snapshot.issues.contains { $0.projectID == project.id })
        }
        Spacer()
        Button(role: .cancel) { dismiss() } label: {
          Text(chrome: "Cancel", comment: "Closes project settings without saving.")
        }
        Button { save() } label: {
          Text(chrome: "Save project", comment: "Saves the project.")
        }.buttonStyle(.borderedProminent).tint(.orange)
      }
    }.padding(24).frame(minWidth: 620, idealWidth: 720).onAppear {
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
