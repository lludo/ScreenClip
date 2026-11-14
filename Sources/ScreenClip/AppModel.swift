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
  /// Reads the Grok Bot webhook from the Keychain. Tests replace this so they do not touch credentials.
  var loadExternalAssistant: () -> ExternalAssistantConfiguration = {
    ExternalAssistantKeychain.load()
  }
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
      if snapshot.issues[i].resolvedAgent == .external {
        switch ExternalRecovery.afterRestart(
          status: snapshot.issues[i].status, uncertain: snapshot.issues[i].dispatchUncertain,
          sentCurrentRevision: ExternalRecovery.sentCurrentRevision(snapshot.issues[i]))
        {
        case .retrySend:
          snapshot.issues[i].dispatchUncertain = false
          snapshot.issues[i].record(ExternalAssistant.restartRetryActivity, status: .failed)
        case .watchForPullRequest:
          snapshot.issues[i].record(ExternalAssistant.restartWatchActivity)
        }
      } else {
        snapshot.issues[i].record(
          "ScreenClip restarted. Reconcile the existing chat before continuing.", status: .needsYou)
      }
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
  func saveSettings(_ settings: AppSettings) {
    perform { try commit { $0.settings = settings } }
    NotificationCenter.default.post(name: .screenClipSettingsChanged, object: nil)
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
    if !draft, chosenAgent == .external, projectID != nil {
      let availability = AgentPicker.externalAvailability(
        configured: loadExternalAssistant().isConfigured, hasProject: true,
        projectOptIn: project(projectID)?.sendsExternalScreenshots == true)
      if let hint = availability.hint { throw ScreenClipError.message(hint) }
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
  func addContext(_ id: UUID, text: String) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScreenClipError.message("Enter some context before saving.")
    }
    try updateIssue(id) { $0.addContext(trimmed) }
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
    agents = await AgentDetector.detectAll(snapshot.settings, external: loadExternalAssistant())
    worker.pump()
  }
  func saveExternalAssistant(webhookURL: String, authorization: String) throws {
    let previous = loadExternalAssistant()
    let next = ExternalAssistantConfiguration(
      webhookURL: webhookURL, authorization: authorization, testSucceeded: false)
    let unchanged =
      previous.normalizedURL == next.normalizedURL
      && previous.normalizedAuthorization == next.normalizedAuthorization
    try ExternalAssistantKeychain.save(
      ExternalAssistantConfiguration(
        webhookURL: next.normalizedURL, authorization: next.normalizedAuthorization,
        testSucceeded: unchanged && previous.testSucceeded))
  }
  func sendExternalAssistantTest(webhookURL: String, authorization: String) async -> String {
    let configuration = ExternalAssistantConfiguration(
      webhookURL: webhookURL, authorization: authorization, testSucceeded: false)
    guard let endpoint = configuration.endpoint else {
      return "The webhook URL must be an http or https address."
    }
    guard !configuration.normalizedAuthorization.isEmpty else {
      return "Paste the Authorization header value from the Grok Bot routine panel."
    }
    guard configuration.authorizationIsHeaderSafe else {
      return
        "The Authorization header cannot contain a line break. Paste the single-line value from the Grok Bot routine panel."
    }
    do {
      let stored = ExternalAssistantConfiguration(
        webhookURL: configuration.normalizedURL,
        authorization: configuration.normalizedAuthorization, testSucceeded: false)
      try ExternalAssistantKeychain.save(stored)
      let response = try await ExternalAssistantClient.post(
        url: endpoint, authorization: stored.authorization, body: try ExternalAssistant.testJSON())
      if response.succeeded {
        try ExternalAssistantKeychain.save(
          ExternalAssistantConfiguration(
            webhookURL: stored.webhookURL, authorization: stored.authorization,
            testSucceeded: true))
        await refreshAgents()
        return "HTTP \(response.status). Grok Bot accepted the test request."
      }
      await refreshAgents()
      let snippet = response.body.trimmingCharacters(in: .whitespacesAndNewlines)
      return snippet.isEmpty
        ? "HTTP \(response.status)."
        : "HTTP \(response.status). \(snippet)"
    } catch {
      return error.localizedDescription
    }
  }
  func detection(_ kind: AgentKind) -> AgentDetection? { agents.first { $0.kind == kind } }
  /// Agents offered in pickers: those found locally, plus the default so it is never hidden.
  var availableAgents: [AgentKind] {
    let installed = agents.filter(\.installed).map(\.kind)
    if agents.isEmpty { return AgentKind.allCases }
    return AgentKind.allCases.filter {
      installed.contains($0) || $0 == snapshot.settings.preferredAgent || $0 == .external
    }
  }
  /// One-line status for the default agent, shown in the queue sidebar.
  var agentStatus: (text: String, ready: Bool) {
    switch snapshot.settings.preferredAgent {
    case .codex: return (connection, connection == "Connected to Codex")
    case .claude:
      guard let found = detection(.claude) else { return ("Checking Claude Code…", false) }
      if !found.installed { return ("Claude Code not found", false) }
      if found.signedIn == false { return ("Sign in to Claude Code to start work", false) }
      return ("Claude Code ready", true)
    case .external:
      guard let found = detection(.external) else { return ("Checking Grok Bot…", false) }
      if !found.usable { return ("Grok Bot is not configured", false) }
      return ("Grok Bot ready", true)
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
      guard let issue = issue(id), ![.working, .needsYou, .prOpen].contains(issue.status) else {
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
