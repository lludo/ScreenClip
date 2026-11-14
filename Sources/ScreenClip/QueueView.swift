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
  func includes(
    _ issue: Issue, projectID: UUID? = nil, agent: AgentKind? = nil, search: String = ""
  ) -> Bool {
    if Issue.parseReportReference(search) != nil { return issue.matchesSearch(search) }
    guard projectID == nil || projectID == issue.projectID,
      agent == nil || agent == issue.resolvedAgent, issue.matchesSearch(search)
    else {
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
/// The one thing selected in the sidebar: a report status or a project's settings.
enum SidebarSelection: Hashable {
  case status(QueueFilter)
  case project(UUID)
  case newProject
}

struct QueueView: View {
  @ObservedObject var model: AppModel
  @State private var selection: SidebarSelection
  @State private var projectFilter: UUID?
  @State private var agentFilter: AgentKind?
  @State private var showingFilters = false
  @State private var search = ""
  init(
    model: AppModel, selection: SidebarSelection = .status(.active),
    projectFilter: UUID? = nil, agentFilter: AgentKind? = nil
  ) {
    self.model = model
    _selection = State(initialValue: selection)
    _projectFilter = State(initialValue: projectFilter)
    _agentFilter = State(initialValue: agentFilter)
  }
  var isReportLookup: Bool { Issue.parseReportReference(search) != nil }
  var filter: QueueFilter {
    if case .status(let item) = selection { return item }
    return .active
  }
  var filtered: [Issue] {
    model.snapshot.issues.filter {
      filter.includes($0, projectID: projectFilter, agent: agentFilter, search: search)
    }
  }
  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        sidebarList
        Divider()
        sidebarFooter
      }
      // Fixed width so the sidebar doesn't jump when the panes beside it change.
      .frame(width: 220).frame(maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      switch selection {
      case .status:
        reportList
        reportDetail
      case .project(let id):
        if let project = model.project(id) {
          projectSettings(project, isNew: false)
        } else {
          reportList
          reportDetail
        }
      case .newProject:
        projectSettings(Project(name: "", path: ""), isNew: true)
      }
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
    .onChange(of: model.snapshot.projects.map(\.id)) { _, ids in
      // Drop a filter or selection that points at a project that no longer exists.
      if let id = projectFilter, !ids.contains(id) { projectFilter = nil }
      if case .project(let id) = selection, !ids.contains(id) { selection = .status(.active) }
    }
    .frame(minWidth: 1000, minHeight: 640)
  }
  private var reportList: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        // The sidebar picks the status; this menu narrows it by project and by agent.
        HStack(alignment: .center, spacing: 8) {
          if isReportLookup {
            Text("Report search").fontWeight(.semibold)
          } else {
            filterMenu
          }
          Button {
            model.captureAction?()
          } label: {
            Image(systemName: "plus").frame(width: 16, height: 16)
          }.help("New capture").accessibilityLabel("New capture")
          Button {
            model.settingsAction?()
          } label: {
            Image(systemName: "gearshape").frame(width: 16, height: 16)
          }.help("Settings").accessibilityLabel("Settings")
        }.controlSize(.regular).buttonStyle(.bordered)
        TextField("Search reports and feedback", text: $search)
          .textFieldStyle(.roundedBorder).accessibilityLabel("Search reports and feedback")
      }.padding(20)
      Divider()
      if filtered.isEmpty {
        ContentUnavailableView {
          Label(search.isEmpty ? "Nothing here yet" : "No matches", systemImage: "viewfinder")
        } description: {
          Text(emptyDescription)
        } actions: {
          if isFiltered && search.isEmpty {
            Button("Show everything") {
              projectFilter = nil
              agentFilter = nil
            }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
  }
  private var reportDetail: some View {
    Group {
      if let id = model.selectedIssueID, let issue = model.issue(id) {
        // A fresh identity per issue resets dialogs and typed chat IDs on selection change.
        IssueDetailView(model: model, issue: issue).id(issue.id)
      } else {
        WelcomeView(model: model)
      }
    }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
  }
  private var emptyDescription: String {
    if !search.isEmpty { return "Try a report number or another description." }
    if isFiltered { return "No \(filter.rawValue.lowercased()) reports for \(filterSummary)." }
    return "Capture an observation to start the next fix."
  }
  private var isFiltered: Bool { projectFilter != nil || agentFilter != nil }
  /// "All", one name, or "Project – Agent"; an "All" side is left out of a combined summary.
  private var filterSummary: String {
    let project = projectFilter.flatMap { model.project($0)?.name }
    let parts = [project, agentFilter?.title].compactMap { $0 }
    return parts.isEmpty ? "All" : parts.joined(separator: " – ")
  }
  private func filterCount(project: UUID? = nil, agent: AgentKind? = nil) -> Int {
    model.snapshot.issues.filter { filter.includes($0, projectID: project, agent: agent) }.count
  }
  private func filterOption(
    _ title: String, symbol: String? = nil, count: Int, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      showingFilters = false
    } label: {
      HStack(spacing: 8) {
        Image(systemName: selected ? "checkmark" : "circle.fill")
          .opacity(selected ? 1 : 0).frame(width: 12)
        if let symbol { Image(systemName: symbol).frame(width: 16) }
        Text(title)
        Spacer(minLength: 16)
        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  /// Counts reflect the current status and the other active filter.
  private var filterMenu: some View {
    Button { showingFilters.toggle() } label: {
      HStack(spacing: 5) {
        Image(systemName: isFiltered
          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        Text(filterSummary).lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 24)
      .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.top, 4)
        filterOption("All projects", symbol: "square.grid.2x2", count: filterCount(agent: agentFilter), selected: projectFilter == nil) { projectFilter = nil }
        ForEach(model.snapshot.projects) { project in
          let count = filterCount(project: project.id, agent: agentFilter)
          if count > 0 || projectFilter == project.id {
            filterOption(project.name, symbol: project.displaySymbol, count: count, selected: projectFilter == project.id) { projectFilter = project.id }
          }
        }
        Divider().padding(.vertical, 4)
        Text("AI agents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 8)
        filterOption("All AI agents", symbol: "sparkles", count: filterCount(project: projectFilter), selected: agentFilter == nil) { agentFilter = nil }
        ForEach(AgentKind.allCases) { agent in
          let count = filterCount(project: projectFilter, agent: agent)
          if count > 0 || agentFilter == agent {
            filterOption(agent.title, symbol: "sparkles", count: count, selected: agentFilter == agent) { agentFilter = agent }
          }
        }
      }.padding(8).frame(minWidth: 210)
    }
    .help(isFiltered ? "Showing \(filterSummary)" : "Filter reports by project and AI agent")
    .accessibilityLabel("Filter: \(filterSummary)")
  }
  private func projectSettings(_ project: Project, isNew: Bool) -> some View {
    ScrollView {
      ProjectEditor(
        model: model, project: project,
        onSaved: { selection = .project($0) },
        onRemoved: {
          if projectFilter == project.id { projectFilter = nil }
          selection = .status(.active)
        }
      )
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // A fresh identity per project resets the editor's unsaved fields on selection change.
    .id(isNew ? "new-project" : project.id.uuidString)
    .frame(minWidth: 730, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
  }
  private var sidebarList: some View {
    List {
      Section {
        ForEach(QueueFilter.allCases) { item in
          Button {
            selection = .status(item)
          } label: {
            HStack {
              Label(item.rawValue, systemImage: item.symbol)
              Spacer()
              // Counts follow the toolbar's filters so they match the list they open.
              Text(
                "\(model.snapshot.issues.filter { item.includes($0, projectID: projectFilter, agent: agentFilter) }.count)"
              ).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 4).contentShape(Rectangle())
            .fontWeight(selection == .status(item) ? .semibold : .regular)
          }.buttonStyle(.plain)
            .listRowBackground(sidebarHighlight(selection == .status(item)))
        }
      } header: {
        sidebarHeader("WORKSPACE")
      }
      Section {
        ForEach(model.snapshot.projects) { project in
          Button {
            selection = .project(project.id)
          } label: {
            Label(project.name, systemImage: project.displaySymbol)
              .fontWeight(selection == .project(project.id) ? .semibold : .regular)
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain).help("Project settings")
            .listRowBackground(sidebarHighlight(selection == .project(project.id)))
        }
        Button {
          selection = .newProject
        } label: {
          Label("Add project…", systemImage: "plus")
            .fontWeight(selection == .newProject ? .semibold : .regular)
            .foregroundStyle(selection == .newProject ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .listRowBackground(sidebarHighlight(selection == .newProject))
      } header: {
        sidebarHeader("PROJECTS")
      }
    }.listStyle(.sidebar).scrollContentBackground(.hidden).labelStyle(SidebarLabelStyle())
      // Sidebar rows tint icons with the system accent unless told otherwise.
      .listItemTint(.fixed(.orange)).tint(.orange)
  }
  /// Section titles in Finder's gray (secondary label), not the extra-dimmed default.
  private func sidebarHeader(_ title: String) -> some View {
    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
  }
  /// Finder-style selection: a rounded neutral pill behind the row, with bolder text.
  @ViewBuilder private func sidebarHighlight(_ selected: Bool) -> some View {
    if selected {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.1)).padding(.horizontal, 6)
    } else {
      Color.clear
    }
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
