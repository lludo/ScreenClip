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
      }.frame(minWidth: 190, idealWidth: 210, maxHeight: .infinity)
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              if isReportLookup {
                Text("Report search").fontWeight(.semibold)
              } else {
                Picker("Show reports", selection: $filter) {
                  ForEach(QueueFilter.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                  }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
              }
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
                ? "Capture an observation to start the next fix."
                : "Try a report number or another description."))
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
      }.frame(minWidth: 280, idealWidth: 330, maxHeight: .infinity, alignment: .top)
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
  private var sidebarList: some View {
    List {
      Section {
        ForEach(QueueFilter.allCases) { item in
          Button {
            filter = item
          } label: {
            HStack {
              Label(item.rawValue, systemImage: item.symbol)
              Spacer()
              // Counts follow the project filter so they match the list they open.
              Text(
                "\(model.snapshot.issues.filter { item.includes($0, projectID: projectFilter) }.count)"
              ).foregroundStyle(.secondary).monospacedDigit()
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
    }.listStyle(.sidebar).labelStyle(SidebarLabelStyle())
  }
  private var sidebarFooter: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.agentStatuses, id: \.kind) { status in
        HStack(spacing: 6) {
          Circle().fill(status.ready ? .green : .secondary).frame(width: 6, height: 6)
          Text(status.text).lineLimit(2).font(.caption)
            .foregroundStyle(status.ready ? .primary : .secondary)
        }
      }
      Button {
        model.togglePaused()
      } label: {
        Label(
          model.snapshot.settings.paused ? "Resume processing" : "Pause processing",
          systemImage: model.snapshot.settings.paused ? "play.fill" : "pause.fill")
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
