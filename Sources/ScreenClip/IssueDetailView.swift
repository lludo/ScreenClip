import ScreenClipCore
import SwiftUI

struct IssueDetailView: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  @State private var chatID = ""
  @State private var showLinkChat = false
  @State private var confirmDelete = false
  @State private var showContextEditor = false
  @State private var showFollowUpEditor = false
  @Environment(\.locale) private var locale
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
            }.buttonStyle(.plain).help(
              Text(chrome: "Copy report number", comment: "Copies the permanent report number."))
              .accessibilityLabel(Text(verbatim: Chrome.format(
                "detail.copyReference", "Copy report number \(reference)", locale: locale,
                comment: "Accessibility label. %@ is the report number, such as #26.")))
          }
          StatusBadge(status: issue.status)
          Spacer()
          Text(issue.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
        }
        Text(verbatim: issue.title).font(.system(size: 25, weight: .semibold)).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          AgentLabel(kind: issue.resolvedAgent).font(.caption)
            .foregroundStyle(.secondary)
            .help(Text(chrome: "Agent working on this issue", comment: "Help for the agent name on a report."))
          if issue.resolvedAgent == .external, issue.prURL == nil {
            Text(verbatim: ExternalAssistant.localizedConversationNote(locale: locale))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if issue.codexURL != nil {
            Button {
              model.openCodex(issue)
            } label: {
              Label {
                Text(chrome: "Open in Codex", comment: "Opens this report's Codex chat.")
              } icon: {
                Image(systemName: "arrow.up.right.square")
              }
            }
          }
          if issue.claudeResumeCommand != nil {
            Button {
              model.openClaudeInDesktop(issue)
            } label: {
              Label {
                Text(chrome: "Open in Claude Desktop", comment: "Opens this report's Claude Code session in the Claude desktop app.")
              } icon: {
                Image(systemName: "arrow.up.right.square")
              }
            }.help(Text(
              chrome: "Needs Claude Code 2.1.285 or newer. Otherwise copy the Terminal command.",
              comment: "Help for the Open in Claude Desktop button."))
            Button {
              model.copyClaudeResumeCommand(issue)
            } label: {
              Label {
                Text(chrome: "Copy Claude resume command", comment: "Copies the Claude Code resume command.")
              } icon: {
                Image(systemName: "terminal")
              }
            }.help(Text(
              chrome: "Copies a Terminal command that reopens this issue's Claude Code session",
              comment: "Help for the Claude resume command button."))
          }
          if let url = issue.prURL.flatMap(URL.init(string:)) {
            Link(destination: url) {
              Text(chrome: "View pull request", comment: "Opens the report's pull request.")
            }
          }
          if issue.status == .prOpen
            || (issue.resolvedAgent == .external && issue.status == .working && !issue.dispatchUncertain)
          {
            Button { Task { await model.worker.refreshPRs() } } label: {
              Text(chrome: "Refresh PR status", comment: "Refreshes pull request checks. Keep PR.")
            }
          }
          Button {
            model.setArchived(issue.id, archived: !issue.archived)
          } label: {
            Label {
              if issue.archived {
                Text(chrome: "Restore", comment: "Restores an archived report.")
              } else {
                Text(chrome: "Archive", comment: "Archives a report.")
              }
            } icon: {
              Image(systemName: "archivebox")
            }
          }.disabled(!issue.archived && !issue.canArchive)
            .help(
              issue.archived || issue.canArchive
                ? Text(chrome: "Keep this report's evidence", comment: "Help for archive when it is allowed.")
                : Text(chrome: "Cancel active work before archiving", comment: "Help when archive is blocked."))
          if issue.resolvedAgent != .external || issue.status != .working {
            Menu {
              if issue.resolvedAgent != .external {
                Button { showLinkChat = true } label: {
                  Text(chrome: "Link existing chat…", comment: "Links a report to an existing agent chat.")
                }.disabled(issue.status == .working || issue.worktreePath == nil)
              }
              if model.canMove(issue) && model.snapshot.projects.count > 1 {
                Menu {
                  ForEach(model.snapshot.projects.filter { $0.id != issue.projectID }) { project in
                    Button(project.name, systemImage: project.displaySymbol) {
                      model.perform { _ = try model.moveToProject(issue.id, projectID: project.id) }
                    }
                  }
                } label: {
                  Text(chrome: "Move to project", comment: "Moves a report to another project.")
                }
              }
              if issue.canDelete && !model.worker.isActive(issue.id) {
                Button(role: .destructive) { confirmDelete = true } label: {
                  Text(chrome: "Delete local evidence…", comment: "Deletes local screenshots for this report.")
                }
              }
            } label: {
              Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          }
        }.controlSize(.small)
        if issue.projectID == nil {
          VStack(alignment: .leading, spacing: 10) {
            Text(chrome: "Choose where to work", comment: "Prompt when a capture has no project.")
              .fontWeight(.medium)
            Text(
              chrome: "This capture is saved. Choose a project to begin.",
              comment: "Explains that a capture is saved before a project is chosen."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Menu {
              ForEach(model.snapshot.projects) { project in
                Button(project.name, systemImage: project.displaySymbol) { model.assignProject(issue.id, projectID: project.id) }
              }
              Button { model.settingsAction?() } label: {
                Text(chrome: "Add project…", comment: "Opens Settings to add a project.")
              }
            } label: {
              Text(chrome: "Choose project", comment: "Menu of projects for an unassigned capture.")
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
            .orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        if let error = issue.lastError {
          Label {
            Text(verbatim: Chrome.stored(error, locale: locale)).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.circle")
          }.font(.callout).foregroundStyle(.orange)
        }
        if issue.status == .prOpen, let summary = issue.checkSummary {
          Label {
            Text(verbatim: Chrome.stored(summary, locale: locale))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: summary == ExternalAssistant.evidenceStillPresentSummary
              ? "exclamationmark.circle" : "clock")
          }.font(.callout).foregroundStyle(
            summary == ExternalAssistant.evidenceStillPresentSummary ? .orange : .secondary)
        }
        if let commit = issue.mergeCommit {
          Text(verbatim: Chrome.format(
            "detail.mergeCommit", "Merge commit: \(String(commit.prefix(12)))", locale: locale,
            comment: "Shows the short merge commit. %@ is the commit prefix."))
            .font(.caption).monospaced().foregroundStyle(.secondary).textSelection(.enabled)
        }
        ForEach(issue.questions.filter { $0.reply == nil }) { question in
          QuestionCard(model: model, issue: issue, question: question)
        }
        FlowLayout {
          Button {
            showContextEditor = true
          } label: {
            Label {
              Text(chrome: "Add context", comment: "Adds a text note to the report.")
            } icon: {
              Image(systemName: "text.bubble")
            }
          }
          if issue.status == .draft {
            Button {
              if let c = issue.captures.first,
                let image = NSImage(contentsOfFile: c.originalPath ?? c.imagePath)
              {
                model.composerAction?(image, c.context, issue)
              }
            } label: {
              Text(chrome: "Edit draft", comment: "Reopens a draft in the composer.")
            }
          }
          if [.needsYou, .failed, .canceled, .draft].contains(issue.status)
            && !issue.dispatchUncertain && issue.questions.allSatisfy({ $0.reply != nil })
          {
            Button { model.retry(issue.id) } label: {
              if issue.resolvedAgent == .external && issue.status == .failed {
                Text(chrome: "Retry", comment: "Sends a failed Grok Bot report again.")
              } else {
                Text(chrome: "Continue", comment: "Continues agent work on this report.")
              }
            }
          }
          if issue.resolvedAgent != .external && issue.threadID != nil
            && [.needsYou, .failed].contains(issue.status)
          {
            Button { Task { await model.worker.reconcile(issue.id) } } label: {
              Text(chrome: "Reconcile chat", comment: "Recovers a saved agent chat.")
            }
          }
          if [.working, .queued, .needsYou, .prOpen].contains(issue.status) {
            Button(role: .destructive) {
              Task { await model.worker.cancel(issue.id) }
            } label: {
              Text(chrome: "Cancel work", comment: "Cancels local work on this report.")
            }
          }
          if issue.status == .merged {
            Button {
              model.perform {
                try model.updateIssue(issue.id) {
                  $0.record("Tester verified the fix", status: .verified)
                }
              }
            } label: {
              Text(chrome: "Mark verified", comment: "Marks a merged fix as verified.")
            }.buttonStyle(.borderedProminent).tint(.green)
          }
          if [.merged, .verified].contains(issue.status) {
            Button {
              showFollowUpEditor = true
            } label: {
              Label {
                Text(chrome: "Needs follow-up", comment: "Asks the agent to continue after a merge.")
              } icon: {
                Image(systemName: "arrow.uturn.backward.circle")
              }
            }.help(Text(
              chrome: "Describe what was not addressed; the agent starts a new fix with your feedback.",
              comment: "Help for the follow-up button."))
          }
        }
        if let summary = issue.resultSummary {
          Text(verbatim: summary).textSelection(.enabled).padding(16).frame(
            maxWidth: .infinity, alignment: .leading
          ).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        ForEach(Array(issue.captures.enumerated()), id: \.element.id) { index, capture in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(verbatim: Chrome.format(
                "capture.heading", "CAPTURE \(index + 1)", locale: locale,
                comment: "Heading above a screenshot. %lld is the capture number."))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Spacer()
              Text(capture.context.capturedAt, style: .time).font(.caption).foregroundStyle(
                .tertiary)
            }
            if let image = NSImage(contentsOfFile: capture.imagePath) {
              Image(nsImage: image).resizable().scaledToFit().frame(
                maxWidth: .infinity, maxHeight: 420
              ).background(Color.black.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !capture.note.isEmpty {
              Text(verbatim: capture.note).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup {
              VStack(alignment: .leading, spacing: 6) {
                contextLine(
                  Chrome.text("App", locale: locale, comment: "Capture context label."),
                  capture.context.appName)
                contextLine(
                  Chrome.text("Window", locale: locale, comment: "Capture context label."),
                  capture.context.windowTitle ?? Chrome.text(
                    "Unavailable", locale: locale, comment: "Missing window title."))
                contextLine(
                  Chrome.text("URL", locale: locale, comment: "Capture context label. Keep URL."),
                  capture.context.browserURL ?? Chrome.text(
                    "Unavailable", locale: locale, comment: "Missing browser URL."))
                contextLine(
                  Chrome.text("Session", locale: locale, comment: "Capture context label."),
                  capture.context.sessionName)
                contextLine(
                  Chrome.text("Tested version", locale: locale, comment: "Capture context label."),
                  capture.context.testedVersion.isEmpty
                    ? Chrome.text("Unknown", locale: locale, comment: "Missing tested version.")
                    : capture.context.testedVersion)
                contextLine(
                  Chrome.text("Routing", locale: locale, comment: "Capture context label."),
                  Chrome.stored(capture.context.routingReason, locale: locale))
              }.font(.caption).padding(.top, 8).textSelection(.enabled)
            } label: {
              Text(chrome: "Captured context", comment: "Disclosure heading for capture metadata.")
            }.font(.caption).foregroundStyle(.secondary)
          }
        }
        if let notes = issue.contextNotes, !notes.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Text(chrome: "ADDED CONTEXT", comment: "Heading above notes added after filing.")
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(notes) { note in
              VStack(alignment: .leading, spacing: 6) {
                Text(note.date, format: .dateTime.month().day().hour().minute())
                  .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: note.text).textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        Divider()
        Text(chrome: "ACTIVITY", comment: "Heading above the report activity log.")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(issue.activities.suffix(50)) { activity in
          HStack(alignment: .top, spacing: 12) {
            Text(activity.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(
              .tertiary
            ).fixedSize().frame(minWidth: 72, alignment: .leading)
            Text(verbatim: Chrome.stored(activity.text, locale: locale)).font(.callout)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
        }
        if [.merged, .verified].contains(issue.status) {
          Text(
            chrome:
              "Merged code becomes visible after the relevant build or deployment. Your running app has not been restarted.",
            comment: "Shown after a fix merges, before the user retests."
          ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.padding(28)
    }
    .sheet(isPresented: $showFollowUpEditor) {
      ContextNoteEditor(model: model, issueID: issue.id, followUp: true)
    }
    .sheet(isPresented: $showContextEditor) {
      ContextNoteEditor(model: model, issueID: issue.id)
    }
    .alert(
      issue.resolvedAgent == .claude
        ? Chrome.text(
          "Link an existing Claude Code session", locale: locale,
          comment: "Alert title for linking a Claude Code session.")
        : Chrome.text(
          "Link an existing Codex chat", locale: locale,
          comment: "Alert title for linking a Codex chat."),
      isPresented: $showLinkChat
    ) {
      TextField(
        "",
        text: $chatID,
        prompt: Text(
          verbatim: issue.resolvedAgent == .claude
            ? Chrome.text("Session ID", locale: locale, comment: "Placeholder for a Claude Code session ID.")
            : Chrome.text(
              "Thread ID or codex://threads/…", locale: locale,
              comment: "Placeholder for a Codex thread. Keep the codex://threads/ scheme.")))
      Button {
        let value = chatID.replacingOccurrences(of: "codex://threads/", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
          model.banner =
            issue.resolvedAgent == .claude
            ? "Enter the Claude Code session ID." : "Enter the thread ID from the Codex chat link."
          return
        }
        Task { await model.worker.reconcile(issue.id, linkingThread: value) }
      } label: {
        Text(chrome: "Link", comment: "Confirms linking an existing chat.")
      }
      Button(role: .cancel) {} label: {
        Text(chrome: "Cancel", comment: "Dismisses the link-chat alert.")
      }
    } message: {
      Text(
        chrome: "Use the exact chat created for this issue. ScreenClip will check it before continuing.",
        comment: "Explains that the linked chat must belong to this report.")
    }
    .confirmationDialog(
      Chrome.text(
        "Delete this issue and its local screenshots?", locale: locale,
        comment: "Confirmation before deleting local evidence."),
      isPresented: $confirmDelete,
      titleVisibility: .visible
    ) {
      Button(role: .destructive) { model.delete(issue.id) } label: {
        Text(chrome: "Delete local evidence", comment: "Confirms deletion of local screenshots.")
      }
      Button(role: .cancel) {} label: {
        Text(chrome: "Cancel", comment: "Dismisses deletion.")
      }
    } message: {
      Text(verbatim: Chrome.format(
        "detail.deleteRetained",
        "\(issue.resolvedAgent.title) history, Git worktrees, and pull requests are retained independently.",
        locale: locale,
        comment: "Deletion warning. %@ is the agent product name. Keep Git."))
    }
  }
  func contextLine(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(verbatim: label).frame(minWidth: 108, alignment: .leading).fixedSize()
      Text(verbatim: value.isEmpty ? "—" : value).fixedSize(horizontal: false, vertical: true)
    }
  }
}
