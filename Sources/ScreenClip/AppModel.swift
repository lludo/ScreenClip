import AppKit
import Combine
import ScreenClipCore
import UserNotifications

@MainActor final class AppModel: ObservableObject {
  @Published private(set) var snapshot: StoreSnapshot
  @Published var selectedIssueID: UUID?
  @Published var banner: String?
  @Published var connection = "Not connected"
  @Published var captureBusy = false
  @Published var capturePermissionIssue = false
  /// Locally installed coding agents, refreshed at launch and from Settings.
  @Published var agents: [AgentDetection] = []
  @Published var detectingAgents = false
  let store: IssueStore
  let captureDiagnostics: CaptureDiagnostics
  let capturePermission: ScreenCapturePermission
  lazy var worker = AgentWorker(model: self)
  var captureAction: (() -> Void)?
  var queueAction: (() -> Void)?
  var settingsAction: (() -> Void)?
  var relaunchAction: (() -> Void)?
  var composerAction: ((NSImage, CaptureContext, Issue?) -> Void)?

  init(root: URL) throws {
    store = try IssueStore(root: root)
    let diagnostics = CaptureDiagnostics(root: root)
    captureDiagnostics = diagnostics
    let executable = Bundle.main.executableURL
    let originalStamp = executable.flatMap {
      try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
    }
    capturePermission = ScreenCapturePermission(
      replaced: {
        guard let executable, let originalStamp,
          let stamp = try? FileManager.default.attributesOfItem(atPath: executable.path)[
            .modificationDate] as? Date
        else { return false }
        return stamp != originalStamp
      }, log: { diagnostics.record($0, $1) })
    diagnostics.record(
      "app.launch",
      [
        "bundle": Bundle.main.bundleURL.path,
        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
          ?? "unknown",
      ])
    snapshot = try store.load()
    // Do not replay uncertain work automatically after a crash.
    for i in snapshot.issues.indices
    where snapshot.issues[i].status == .working || snapshot.issues[i].dispatchUncertain {
      snapshot.issues[i].record(
        "ScreenClip restarted. Reconcile the existing chat before continuing.", status: .needsYou)
    }
    if snapshot.settings.codexPath.isEmpty {
      snapshot.settings.codexPath = Self.defaultCodexPath()
    }
    snapshot = try store.save(snapshot)
  }
  static func defaultCodexPath() -> String { AgentDetector.defaultCodexPath() }
  func commit(_ change: (inout StoreSnapshot) throws -> Void) throws {
    var next = snapshot
    try change(&next)
    snapshot = try store.save(next)
  }
  func updateIssue(_ id: UUID, _ change: (inout Issue) -> Void) throws {
    try commit { state in
      guard let index = state.issues.firstIndex(where: { $0.id == id }) else {
        throw ScreenClipError.message("Issue no longer exists.")
      }
      change(&state.issues[index])
    }
  }
  func issue(_ id: UUID) -> Issue? { snapshot.issues.first { $0.id == id } }
  func project(_ id: UUID?) -> Project? { snapshot.projects.first { $0.id == id } }
  func perform(_ body: () throws -> Void) {
    do { try body() } catch { banner = error.localizedDescription }
  }
  /// Saves the Settings form. Processing pause is controlled elsewhere (popover, queue),
  /// so a form opened earlier never reverts it.
  func saveSettings(_ settings: AppSettings) {
    perform {
      try commit { state in
        var merged = settings
        merged.paused = state.settings.paused
        state.settings = merged
      }
    }
    NotificationCenter.default.post(name: .screenClipSettingsChanged, object: nil)
  }
  func togglePaused() {
    perform { try commit { $0.settings.paused.toggle() } }
    worker.pump()
  }
  func saveProject(_ project: Project) throws {
    guard FileManager.default.fileExists(atPath: project.path + "/.git") else {
      throw ScreenClipError.message("Choose a Git repository root containing .git.")
    }
    guard !project.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw ScreenClipError.message("Give the project a name.")
    }
    try commit { state in
      if let index = state.projects.firstIndex(where: { $0.id == project.id }) {
        state.projects[index] = project
      } else {
        state.projects.append(project)
      }
    }
  }
  func submit(
    imageData: Data, originalData: Data?, annotations: [Annotation], note: String,
    context: CaptureContext, projectID: UUID?, existingID: UUID?, draft: Bool,
    agent: AgentKind? = nil
  ) throws {
    let chosenAgent = agent ?? snapshot.settings.preferredAgent
    if draft, let existingID, let target = issue(existingID), target.status != .draft {
      throw ScreenClipError.message(
        "Drafts cannot be added to a submitted issue. Submit the capture, or choose New issue.")
    }
    let approved = try store.writeAsset(imageData)
    // A redacted original is never retained where a local coding agent could read it.
    var original: String?
    let replacedDraft = existingID.flatMap { issue($0) }.flatMap { $0.status == .draft ? $0 : nil }
    do {
      original = try originalData.map { try store.writeAsset($0, original: true) }
      let capture = Capture(
        note: note, imagePath: approved, originalPath: original, annotations: annotations,
        context: context)
      try commit { state in
        if let existingID, let index = state.issues.firstIndex(where: { $0.id == existingID }) {
          guard state.issues[index].projectID == projectID || state.issues[index].status == .draft
          else {
            throw ScreenClipError.message("Related captures must use the issue's existing project.")
          }
          if state.issues[index].status == .draft {
            state.issues[index].agent = chosenAgent
            state.issues[index].projectID = projectID
            state.issues[index].captures = [capture]
            state.issues[index].revision += 1
            state.issues[index].status =
              draft ? .draft : (projectID == nil ? .needsProject : .queued)
            state.issues[index].record(draft ? "Draft updated" : "Draft submitted")
            if !note.isEmpty { state.issues[index].title = String(note.prefix(100)) }
          } else {
            state.issues[index].add(capture)
          }
          selectedIssueID = existingID
        } else {
          let title =
            note.split(separator: "\n").first.map(String.init).flatMap {
              $0.isEmpty ? nil : String($0.prefix(100))
            } ?? (context.appName.isEmpty ? "New observation" : "Observation in " + context.appName)
          let issue = Issue(
            projectID: projectID, title: title, capture: capture, draft: draft, agent: chosenAgent)
          state.issues.append(issue)
          selectedIssueID = issue.id
        }
      }
    } catch {
      try? FileManager.default.removeItem(atPath: approved)
      if let original { try? FileManager.default.removeItem(atPath: original) }
      throw error
    }
    if let replacedDraft { try? store.deleteAssets(for: replacedDraft) }
    if !draft { worker.pump() }
  }
  func assignProject(_ issueID: UUID, projectID: UUID) {
    perform {
      guard let issue = issue(issueID), issue.threadID == nil && issue.worktreePath == nil else {
        throw ScreenClipError.message(
          "An issue with agent work cannot be moved silently. Cancel it and create a new issue in the correct project."
        )
      }
      try updateIssue(issueID) { issue in
        issue.projectID = projectID
        issue.record("Project assigned", status: .queued)
      }
    }
    worker.pump()
  }
  func addContext(_ id: UUID, text: String, followUp: Bool = false) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScreenClipError.message("Enter some context before saving.")
    }
    try updateIssue(id) {
      // A merged or verified report reopens with this note as feedback for a new fix.
      if followUp { $0.record("Tester requested a follow-up") }
      $0.addContext(trimmed)
    }
    worker.pump()
  }
  func retry(_ id: UUID) {
    perform {
      guard let issue = issue(id), !issue.dispatchUncertain else {
        throw ScreenClipError.message(
          "Dispatch was not acknowledged. Use Reconcile chat before retrying.")
      }
      try updateIssue(id) { issue in
        issue.lastError = nil
        issue.record("Queued to continue", status: issue.projectID == nil ? .needsProject : .queued)
      }
    }
    worker.pump()
  }
  func refreshAgents() async {
    detectingAgents = true
    defer { detectingAgents = false }
    agents = await AgentDetector.detectAll(snapshot.settings)
    worker.pump()
  }
  func detection(_ kind: AgentKind) -> AgentDetection? { agents.first { $0.kind == kind } }
  /// Agents offered in pickers: those found locally, plus the default so it is never hidden.
  var availableAgents: [AgentKind] {
    let installed = agents.filter(\.installed).map(\.kind)
    if agents.isEmpty { return AgentKind.allCases }
    return AgentKind.allCases.filter {
      installed.contains($0) || $0 == snapshot.settings.preferredAgent
    }
  }
  /// One status line per agent offered in pickers, default agent first, for the queue sidebar.
  var agentStatuses: [(kind: AgentKind, text: String, ready: Bool)] {
    let preferred = snapshot.settings.preferredAgent
    return ([preferred] + availableAgents.filter { $0 != preferred }).map { kind in
      let status = agentStatus(kind)
      return (kind, status.text, status.ready)
    }
  }
  /// One-line status for the default agent.
  var agentStatus: (text: String, ready: Bool) { agentStatus(snapshot.settings.preferredAgent) }
  func agentStatus(_ kind: AgentKind) -> (text: String, ready: Bool) {
    switch kind {
    case .codex: return (connection, connection == "Connected to Codex")
    case .claude:
      guard let found = detection(.claude) else { return ("Checking Claude Code…", false) }
      if !found.installed { return ("Claude Code not found", false) }
      if found.signedIn == false { return ("Sign in to Claude Code to start work", false) }
      return ("Claude Code ready", true)
    }
  }
  /// `claude auth login` needs an interactive terminal and a browser, so run it in Terminal.
  func signInToClaude() {
    perform {
      let path = AgentDetector.claudePath(snapshot.settings)
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw ScreenClipError.message("Install Claude Code or choose its executable first.")
      }
      let script = store.root.appendingPathComponent("claude-sign-in.command")
      let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
      try """
        #!/bin/zsh
        \(quoted) auth login
        echo
        echo "Return to ScreenClip and click Detect agents."
        """.write(to: script, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      NSWorkspace.shared.open(script)
    }
  }
  func copyClaudeResumeCommand(_ issue: Issue) {
    guard let command = issue.claudeResumeCommand else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    banner = "Copied. Paste in Terminal to continue this issue's Claude Code session."
  }
  func notify(_ issue: Issue, text: String) {
    guard snapshot.settings.notifications else { return }
    let content = UNMutableNotificationContent()
    content.title = issue.referencedTitle
    content.body = text
    content.userInfo = ["issueID": issue.id.uuidString]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
  func openCodex(_ issue: Issue) { if let url = issue.codexURL { NSWorkspace.shared.open(url) } }
  func markRead(_ id: UUID) { perform { try updateIssue(id) { $0.unread = false } } }
  func setArchived(_ id: UUID, archived: Bool) {
    perform {
      guard let issue = issue(id) else { throw ScreenClipError.message("Report no longer exists.") }
      guard !archived || issue.canArchive else {
        throw ScreenClipError.message("Cancel active work before archiving this report.")
      }
      guard issue.archived != archived else { return }
      try updateIssue(id) {
        $0.archived = archived
        $0.record(archived ? "Report archived; evidence retained" : "Report restored from archive")
      }
    }
  }
  func openCaptureSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
  }
  func recheckCapturePermission() async {
    if await capturePermission.recheck() {
      if capturePermissionIssue {
        banner = nil
        capturePermissionIssue = false
      }
    } else if capturePermissionIssue {
      banner = capturePermission.message
    }
  }
  func delete(_ id: UUID) {
    perform {
      guard let issue = issue(id), issue.canDelete, !worker.isActive(id) else {
        throw ScreenClipError.message(
          "Cancel or finish the active run before deleting its evidence.")
      }
      try commit { $0.issues.removeAll { $0.id == id } }
      try store.deleteAssets(for: issue)
    }
  }
}
extension Notification.Name {
  static let screenClipSettingsChanged = Notification.Name("screenClipSettingsChanged")
}
