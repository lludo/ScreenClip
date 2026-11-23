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
  /// The first status list that shows `issue` under the given filters, or nil when none does.
  static func showing(
    _ issue: Issue, projectID: UUID? = nil, agent: AgentKind? = nil, search: String = ""
  ) -> QueueFilter? {
    allCases.first { $0.includes(issue, projectID: projectID, agent: agent, search: search) }
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
  @Environment(\.locale) private var locale
  @State private var selection: SidebarSelection
  @State private var projectFilter: UUID?
  @State private var agentFilter: AgentKind?
  @State private var showingFilters = false
  @State private var search = ""
  @FocusState private var searchFocused: Bool
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
  /// Newest first, like the menu bar popover and the composer's Issue menu.
  var filtered: [Issue] {
    Issue.newestFirst(model.snapshot.issues.filter {
      filter.includes($0, projectID: projectFilter, agent: agentFilter, search: search)
    })
  }
  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        sidebarList
        Divider()
        sidebarFooter
      }
      // Fixed width so the sidebar doesn't jump when the panes beside it change.
      .frame(width: 240).frame(maxHeight: .infinity)
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
    .onChange(of: model.selectedIssueID) { _, id in
      if let id { model.markRead(id) }
      revealSelection()
    }
    // A report that leaves the list after its status changes (verified, archived, answered)
    // closes, and the list the person was working through stays.
    .onChange(of: selectedIssue?.status) { _, _ in dropHiddenSelection() }
    .onChange(of: selectedIssue?.archived) { _, _ in dropHiddenSelection() }
    // A list the person picks never keeps a report it doesn't show open beside it.
    .onChange(of: selection) { _, _ in dropHiddenSelection() }
    .onChange(of: projectFilter) { _, _ in dropHiddenSelection() }
    .onChange(of: agentFilter) { _, _ in dropHiddenSelection() }
    .onChange(of: search) { _, _ in dropHiddenSelection() }
    .onChange(of: model.queueFilterRequest) { _, _ in applyQueueFilterRequest() }
    .onAppear {
      applyQueueFilterRequest()
      revealSelection()
    }
    .onChange(of: model.snapshot.projects.map(\.id)) { _, ids in
      // Drop a filter or selection that points at a project that no longer exists.
      if let id = projectFilter, !ids.contains(id) { projectFilter = nil }
      if case .project(let id) = selection, !ids.contains(id) { selection = .status(.active) }
    }
    .frame(minWidth: 1000, minHeight: 640)
  }
  private var selectedIssue: Issue? { model.selectedIssueID.flatMap(model.issue) }
  /// The open report when the report list is on screen but doesn't include it.
  private var hiddenSelection: Issue? {
    guard case .status = selection, let issue = selectedIssue,
      !filter.includes(issue, projectID: projectFilter, agent: agentFilter, search: search)
    else { return nil }
    return issue
  }
  /// Switches the list to one that shows the open report, e.g. after a notification opens it.
  private func revealSelection() {
    guard let issue = hiddenSelection else { return }
    if let status = QueueFilter.showing(
      issue, projectID: projectFilter, agent: agentFilter, search: search)
    {
      selection = .status(status)
    } else {
      projectFilter = nil
      agentFilter = nil
      search = ""
      selection = .status(QueueFilter.showing(issue) ?? .active)
    }
  }
  /// Shows the list a popover row came from. Filters are kept when that report passes them, so
  /// opening a report never wipes a search or project filter it doesn't need to.
  private func applyQueueFilterRequest() {
    guard let request = model.queueFilterRequest else { return }
    model.queueFilterRequest = nil
    if let issue = selectedIssue,
      !request.includes(issue, projectID: projectFilter, agent: agentFilter, search: search)
    {
      projectFilter = nil
      agentFilter = nil
      search = ""
    }
    selection = .status(request)
  }
  private func dropHiddenSelection() {
    if hiddenSelection != nil { model.selectedIssueID = nil }
  }
  private var reportList: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        // The sidebar picks the status; this menu narrows it by project and by agent.
        HStack(spacing: 8) {
          if isReportLookup {
            Text(chrome: "Report search", comment: "Heading when the list is showing a report-number search.")
              .fontWeight(.semibold)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            filterMenu
          }
          headerButton("plus", label: Text(chrome: "New capture", comment: "Help for the button that starts a capture.")) {
            model.captureAction?()
          }
          headerButton("gearshape", label: Text(chrome: "Settings", comment: "Help for the button that opens Settings.")) {
            model.settingsAction?()
          }
        }
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            .accessibilityHidden(true)
          TextField(text: $search) {
            Text(chrome: "Search reports and feedback", comment: "Search field in the report list.")
          }.textFieldStyle(.plain)
            .accessibilityLabel(Text(chrome: "Search reports and feedback", comment: "Search field in the report list."))
            .focused($searchFocused)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: Capsule())
        .overlay(
          Capsule().strokeBorder(
            searchFocused ? Color.accentColor : Color.secondary.opacity(0.3),
            lineWidth: searchFocused ? 2 : 1)
        )
      }.padding(.top, 10).padding([.horizontal, .bottom], 20)
      Divider()
      if filtered.isEmpty {
        ContentUnavailableView {
          Label {
            if search.isEmpty {
              Text(chrome: "Nothing here yet", comment: "Empty report list title.")
            } else {
              Text(chrome: "No matches", comment: "Empty search title.")
            }
          } icon: {
            Image(systemName: "viewfinder")
          }
        } description: {
          Text(verbatim: emptyDescription)
        } actions: {
          if isFiltered && search.isEmpty {
            Button {
              projectFilter = nil
              agentFilter = nil
            } label: {
              Text(chrome: "Show everything", comment: "Clears the project and agent filters.")
            }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(filtered, selection: $model.selectedIssueID) { issue in
          IssueRow(issue: issue, project: model.project(issue.projectID)).tag(issue.id)
            .onAppear {
              // Visible reports with an open pull request open with their description ready.
              if [.prOpen, .merged].contains(issue.status), !issue.archived,
                let url = issue.prURL.flatMap(URL.init(string:))
              {
                PullRequestPreviews.shared.prefetch(
                  url, issueID: issue.id, gh: AgentDetector.ghPath(model.snapshot.settings))
              }
            }
            .contextMenu {
              Button {
                model.setArchived(issue.id, archived: !issue.archived)
              } label: {
                if issue.archived {
                  Text(chrome: "Restore report", comment: "Puts an archived report back in the queue.")
                } else {
                  Text(chrome: "Archive report", comment: "Moves a finished report out of the active queue.")
                }
              }.disabled(!issue.archived && !issue.canArchive)
            }
        }.listStyle(.inset)
      }
    }.frame(minWidth: 280, idealWidth: 330, maxHeight: .infinity, alignment: .top)
  }
  private func headerButton(_ symbol: String, label: Text, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 32, height: 24)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .frame(height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
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
    if !search.isEmpty {
      return Chrome.text(
        "Try a report number or another description.", locale: locale,
        comment: "Empty search description.")
    }
    if isFiltered {
      return Chrome.format(
        "queue.filteredEmpty",
        "No \(filter.localizedTitle(locale: locale).lowercased()) reports for \(filterSummary).",
        locale: locale,
        comment: "Empty list when a project or agent filter matches nothing. The first value is the status, the second is the filter summary.")
    }
    return Chrome.text(
      "Capture an observation to start the next fix.", locale: locale,
      comment: "Empty queue description.")
  }
  private var isFiltered: Bool { projectFilter != nil || agentFilter != nil }
  /// "All", one name, or "Project – Agent"; an "All" side is left out of a combined summary.
  private var filterSummary: String {
    let project = projectFilter.flatMap { model.project($0)?.name }
    let parts = [project, agentFilter?.title].compactMap { $0 }
    return parts.isEmpty
      ? Chrome.text("All", locale: locale, comment: "Filter meaning every project and every agent.")
      : parts.joined(separator: " – ")
  }
  private func filterCount(project: UUID? = nil, agent: AgentKind? = nil) -> Int {
    model.snapshot.issues.filter { filter.includes($0, projectID: project, agent: agent) }.count
  }
  private func filterOption(
    _ title: String, symbol: String? = nil, agent: AgentKind? = nil, count: Int, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      showingFilters = false
    } label: {
      HStack(spacing: 8) {
        Image(systemName: selected ? "checkmark" : "circle.fill")
          .opacity(selected ? 1 : 0).frame(width: 12)
        if let agent { AgentIcon(kind: agent).frame(width: 16) }
        else if let symbol { Image(systemName: symbol).frame(width: 16) }
        Text(verbatim: title)
        Spacer(minLength: 16)
        Text(count, format: .number.locale(locale)).foregroundStyle(.secondary).monospacedDigit()
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
        Text(chrome: "Projects", comment: "Filter menu heading.")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.top, 4)
        filterOption(
          Chrome.text("All projects", locale: locale, comment: "Clears the project filter."),
          symbol: "square.grid.2x2", count: filterCount(agent: agentFilter),
          selected: projectFilter == nil
        ) { projectFilter = nil }
        ForEach(model.snapshot.projects) { project in
          let count = filterCount(project: project.id, agent: agentFilter)
          if count > 0 || projectFilter == project.id {
            filterOption(project.name, symbol: project.displaySymbol, count: count, selected: projectFilter == project.id) { projectFilter = project.id }
          }
        }
        Divider().padding(.vertical, 4)
        Text(chrome: "AI agents", comment: "Filter menu heading.")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 8)
        filterOption(
          Chrome.text("All AI agents", locale: locale, comment: "Clears the agent filter."),
          symbol: "sparkles", count: filterCount(project: projectFilter), selected: agentFilter == nil
        ) { agentFilter = nil }
        ForEach(AgentKind.allCases) { agent in
          let count = filterCount(project: projectFilter, agent: agent)
          if count > 0 || agentFilter == agent {
            filterOption(agent.title, agent: agent, count: count, selected: agentFilter == agent) { agentFilter = agent }
          }
        }
      }.padding(8).frame(minWidth: 210)
    }
    .help(
      Text(
        verbatim: isFiltered
          ? Chrome.format(
            "queue.showing", "Showing \(filterSummary)", locale: locale,
            comment: "Help while a project or agent filter is active. %@ is the filter summary.")
          : Chrome.text(
            "Filter reports by project and AI agent", locale: locale,
            comment: "Help for the report filter button."))
    )
    .accessibilityLabel(
      Text(
        verbatim: Chrome.format(
          "queue.filterAccess", "Filter: \(filterSummary)", locale: locale,
          comment: "Accessibility label for the report filter. %@ is the current summary."))
    )
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Label {
                Text(verbatim: item.localizedTitle(locale: locale))
                  .fixedSize(horizontal: false, vertical: true)
                  .lineLimit(2)
              } icon: {
                Image(systemName: item.symbol)
              }
              Spacer(minLength: 8)
              // Counts follow the toolbar's filters so they match the list they open.
              Text(
                model.snapshot.issues.filter {
                  item.includes($0, projectID: projectFilter, agent: agentFilter)
                }.count,
                format: .number
              ).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            .padding(.vertical, 4).contentShape(Rectangle())
            .fontWeight(selection == .status(item) ? .bold : .regular)
          }.sidebarRow(selected: selection == .status(item))
        }
      } header: {
        sidebarHeader(Chrome.text("WORKSPACE", locale: locale, comment: "Sidebar section heading for status filters."))
      }
      Section {
        ForEach(model.snapshot.projects) { project in
          Button {
            selection = .project(project.id)
          } label: {
            Label(project.name, systemImage: project.displaySymbol)
              .fontWeight(selection == .project(project.id) ? .bold : .regular)
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.help(
            Text(chrome: "Project settings", comment: "Opens settings for this project."))
            .sidebarRow(selected: selection == .project(project.id))
        }
        Button {
          selection = .newProject
        } label: {
          Label {
            Text(chrome: "Add project…", comment: "Starts a new project from the sidebar.")
          } icon: {
            Image(systemName: "plus")
          }
          .fontWeight(selection == .newProject ? .bold : .regular)
          .foregroundStyle(selection == .newProject ? Color.primary : Color.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.sidebarRow(selected: selection == .newProject)
      } header: {
        sidebarHeader(Chrome.text("PROJECTS", locale: locale, comment: "Sidebar section heading for projects."))
      }
    }.listStyle(.sidebar).scrollContentBackground(.hidden).labelStyle(SidebarLabelStyle())
      // Sidebar rows tint icons with the system accent unless told otherwise.
      .listItemTint(.fixed(.orange)).tint(.orange)
  }
  /// Section titles in Finder's gray (secondary label), not the extra-dimmed default.
  private func sidebarHeader(_ title: String) -> some View {
    Text(verbatim: title).font(.subheadline.weight(.semibold))
      .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      .fixedSize(horizontal: false, vertical: true)
  }
  /// Finder-style selection: a rounded neutral pill behind the row, with bold text.
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

extension View {
  /// A sidebar button row: plain style, a rounded highlight and the selected trait.
  fileprivate func sidebarRow(selected: Bool) -> some View {
    buttonStyle(.plain)
      .listRowBackground(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? Color.primary.opacity(0.1) : Color.clear).padding(.horizontal, 6)
      )
      .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
