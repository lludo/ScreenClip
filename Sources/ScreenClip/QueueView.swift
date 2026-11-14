import ScreenClipCore
import SwiftUI

enum QueueFilter: String, CaseIterable, Identifiable {
  case active = "All open"
  case attention = "Needs you"
  case retest = "To retest"
  case drafts = "Drafts"
  case history = "History"
  case archived = "Archived"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .active: return "tray"
    case .attention: return "bubble.left.and.exclamationmark.bubble.right"
    case .retest: return "checkmark.circle"
    case .drafts: return "square.and.pencil"
    case .history: return "clock"
    case .archived: return "archivebox"
    }
  }
  func includes(_ issue: Issue) -> Bool {
    if self == .archived { return issue.archived }
    if issue.archived { return false }
    switch self {
    case .active: return issue.status.isActive
    case .attention: return issue.status.needsAttention
    case .retest: return issue.status == .merged
    case .drafts: return issue.status == .draft
    case .history: return [.merged, .verified, .canceled].contains(issue.status)
    case .archived: return true
    }
  }
}
struct QueueView: View {
  @ObservedObject var model: AppModel
  @State private var filter: QueueFilter = .active
  @State private var projectFilter: UUID?
  @State private var search = ""
  var filtered: [Issue] {
    model.snapshot.issues.filter {
      filter.includes($0) && (projectFilter == nil || projectFilter == $0.projectID)
        && $0.matchesFeedback(search)
    }
  }
  var body: some View {
    HSplitView {
      List {
        Section {
          ForEach(QueueFilter.allCases) { item in
            Button {
              filter = item
            } label: {
              HStack {
                Label(item.rawValue, systemImage: item.symbol)
                Spacer()
                Text("\(model.snapshot.issues.filter { item.includes($0) }.count)").foregroundStyle(
                  .secondary
                ).monospacedDigit()
              }
              .padding(.vertical, 4).foregroundStyle(filter == item ? Color.orange : Color.primary)
            }.buttonStyle(.plain)
          }
        } header: {
          Text("WORKSPACE")
        }
        Section("PROJECTS") {
          Button {
            projectFilter = nil
          } label: {
            Label("All projects", systemImage: "square.grid.2x2").foregroundStyle(
              projectFilter == nil ? .orange : .primary)
          }.buttonStyle(.plain)
          ForEach(model.snapshot.projects) { project in
            Button {
              projectFilter = project.id
            } label: {
              Label(project.name, systemImage: "folder").foregroundStyle(
                projectFilter == project.id ? .orange : .primary)
            }.buttonStyle(.plain)
          }
          Button {
            model.settingsAction?()
          } label: {
            Label("Manage projects…", systemImage: "plus")
          }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }.listStyle(.sidebar).frame(minWidth: 190, idealWidth: 210)
        .safeAreaInset(edge: .bottom) {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
              Circle().fill(model.connection == "Connected to Codex" ? .green : .secondary).frame(
                width: 6, height: 6)
              Text(model.connection).lineLimit(2).font(.caption)
            }
            Button {
              model.perform { try model.commit { $0.settings.paused.toggle() } }
              model.worker.pump()
            } label: {
              Label(
                model.snapshot.settings.paused ? "Resume processing" : "Pause processing",
                systemImage: model.snapshot.settings.paused ? "play.fill" : "pause.fill")
            }.buttonStyle(.plain).font(.caption)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Picker("Show reports", selection: $filter) {
                ForEach(QueueFilter.allCases) { item in
                  Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
              }.labelsHidden().pickerStyle(.menu).fixedSize()
              Text("\(filtered.count) observations").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
              model.captureAction?()
            } label: {
              Image(systemName: "plus")
            }.help("New capture")
            Button {
              model.settingsAction?()
            } label: {
              Image(systemName: "gearshape")
            }.help("Settings")
          }
          TextField("Search reports and feedback", text: $search)
            .textFieldStyle(.roundedBorder).accessibilityLabel("Search reports and feedback")
        }.padding(20)
        Divider()
        if filtered.isEmpty {
          ContentUnavailableView(
            search.isEmpty ? "Nothing here yet" : "No matches", systemImage: "viewfinder",
            description: Text(
              search.isEmpty
                ? "Capture an observation to start the next fix." : "Try another description."))
        } else {
          List(filtered, selection: $model.selectedIssueID) { issue in
            IssueRow(issue: issue, project: model.project(issue.projectID)).tag(issue.id)
              .contextMenu {
                Button(issue.archived ? "Restore report" : "Archive report") {
                  model.setArchived(issue.id, archived: !issue.archived)
                }.disabled(!issue.archived && !issue.canArchive)
              }
          }.listStyle(.inset)
        }
      }.frame(minWidth: 280, idealWidth: 330)
      Group {
        if let id = model.selectedIssueID, let issue = model.issue(id) {
          IssueDetailView(model: model, issue: issue)
        } else {
          WelcomeView(model: model)
        }
      }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
    }
    .overlay(alignment: .bottom) {
      if let banner = model.banner {
        HStack {
          Image(systemName: "exclamationmark.circle")
          Text(banner).lineLimit(4)
          if model.capturePermissionIssue {
            Button("Open Settings") { model.openCaptureSettings() }
            Button("Check again") { Task { await model.recheckCapturePermission() } }
            Button("Reopen app") { model.relaunchAction?() }
          }
          Button("Dismiss") { model.banner = nil }
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06), lineWidth: 0.5)
          )
          .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 3).padding(
            20)
      }
    }
    .onChange(of: model.selectedIssueID) { _, id in if let id { model.markRead(id) } }
    .frame(minWidth: 1000, minHeight: 640)
  }
}
struct IssueRow: View {
  let issue: Issue
  let project: Project?
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let image = issue.captures.first.flatMap({ NSImage(contentsOfFile: $0.imagePath) }) {
        Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 7))
      } else {
        Image(systemName: "photo").frame(width: 48, height: 48).background(
          .quaternary, in: RoundedRectangle(cornerRadius: 7))
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(issue.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
          if issue.unread { Circle().fill(.orange).frame(width: 6, height: 6) }
        }
        Text(project?.name ?? "Choose project").font(.caption).foregroundStyle(.secondary)
        StatusBadge(status: issue.status)
      }
      Spacer(minLength: 0)
    }.padding(.vertical, 9)
  }
}
struct StatusBadge: View {
  let status: IssueStatus
  var color: Color {
    switch status {
    case .working: return .blue
    case .needsProject, .needsYou, .failed: return .orange
    case .merged, .verified: return .green
    default: return .secondary
    }
  }
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(status.title).font(.caption.weight(.medium))
    }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(
      color.opacity(0.10), in: Capsule())
  }
}
struct WelcomeView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Image(systemName: "viewfinder").font(.system(size: 45, weight: .light)).foregroundStyle(
        .orange)
      VStack(alignment: .leading, spacing: 10) {
        Text("Keep your testing flow.").font(.system(size: 28, weight: .semibold))
        Text("Capture what you notice. Follow the fix here.").font(.title3).foregroundStyle(
          .secondary)
      }
      VStack(alignment: .leading, spacing: 18) {
        step("1", "Add your projects", "Map a website or Mac app to its repository.")
        step("2", "Connect Codex", "Choose the runtime and check your sign-in.")
        step("3", "Capture an observation", "Select a region, add a note, and submit.")
      }
      HStack {
        Button("Set up ScreenClip") { model.settingsAction?() }.buttonStyle(.borderedProminent)
          .tint(.orange)
        Button("Take a capture") { model.captureAction?() }
      }
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
  func step(_ number: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number).font(.caption.weight(.semibold)).frame(width: 24, height: 24).background(
        .quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title).fontWeight(.medium)
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct IssueDetailView: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  @State private var chatID = ""
  @State private var showLinkChat = false
  @State private var confirmDelete = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          StatusBadge(status: issue.status)
          Spacer()
          Text(issue.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
        }
        Text(issue.title).font(.system(size: 25, weight: .semibold)).textSelection(.enabled)
        HStack(spacing: 12) {
          if issue.codexURL != nil {
            Button {
              model.openCodex(issue)
            } label: {
              Label("Open in Codex", systemImage: "arrow.up.right.square")
            }
          }
          if let url = issue.prURL.flatMap(URL.init(string:)) {
            Link("View pull request", destination: url)
          }
          if issue.status == .prOpen {
            Button("Refresh PR status") { Task { await model.worker.refreshPRs() } }
          }
          Spacer()
          Button {
            model.setArchived(issue.id, archived: !issue.archived)
          } label: {
            Label(issue.archived ? "Restore" : "Archive", systemImage: "archivebox")
          }.disabled(!issue.archived && !issue.canArchive)
            .help(
              issue.archived || issue.canArchive
                ? "Keep this report's evidence" : "Cancel active work before archiving")
          Menu {
            Button("Link existing chat…") { showLinkChat = true }.disabled(
              issue.status == .working || issue.worktreePath == nil)
            if issue.status != .working {
              Button("Delete local evidence…", role: .destructive) { confirmDelete = true }
            }
          } label: {
            Image(systemName: "ellipsis")
          }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.controlSize(.small)
        if issue.projectID == nil {
          VStack(alignment: .leading, spacing: 10) {
            Text("Choose where to work").fontWeight(.medium)
            Text("This capture is saved. Choose a project to begin.").font(.caption)
              .foregroundStyle(.secondary)
            Menu("Choose project") {
              ForEach(model.snapshot.projects) { project in
                Button(project.name) { model.assignProject(issue.id, projectID: project.id) }
              }
              Button("Add project…") { model.settingsAction?() }
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
            .orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        if let error = issue.lastError {
          Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(
            .orange
          ).textSelection(.enabled)
        }
        if issue.status == .prOpen, let summary = issue.checkSummary {
          Label(summary, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
        }
        if let commit = issue.mergeCommit {
          Text("Merge commit: " + String(commit.prefix(12))).font(.caption).monospaced()
            .foregroundStyle(.secondary).textSelection(.enabled)
        }
        ForEach(issue.questions.filter { $0.reply == nil }) { question in
          QuestionCard(model: model, issue: issue, question: question)
        }
        HStack {
          if issue.status == .draft {
            Button("Edit draft") {
              if let c = issue.captures.first,
                let image = NSImage(contentsOfFile: c.originalPath ?? c.imagePath)
              {
                model.composerAction?(image, c.context, issue)
              }
            }
          }
          if [.needsYou, .failed, .canceled, .draft].contains(issue.status)
            && !issue.dispatchUncertain && issue.questions.allSatisfy({ $0.reply != nil })
          {
            Button("Continue") { model.retry(issue.id) }
          }
          if issue.threadID != nil && [.needsYou, .failed].contains(issue.status) {
            Button("Reconcile chat") { Task { await model.worker.reconcile(issue.id) } }
          }
          if [.working, .queued, .needsYou, .prOpen].contains(issue.status) {
            Button("Cancel work", role: .destructive) {
              Task { await model.worker.cancel(issue.id) }
            }
          }
          if issue.status == .merged {
            Button("Mark verified") {
              model.perform {
                try model.updateIssue(issue.id) {
                  $0.record("Tester verified the fix", status: .verified)
                }
              }
            }.buttonStyle(.borderedProminent).tint(.green)
          }
        }
        if let summary = issue.resultSummary {
          Text(summary).textSelection(.enabled).padding(16).frame(
            maxWidth: .infinity, alignment: .leading
          ).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        ForEach(Array(issue.captures.enumerated()), id: \.element.id) { index, capture in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("CAPTURE \(index+1)").font(.caption.weight(.semibold)).foregroundStyle(
                .secondary)
              Spacer()
              Text(capture.context.capturedAt, style: .time).font(.caption).foregroundStyle(
                .tertiary)
            }
            if let image = NSImage(contentsOfFile: capture.imagePath) {
              Image(nsImage: image).resizable().scaledToFit().frame(
                maxWidth: .infinity, maxHeight: 420
              ).background(Color.black.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !capture.note.isEmpty { Text(capture.note).textSelection(.enabled) }
            DisclosureGroup("Captured context") {
              VStack(alignment: .leading, spacing: 6) {
                contextLine("App", capture.context.appName)
                contextLine("Window", capture.context.windowTitle ?? "Unavailable")
                contextLine("URL", capture.context.browserURL ?? "Unavailable")
                contextLine("Session", capture.context.sessionName)
                contextLine(
                  "Tested version",
                  capture.context.testedVersion.isEmpty ? "Unknown" : capture.context.testedVersion)
                contextLine("Routing", capture.context.routingReason)
              }.font(.caption).padding(.top, 8).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
          }
        }
        Divider()
        Text("ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(issue.activities.suffix(50)) { activity in
          HStack(alignment: .top, spacing: 12) {
            Text(activity.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(
              .tertiary
            ).frame(width: 64, alignment: .leading)
            Text(activity.text).font(.callout).textSelection(.enabled)
          }
        }
        if [.merged, .verified].contains(issue.status) {
          Text(
            "Merged code becomes visible after the relevant build or deployment. Your running app has not been restarted."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.padding(28)
    }
    .alert("Link an existing Codex chat", isPresented: $showLinkChat) {
      TextField("Thread ID or codex://threads/…", text: $chatID)
      Button("Link") {
        let value = chatID.replacingOccurrences(of: "codex://threads/", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
          model.banner = "Enter the thread ID from the Codex chat link."
          return
        }
        Task { await model.worker.reconcile(issue.id, linkingThread: value) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Use the exact chat created for this issue. ScreenClip will check it before continuing.")
    }
    .confirmationDialog(
      "Delete this issue and its local screenshots?", isPresented: $confirmDelete,
      titleVisibility: .visible
    ) {
      Button("Delete local evidence", role: .destructive) { model.delete(issue.id) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Codex chat history, Git worktrees, and pull requests are retained independently.")
    }
  }
  func contextLine(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).frame(width: 90, alignment: .leading)
      Text(value.isEmpty ? "—" : value)
    }
  }
}
struct QuestionCard: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  let question: PendingQuestion
  @State private var answers: [String: String] = [:]
  var queries: [JSONValue] {
    question.requestMethod?.contains("requestUserInput") == true
      ? (question.questions?.array ?? []) : []
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Needs your input", systemImage: "bubble.left").font(.headline).foregroundStyle(.orange)
      Text(question.title).textSelection(.enabled)
      if question.requestID == nil || !queries.isEmpty {
        if queries.isEmpty {
          TextField(
            "Your reply",
            text: Binding(get: { answers["reply"] ?? "" }, set: { answers["reply"] = $0 }),
            axis: .vertical
          ).textFieldStyle(.roundedBorder)
        }
        ForEach(Array(queries.enumerated()), id: \.offset) { _, q in
          VStack(alignment: .leading, spacing: 6) {
            Text(q["header"].string ?? q["id"].string ?? "Answer").font(.caption)
            if !q["options"].array.isEmpty {
              HStack {
                ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in
                  Button(option["label"].string ?? "Option") {
                    answers[q["id"].string ?? "reply"] = option["label"].string
                  }
                }
              }
            }
            TextField(
              "Your answer",
              text: Binding(
                get: { answers[q["id"].string ?? "reply"] ?? "" },
                set: { answers[q["id"].string ?? "reply"] = $0 })
            ).textFieldStyle(.roundedBorder)
          }
        }
        Button("Send reply") {
          Task {
            await model.worker.reply(issueID: issue.id, questionID: question.id, answers: answers)
          }
        }.disabled(
          queries.isEmpty
            ? (answers["reply"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : queries.contains { (answers[$0["id"].string ?? ""] ?? "").isEmpty })
      } else if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"]
        .contains(question.requestMethod ?? "")
      {
        Text(
          question.questions?["command"].string
            ?? "Review the requested change in Codex if you need more detail."
        ).font(.caption.monospaced()).textSelection(.enabled)
        HStack {
          Button("Allow once") {
            Task {
              await model.worker.reply(
                issueID: issue.id, questionID: question.id, answers: [:], allow: true)
            }
          }
          Button("Decline") {
            Task {
              await model.worker.reply(
                issueID: issue.id, questionID: question.id, answers: [:], allow: false)
            }
          }
        }
      } else {
        Button("Review request in Codex") { model.openCodex(issue) }
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
      .orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
}
