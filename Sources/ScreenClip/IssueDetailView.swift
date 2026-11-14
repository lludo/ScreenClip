import ScreenClipCore
import SwiftUI

struct IssueDetailView: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  @State private var chatID = ""
  @State private var showLinkChat = false
  @State private var confirmDelete = false
  @State private var showContextEditor = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          if let reference = issue.reportReference {
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(reference, forType: .string)
            } label: {
              Text(reference).font(.callout.weight(.semibold)).monospacedDigit()
            }.buttonStyle(.plain).help("Copy report number")
              .accessibilityLabel("Copy report number \(reference)")
          }
          StatusBadge(status: issue.status)
          Spacer()
          Text(issue.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
        }
        Text(issue.title).font(.system(size: 25, weight: .semibold)).textSelection(.enabled)
        HStack(spacing: 12) {
          Label(issue.resolvedAgent.title, systemImage: "cpu").font(.caption)
            .foregroundStyle(.secondary).help("Agent working on this issue")
          if let note = issue.externalConversationNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
          }
          if issue.codexURL != nil {
            Button {
              model.openCodex(issue)
            } label: {
              Label("Open in Codex", systemImage: "arrow.up.right.square")
            }
          }
          if issue.claudeResumeCommand != nil {
            Button {
              model.copyClaudeResumeCommand(issue)
            } label: {
              Label("Copy Claude resume command", systemImage: "terminal")
            }.help("Copies a Terminal command that reopens this issue's Claude Code session")
          }
          if let url = issue.prURL.flatMap(URL.init(string:)) {
            Link("View pull request", destination: url)
          }
          if issue.status == .prOpen
            || (issue.resolvedAgent == .external && issue.status == .working && !issue.dispatchUncertain)
          {
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
          if issue.resolvedAgent != .external || issue.status != .working {
            Menu {
              if issue.resolvedAgent != .external {
                Button("Link existing chat…") { showLinkChat = true }.disabled(
                  issue.status == .working || issue.worktreePath == nil)
              }
              if issue.canDelete && !model.worker.isActive(issue.id) {
                Button("Delete local evidence…", role: .destructive) { confirmDelete = true }
              }
            } label: {
              Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          }
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
          Label(summary, systemImage: summary == ExternalAssistant.evidenceStillPresentSummary
            ? "exclamationmark.circle" : "clock"
          ).font(.callout).foregroundStyle(
            summary == ExternalAssistant.evidenceStillPresentSummary ? .orange : .secondary)
        }
        if let commit = issue.mergeCommit {
          Text("Merge commit: " + String(commit.prefix(12))).font(.caption).monospaced()
            .foregroundStyle(.secondary).textSelection(.enabled)
        }
        ForEach(issue.questions.filter { $0.reply == nil }) { question in
          QuestionCard(model: model, issue: issue, question: question)
        }
        HStack {
          Button {
            showContextEditor = true
          } label: {
            Label("Add context", systemImage: "text.bubble")
          }
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
            Button(issue.resolvedAgent == .external && issue.status == .failed ? "Retry" : "Continue")
            { model.retry(issue.id) }
          }
          if issue.resolvedAgent != .external && issue.threadID != nil
            && [.needsYou, .failed].contains(issue.status)
          {
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
        if let notes = issue.contextNotes, !notes.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Text("ADDED CONTEXT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(notes) { note in
              VStack(alignment: .leading, spacing: 6) {
                Text(note.date, format: .dateTime.month().day().hour().minute())
                  .font(.caption).foregroundStyle(.secondary)
                Text(note.text).textSelection(.enabled)
              }
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
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
    .sheet(isPresented: $showContextEditor) {
      ContextNoteEditor(model: model, issueID: issue.id)
    }
    .alert(
      issue.resolvedAgent == .claude
        ? "Link an existing Claude Code session" : "Link an existing Codex chat",
      isPresented: $showLinkChat
    ) {
      TextField(
        issue.resolvedAgent == .claude ? "Session ID" : "Thread ID or codex://threads/…",
        text: $chatID)
      Button("Link") {
        let value = chatID.replacingOccurrences(of: "codex://threads/", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
          model.banner =
            issue.resolvedAgent == .claude
            ? "Enter the Claude Code session ID." : "Enter the thread ID from the Codex chat link."
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
      Text(
        "\(issue.resolvedAgent.title) history, Git worktrees, and pull requests are retained independently."
      )
    }
  }
  func contextLine(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).frame(width: 90, alignment: .leading)
      Text(value.isEmpty ? "—" : value)
    }
  }
}
