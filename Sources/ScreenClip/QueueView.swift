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
  func includes(_ issue: Issue, projectID: UUID? = nil, search: String = "") -> Bool {
    if Issue.parseReportReference(search) != nil { return issue.matchesSearch(search) }
    guard projectID == nil || projectID == issue.projectID, issue.matchesSearch(search) else {
      return false
    }
    if self == .archived { return issue.archived }
    if issue.archived { return false }
    switch self {
    case .active: return issue.status.isActive
    case .attention: return issue.wantsAttention
    case .retest: return issue.status == .merged
    case .drafts: return issue.status == .draft
    case .history: return [.merged, .verified, .canceled].contains(issue.status)
    case .archived: return true
    }
  }
}
struct QueueView: View {
  @ObservedObject var model: AppModel
  @Environment(\.locale) private var locale
  @State private var filter: QueueFilter = .active
  @State private var projectFilter: UUID?
  @State private var search = ""
  var isReportLookup: Bool { Issue.parseReportReference(search) != nil }
  var filtered: [Issue] {
    model.snapshot.issues.filter {
      filter.includes($0, projectID: projectFilter, search: search)
    }
  }
  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        sidebarList
        Divider()
        sidebarFooter
      }.frame(minWidth: 230, idealWidth: 260, maxHeight: .infinity)
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          // One row of equal-height controls; the sidebar already shows each filter's count.
          HStack(alignment: .center, spacing: 8) {
            if isReportLookup {
              Text(chrome: "Report search", comment: "Title when a report number bypasses the status filter.")
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            } else {
              Picker(selection: $filter) {
                ForEach(QueueFilter.allCases) { item in
                  Label {
                    Text(verbatim: item.localizedTitle(locale: locale))
                  } icon: {
                    Image(systemName: item.symbol)
                  }.tag(item)
                }
              } label: {
                Text(chrome: "Show reports", comment: "Accessibility label for the queue status filter.")
              }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Spacer(minLength: 8)
            Button {
              model.captureAction?()
            } label: {
              Image(systemName: "plus").frame(width: 16, height: 16)
            }.help(Text(chrome: "New capture", comment: "Starts a capture from the queue."))
              .accessibilityLabel(Text(chrome: "New capture", comment: "Starts a capture from the queue."))
            Button {
              model.settingsAction?()
            } label: {
              Image(systemName: "gearshape").frame(width: 16, height: 16)
            }.help(Text(chrome: "Settings", comment: "Opens Settings from the queue."))
              .accessibilityLabel(Text(chrome: "Settings", comment: "Opens Settings from the queue."))
          }.controlSize(.regular).buttonStyle(.bordered)
          TextField(
            "", text: $search,
            prompt: Text(
              chrome: "Search reports and feedback", comment: "Placeholder for the queue search field.")
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(
            Text(chrome: "Search reports and feedback", comment: "Accessibility label for queue search."))
        }.padding(20)
        Divider()
        if filtered.isEmpty {
          ContentUnavailableView {
            Label {
              if search.isEmpty {
                Text(chrome: "Nothing here yet", comment: "Empty queue title.")
              } else {
                Text(chrome: "No matches", comment: "Search returned no reports.")
              }
            } icon: {
              Image(systemName: "viewfinder")
            }
          } description: {
            if search.isEmpty {
              Text(
                chrome: "Capture an observation to start the next fix.",
                comment: "Empty queue explanation.")
            } else {
              Text(
                chrome: "Try a report number or another description.",
                comment: "Search with no results.")
            }
          }
        } else {
          List(filtered, selection: $model.selectedIssueID) { issue in
            IssueRow(issue: issue, project: model.project(issue.projectID)).tag(issue.id)
              .contextMenu {
                Button {
                  model.setArchived(issue.id, archived: !issue.archived)
                } label: {
                  if issue.archived {
                    Text(chrome: "Restore report", comment: "Puts an archived report back in the queue.")
                  } else {
                    Text(chrome: "Archive report", comment: "Archives a report without deleting evidence.")
                  }
                }.disabled(!issue.archived && !issue.canArchive)
              }
          }.listStyle(.inset)
        }
      }.frame(minWidth: 300, idealWidth: 360, maxHeight: .infinity, alignment: .top)
      Group {
        if let id = model.selectedIssueID, let issue = model.issue(id) {
          // A fresh identity per issue resets dialogs and typed chat IDs on selection change.
          IssueDetailView(model: model, issue: issue).id(issue.id)
        } else {
          WelcomeView(model: model)
        }
      }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if let banner = model.banner {
        HStack {
          Image(systemName: "exclamationmark.circle")
          Text(verbatim: Chrome.stored(banner, locale: locale)).lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
          if model.capturePermissionIssue {
            Button { model.openCaptureSettings() } label: {
              Text(chrome: "Open Settings", comment: "Opens Screen Recording settings from the banner.")
            }
            Button { Task { await model.recheckCapturePermission() } } label: {
              Text(chrome: "Check again", comment: "Rechecks screen capture permission.")
            }
            Button { model.relaunchAction?() } label: {
              Text(chrome: "Reopen app", comment: "Relaunches ScreenClip so capture permission can refresh.")
            }
          }
          Button { model.banner = nil } label: {
            Text(chrome: "Dismiss", comment: "Closes the queue banner.")
          }
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
  private var sidebarList: some View {
    List {
      Section {
        ForEach(QueueFilter.allCases) { item in
          Button {
            filter = item
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Label {
                Text(verbatim: item.localizedTitle(locale: locale))
                  .fixedSize(horizontal: false, vertical: true)
                  .lineLimit(2)
              } icon: {
                Image(systemName: item.symbol)
              }
              Spacer(minLength: 8)
              // Counts follow the project filter so they match the list they open.
              Text(
                model.snapshot.issues.filter { item.includes($0, projectID: projectFilter) }.count,
                format: .number
              ).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            .padding(.vertical, 4).foregroundStyle(filter == item ? Color.orange : Color.primary)
          }.buttonStyle(.plain)
        }
      } header: {
        Text(chrome: "WORKSPACE", comment: "Sidebar section heading for status filters.")
      }
      Section {
        Button {
          projectFilter = nil
        } label: {
          Label {
            Text(chrome: "All projects", comment: "Clears the project filter.")
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "square.grid.2x2")
          }.foregroundStyle(projectFilter == nil ? .orange : .primary)
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
          Label {
            Text(chrome: "Manage projects…", comment: "Opens project settings from the sidebar.")
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "plus")
          }
        }.buttonStyle(.plain).foregroundStyle(.secondary)
      } header: {
        Text(chrome: "PROJECTS", comment: "Sidebar section heading for projects.")
      }
    }.listStyle(.sidebar).labelStyle(SidebarLabelStyle())
  }
  private var sidebarFooter: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.agentStatuses, id: \.kind) { status in
        HStack(spacing: 6) {
          Circle().fill(status.ready ? .green : .secondary).frame(width: 6, height: 6)
          Text(verbatim: Chrome.stored(status.text, locale: locale)).lineLimit(3).font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(status.ready ? .primary : .secondary)
        }
      }
      Button {
        model.togglePaused()
      } label: {
        Label {
          if model.snapshot.settings.paused {
            Text(chrome: "Resume processing", comment: "Resumes the report queue.")
          } else {
            Text(chrome: "Pause processing", comment: "Pauses the report queue.")
          }
        } icon: {
          Image(systemName: model.snapshot.settings.paused ? "play.fill" : "pause.fill")
        }
      }.buttonStyle(.plain).font(.caption)
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .windowBackgroundColor))
  }
}

/// Sidebar icons use the app's orange accent instead of the system accent color.
struct SidebarLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    Label {
      configuration.title
    } icon: {
      configuration.icon.foregroundStyle(.orange)
    }
  }
}
