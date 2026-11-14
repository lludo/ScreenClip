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
  var supportAction: (() -> Void)?

  init(root: URL, recoverInterruptedWork: Bool = true) throws {
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
    if recoverInterruptedWork {
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
    }
    if snapshot.settings.codexPath.isEmpty {
      snapshot.settings.codexPath = Self.defaultCodexPath()
    }
    if snapshot.settings.firstLaunchedAt == nil {
      snapshot.settings.firstLaunchedAt = Date()
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
        // The Settings form is a copy. Tip-prompt state changes outside that form.
        merged.firstLaunchedAt = state.settings.firstLaunchedAt
        merged.donationOptOut = state.settings.donationOptOut
        merged.donationSnoozeUntil = state.settings.donationSnoozeUntil
        state.settings = merged
      }
    }
    NotificationCenter.default.post(name: .screenClipSettingsChanged, object: nil)
  }
  func mergedFixCount() -> Int { DonationPromptPolicy.mergedFixCount(snapshot.issues) }
  func shouldShowDonationPrompt(at now: Date = Date()) -> Bool {
    guard DistributionChannel.offersDonations else { return false }
    return DonationPromptPolicy.shouldShow(
      at: now, firstLaunchedAt: snapshot.settings.firstLaunchedAt, mergedCount: mergedFixCount(),
      optedOut: snapshot.settings.donationOptOut == true,
      snoozeUntil: snapshot.settings.donationSnoozeUntil)
  }
  func snoozeDonationPrompt(from now: Date = Date()) {
    perform {
      try commit {
        $0.settings.donationSnoozeUntil = now.addingTimeInterval(DonationPromptPolicy.snoozeInterval)
      }
    }
  }
  func optOutOfDonationPrompt() {
    perform { try commit { $0.settings.donationOptOut = true } }
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
        // Remember the app for the project the tester chose, so its next capture routes itself.
        // Drafts are not a confirmed choice yet.
        if !draft, let projectID,
          let identifier = ProjectRouter.identifierToLearn(
            from: context, for: projectID, projects: state.projects),
          let index = state.projects.firstIndex(where: { $0.id == projectID })
        {
          state.projects[index].bundleIDs.append(identifier)
        }
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
          "This report already has agent work. Use Move to project in the report's menu to continue it under the correct project."
        )
      }
      try updateIssue(issueID) { issue in
        issue.projectID = projectID
        issue.record("Project assigned", status: .queued)
      }
    }
    worker.pump()
  }
  /// Whether a report can move to another project from its detail view.
  func canMove(_ issue: Issue) -> Bool {
    // A pull request belongs to the old repository and would no longer be tracked.
    !worker.isActive(issue.id) && !issue.dispatchUncertain && !issue.archived && issue.prURL == nil
      && [.needsProject, .queued, .needsYou, .failed, .canceled].contains(issue.status)
  }
  /// Moves a report filed under the wrong project. Before agent work starts the report is simply
  /// reassigned. Once a chat or worktree exists for the old repository, that work cannot follow
  /// it, so the report is canceled and a copy with the same captures and notes is queued under
  /// the chosen project. Returns the report that now carries the work.
  @discardableResult func moveToProject(_ issueID: UUID, projectID: UUID) throws -> UUID {
    guard let issue = issue(issueID), let target = project(projectID) else {
      throw ScreenClipError.message("Report or project no longer exists.")
    }
    guard issue.projectID != projectID else { return issueID }
    guard issue.prURL == nil else {
      throw ScreenClipError.message(
        "This report has a pull request in its current repository. Close or merge it before moving the report."
      )
    }
    guard canMove(issue) else {
      throw ScreenClipError.message("Cancel active work before moving this report to another project.")
    }
    if issue.threadID == nil && issue.worktreePath == nil {
      try updateIssue(issueID) {
        $0.projectID = projectID
        $0.lastError = nil
        $0.repairAttempts = 0
        $0.record("Moved to \(target.name)", status: $0.status == .canceled ? .canceled : .queued)
      }
      worker.pump()
      return issueID
    }
    // Copy the evidence so deleting either report's files never removes the other's.
    var copied: [String] = []
    do {
      let captures = try issue.captures.map { capture -> Capture in
        let image = try store.writeAsset(Data(contentsOf: URL(fileURLWithPath: capture.imagePath)))
        copied.append(image)
        let original = try capture.originalPath.map {
          try store.writeAsset(Data(contentsOf: URL(fileURLWithPath: $0)), original: true)
        }
        if let original { copied.append(original) }
        var context = capture.context
        context.routingReason = "Moved from another project by tester"
        return Capture(
          note: capture.note, imagePath: image, originalPath: original,
          annotations: capture.annotations, context: context)
      }
      guard let first = captures.first else {
        throw ScreenClipError.message("This report has no captures to move.")
      }
      var moved = Issue(projectID: projectID, title: issue.title, capture: first, agent: issue.agent)
      moved.captures = captures
      moved.revision = captures.count
      moved.contextNotes = issue.contextNotes
      let from = project(issue.projectID)?.name ?? "another project"
      moved.record("Moved from \(from)" + (issue.reportReference.map { " (\($0))" } ?? ""))
      try commit { state in
        state.issues.append(moved)
        if let index = state.issues.firstIndex(where: { $0.id == issueID }) {
          state.issues[index].record("Moved to \(target.name); continuing in a new report", status: .canceled)
        }
      }
      if let number = self.issue(moved.id)?.reportReference {
        try updateIssue(issueID) { $0.record("Moved to \(target.name) as \(number)") }
      }
      selectedIssueID = moved.id
      worker.pump()
      return moved.id
    } catch {
      for path in copied { try? FileManager.default.removeItem(atPath: path) }
      throw error
    }
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
  /// Fixed connection lines for localization screenshots. Does not contact Codex, Claude Code, or Grok Bot.
  func applyScreenshotAgentStatus() {
    connection = "Connected to Codex"
    agents = [
      AgentDetection(
        kind: .codex, path: "/usr/local/bin/codex", version: "0.50.0", signedIn: nil,
        detail: "Codex 0.50.0"),
      AgentDetection(
        kind: .claude, path: "/usr/local/bin/claude", version: "2.1.0", signedIn: true,
        detail: "Claude Code 2.1.0, signed in"),
      AgentDetection(
        kind: .external, path: "", version: nil, signedIn: false,
        detail:
          "Not configured. Add the webhook URL and Authorization header in Settings → Connections → External assistant."
      ),
    ]
  }
  func agentStatus(_ kind: AgentKind) -> (text: String, ready: Bool) {
    switch kind {
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
