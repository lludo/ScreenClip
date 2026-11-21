import Foundation

public enum IssueStatus: String, Codable, CaseIterable, Identifiable {
  case draft, needsProject, queued, working, needsYou, prOpen, merged, verified, failed, canceled
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .draft: return "Draft"
    case .needsProject: return "Needs project"
    case .queued: return "Queued"
    case .working: return "Working"
    case .needsYou: return "Needs you"
    case .prOpen: return "PR open"
    case .merged: return "Merged"
    case .verified: return "Verified"
    case .failed: return "Failed"
    case .canceled: return "Canceled"
    }
  }
  public var isActive: Bool { ![.draft, .merged, .verified, .canceled].contains(self) }
  public var needsAttention: Bool { [.needsProject, .needsYou, .failed].contains(self) }
}

/// Where a report is handled. `external` is Grok Bot, a remote assistant rather than a local CLI.
public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex, claude, external
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .external: return "Grok Bot"
    }
  }
}

/// The project owns this choice; screenshots and agent replies cannot change it.
public enum CodexApprovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case automaticReview, ask, fullAccess
  public var id: String { rawValue }
  public var approvalPolicy: String { self == .fullAccess ? "never" : "on-request" }
  public var reviewer: String { self == .automaticReview ? "auto_review" : "user" }
  public var sandbox: String { self == .fullAccess ? "danger-full-access" : "workspace-write" }
  public var sandboxPolicy: JSONValue {
    .object(["type": .string(self == .fullAccess ? "dangerFullAccess" : "workspaceWrite")])
  }
}

public struct Project: Codable, Identifiable, Equatable {
  public var id: UUID
  public var name: String
  public var path: String
  public var baseBranch: String
  public var origins: [String]
  public var bundleIDs: [String]
  public var validationCommand: String
  public var autoMerge: Bool
  /// Legacy persisted preference, retained for decoding older queues. Sharing is always enabled.
  public var allowExternalScreenshots: Bool? = nil
  public var sendsExternalScreenshots: Bool { true }
  /// nil follows the system default. An explicit provider stays when the system default changes.
  public var defaultAgent: AgentKind? = nil
  public var codexApprovalMode: CodexApprovalMode = .automaticReview
  /// SF Symbol shown next to the project name. Optional so projects saved earlier still decode.
  public var symbol: String? = nil
  public static let defaultSymbol = "folder"
  public var displaySymbol: String {
    guard let symbol, !symbol.isEmpty else { return Project.defaultSymbol }
    return symbol
  }
  public init(
    id: UUID = UUID(), name: String, path: String, baseBranch: String = "main",
    origins: [String] = [], bundleIDs: [String] = [], validationCommand: String = "",
    autoMerge: Bool = true
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.baseBranch = baseBranch
    self.origins = origins
    self.bundleIDs = bundleIDs
    self.validationCommand = validationCommand
    self.autoMerge = autoMerge
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, path, baseBranch, origins, bundleIDs, validationCommand, autoMerge
    case allowExternalScreenshots, symbol, defaultAgent, codexApprovalMode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    path = try container.decode(String.self, forKey: .path)
    baseBranch = try container.decode(String.self, forKey: .baseBranch)
    origins = try container.decode([String].self, forKey: .origins)
    bundleIDs = try container.decode([String].self, forKey: .bundleIDs)
    validationCommand = try container.decode(String.self, forKey: .validationCommand)
    autoMerge = try container.decode(Bool.self, forKey: .autoMerge)
    allowExternalScreenshots = try container.decodeIfPresent(Bool.self, forKey: .allowExternalScreenshots)
    symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
    codexApprovalMode = try container.decodeIfPresent(CodexApprovalMode.self, forKey: .codexApprovalMode)
      ?? .automaticReview
    // A missing key is an older project. Opting into Grok Bot screenshots meant that
    // project sent its work to Grok Bot, so that choice becomes an explicit default.
    // A present null is "use the system default" and must not be migrated again.
    if container.contains(.defaultAgent) {
      defaultAgent = try container.decodeIfPresent(AgentKind.self, forKey: .defaultAgent)
    } else if allowExternalScreenshots == true {
      defaultAgent = .external
    } else {
      defaultAgent = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(path, forKey: .path)
    try container.encode(baseBranch, forKey: .baseBranch)
    try container.encode(origins, forKey: .origins)
    try container.encode(bundleIDs, forKey: .bundleIDs)
    try container.encode(validationCommand, forKey: .validationCommand)
    try container.encode(autoMerge, forKey: .autoMerge)
    try container.encodeIfPresent(allowExternalScreenshots, forKey: .allowExternalScreenshots)
    try container.encodeIfPresent(symbol, forKey: .symbol)
    try container.encode(defaultAgent, forKey: .defaultAgent)
    try container.encode(codexApprovalMode, forKey: .codexApprovalMode)
  }
}

public struct CaptureContext: Codable, Equatable {
  public var capturedAt: Date
  public var appName: String
  public var bundleID: String
  public var windowTitle: String?
  public var browserURL: String?
  public var selection: [Double]
  public var scale: Double
  public var sessionName: String
  public var testedVersion: String
  public var routingReason: String
  public init(
    appName: String = "", bundleID: String = "", windowTitle: String? = nil,
    browserURL: String? = nil, selection: [Double] = [], scale: Double = 1,
    sessionName: String = "", testedVersion: String = "", routingReason: String = ""
  ) {
    capturedAt = Date()
    self.appName = appName
    self.bundleID = bundleID
    self.windowTitle = windowTitle
    self.browserURL = browserURL
    self.selection = selection
    self.scale = scale
    self.sessionName = sessionName
    self.testedVersion = testedVersion
    self.routingReason = routingReason
  }
}

public enum MarkKind: String, Codable, CaseIterable {
  case pen, arrow, rectangle, ellipse, text, redact
}
public enum MarkColor: String, Codable, CaseIterable {
  case red, orange, yellow, green, blue, white, black
}
public struct MarkPoint: Codable, Equatable {
  public var x: Double
  public var y: Double
  public init(_ x: Double, _ y: Double) {
    self.x = x
    self.y = y
  }
}
public struct Annotation: Codable, Identifiable, Equatable {
  public var id: UUID
  public var kind: MarkKind
  public var points: [MarkPoint]
  public var text: String
  // Optional style keeps captures from earlier versions readable. Width is a fraction of image width.
  public var color: MarkColor?
  public var lineWidth: Double?
  public init(
    kind: MarkKind, points: [MarkPoint], text: String = "", color: MarkColor? = nil,
    lineWidth: Double? = nil
  ) {
    id = UUID()
    self.kind = kind
    self.points = points
    self.text = text
    self.color = color
    self.lineWidth = lineWidth
  }
}
public struct Capture: Codable, Identifiable, Equatable {
  public var id: UUID
  public var note: String
  public var imagePath: String
  public var originalPath: String?
  public var annotations: [Annotation]
  public var context: CaptureContext
  public init(
    note: String, imagePath: String, originalPath: String? = nil, annotations: [Annotation] = [],
    context: CaptureContext
  ) {
    id = UUID()
    self.note = note
    self.imagePath = imagePath
    self.originalPath = originalPath
    self.annotations = annotations
    self.context = context
  }
}

public struct Activity: Codable, Identifiable, Equatable {
  public var id: UUID
  public var date: Date
  public var kind: String
  public var text: String
  public init(_ text: String, kind: String = "update") {
    id = UUID()
    date = Date()
    self.kind = kind
    self.text = text
  }
}
/// Evidence an agent conversation has already received, recorded after a turn completes.
public struct DeliveredContext: Codable, Equatable, Sendable {
  public var threadID: String
  public var captureIDs: [UUID]
  public var contextNoteIDs: [UUID]
  public var answeredQuestionIDs: [UUID]
  public var validationFeedback: String?
  public init(
    threadID: String, captureIDs: [UUID], contextNoteIDs: [UUID], answeredQuestionIDs: [UUID],
    validationFeedback: String?
  ) {
    self.threadID = threadID
    self.captureIDs = captureIDs
    self.contextNoteIDs = contextNoteIDs
    self.answeredQuestionIDs = answeredQuestionIDs
    self.validationFeedback = validationFeedback
  }
}

public struct ContextNote: Codable, Identifiable, Equatable {
  public var id: UUID
  public var date: Date
  public var text: String
  public init(_ text: String) {
    id = UUID()
    date = Date()
    self.text = text
  }
}
public struct PendingQuestion: Codable, Identifiable, Equatable {
  public var id: UUID
  public var title: String
  public var reply: String?
  public var requestID: JSONValue?
  public var questions: JSONValue?
  public var requestMethod: String?
  /// When the agent asked. Optional so questions saved by earlier versions still decode.
  public var askedAt: Date?
  public init(
    title: String, requestID: JSONValue? = nil, questions: JSONValue? = nil,
    requestMethod: String? = nil
  ) {
    id = UUID()
    askedAt = Date()
    self.title = title
    self.requestID = requestID
    self.questions = questions
    self.requestMethod = requestMethod
  }
}
public struct Issue: Codable, Identifiable, Equatable {
  public var id: UUID
  // Assigned by the store; optional so queues from earlier versions still decode.
  public internal(set) var reportNumber: Int?
  public var createdAt: Date
  public var updatedAt: Date
  public var projectID: UUID?
  public var title: String
  public var status: IssueStatus
  public var archived: Bool
  public var unread: Bool
  public var revision: Int
  public var workspaceID: UUID
  public var coveredRevision: Int
  public var captures: [Capture]
  // Optional so reports filed before text-only follow-ups still decode.
  public var contextNotes: [ContextNote]?
  public var activities: [Activity]
  public var questions: [PendingQuestion]
  public var threadID: String?
  public var turnID: String?
  /// The Codex turn whose result was last taken. Optional so queues from earlier versions decode.
  public var consumedTurnID: String?
  /// The turn that was the latest when a newer one was requested. If that request never
  /// reached Codex, Reconcile must not recover this older result for the newer evidence.
  /// A result whose validation or publication was interrupted is still recovered.
  public var supersededTurnID: String?
  public var worktreePath: String?
  public var branch: String?
  public var prURL: String?
  public var prHead: String?
  public var mergeCommit: String?
  public var lastError: String?
  public var dispatchUncertain: Bool
  public var resultSummary: String?
  public var repairAttempts: Int?
  public var checkSummary: String?
  // Optional so queues from earlier versions decode; those issues were always Codex issues.
  public var agent: AgentKind?
  /// Model chosen when filing; nil uses the agent's default from Settings.
  public var agentModel: String? = nil
  /// Reasoning effort chosen when filing; nil uses the model's default.
  public var agentEffort: String? = nil
  /// Evidence commit already pushed for this revision. A retry of the same revision reuses it.
  public var handoffRevision: Int? = nil
  public var handoffCommit: String? = nil
  /// How many times this revision was POSTed. Reset when the revision changes. Optional for old queues.
  public var handoffAttempts: Int? = nil
  /// cursor.com agent link reported by the `screenclip/grok-bot` commit status. Kept across revisions.
  public var externalAgentURL: String? = nil
  /// Revision whose evidence commit Grok Bot has acknowledged.
  public var externalAckRevision: Int? = nil
  /// Latest status description, with control characters removed and length capped.
  public var externalStatusText: String? = nil
  /// The latest validation or CI failure to hand back to the agent. Kept apart from
  /// `lastError`, which can be any error (a disconnect, a gh failure) and is only shown.
  public var validationFeedback: String? = nil
  /// What the agent's current conversation already received, so a resumed turn sends only
  /// what is new. Nil, or bound to another conversation, means the next turn sends everything.
  public var deliveredContext: DeliveredContext? = nil
  public var resolvedAgent: AgentKind { agent ?? .codex }
  public init(
    id: UUID = UUID(), projectID: UUID?, title: String, capture: Capture, draft: Bool = false,
    agent: AgentKind? = nil
  ) {
    self.id = id
    self.agent = agent
    createdAt = Date()
    updatedAt = createdAt
    self.projectID = projectID
    self.title = title
    status = draft ? .draft : (projectID == nil ? .needsProject : .queued)
    archived = false
    unread = false
    revision = 1
    workspaceID = UUID()
    coveredRevision = 0
    captures = [capture]
    contextNotes = []
    activities = [Activity(draft ? "Draft saved" : "Capture submitted")]
    questions = []
    dispatchUncertain = false
  }
  public var codexURL: URL? {
    guard resolvedAgent == .codex else { return nil }
    return threadID.flatMap { URL(string: "codex://threads/\($0)") }
  }
  /// Shell command that reopens this issue's Claude Code session interactively.
  public var claudeResumeCommand: String? {
    guard resolvedAgent == .claude, let threadID, let worktreePath else { return nil }
    func quote(_ value: String) -> String {
      "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
    return "cd \(quote(worktreePath)) && claude --resume \(quote(threadID))"
  }
  /// Shown until a pull request or a Grok Bot agent link exists.
  public var externalConversationNote: String? {
    guard resolvedAgent == .external, prURL == nil, externalAgentLink == nil else { return nil }
    return ExternalAssistant.conversationNote
  }
  /// Validated `https://cursor.com/agents/bc-<uuid>` link. Other stored values are not opened.
  public var externalAgentLink: URL? {
    guard resolvedAgent == .external, let externalAgentURL else { return nil }
    return ExternalAssistant.cursorAgentURL(externalAgentURL)
  }
  public var wantsAttention: Bool {
    status.needsAttention
      || (status == .prOpen && checkSummary == ExternalAssistant.evidenceStillPresentSummary)
  }
  public var reportReference: String? { reportNumber.map { "#\($0)" } }
  public var referencedTitle: String {
    reportReference.map { "\($0) \(title)" } ?? title
  }
  public static func parseReportReference(_ query: String) -> Int? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
      let number = Int(digits), number > 0
    else { return nil }
    return number
  }
  public func matchesSearch(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    if let number = Self.parseReportReference(trimmed) { return reportNumber == number }
    return matchesFeedback(trimmed)
  }
  public var canArchive: Bool {
    !dispatchUncertain && ![.working, .queued, .prOpen].contains(status)
      && questions.allSatisfy { $0.requestID == nil || $0.reply != nil }
  }
  /// Deleting removes local evidence, so it is refused while an agent may still use it.
  public var canDelete: Bool {
    !dispatchUncertain && ![.queued, .working, .needsYou, .prOpen].contains(status)
  }
  public func matchesFeedback(_ query: String) -> Bool {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return true }
    return title.localizedCaseInsensitiveContains(text)
      || captures.contains { $0.note.localizedCaseInsensitiveContains(text) }
      || contextNotes?.contains { $0.text.localizedCaseInsensitiveContains(text) } == true
      || resultSummary?.localizedCaseInsensitiveContains(text) == true
      || activities.contains { $0.text.localizedCaseInsensitiveContains(text) }
      || questions.contains {
        $0.title.localizedCaseInsensitiveContains(text)
          || $0.reply?.localizedCaseInsensitiveContains(text) == true
      }
  }
  public mutating func add(_ capture: Capture) {
    prepareForNewEvidence()
    captures.append(capture)
    revision += 1
    updatedAt = Date()
    archived = false
    if resolvedAgent == .external {
      // A new revision is another handoff on the same branch, including while a PR is open.
      status = projectID == nil ? .needsProject : .queued
    } else if ![.working, .needsYou].contains(status) {
      status = projectID == nil ? .needsProject : .queued
    }
    activities.append(Activity("Added capture \(captures.count)"))
  }
  public mutating func addContext(_ text: String) {
    prepareForNewEvidence()
    contextNotes = (contextNotes ?? []) + [ContextNote(text)]
    revision += 1
    archived = false
    if resolvedAgent == .external && status != .draft {
      // A new revision is another handoff on the same branch, including while a PR is open.
      status = projectID == nil ? .needsProject : .queued
    } else if ![.draft, .working, .needsYou].contains(status) {
      status = projectID == nil ? .needsProject : .queued
    }
    record("Context added")
  }
  private mutating func prepareForNewEvidence() {
    repairAttempts = 0
    if [.merged, .verified].contains(status) {
      if let prURL { activities.append(Activity("Previous fix: " + prURL)) }
      workspaceID = UUID()
      worktreePath = nil
      branch = nil
      prURL = nil
      prHead = nil
      mergeCommit = nil
      handoffCommit = nil
      handoffRevision = nil
      handoffAttempts = nil
      // The follow-up runs in a new worktree, so the agent gets the full prompt again.
      deliveredContext = nil
    }
  }
  /// Sets a failure for the agent's next turn. A resumed turn only sends feedback that differs
  /// from what the conversation last received, so the delivered copy is cleared: the same
  /// failure happening again is news, and must reach the agent again.
  public mutating func setValidationFeedback(_ feedback: String) {
    validationFeedback = feedback
    deliveredContext?.validationFeedback = nil
  }
  public mutating func record(_ text: String, status: IssueStatus? = nil, kind: String = "update") {
    if let status { self.status = status }
    activities.append(Activity(text, kind: kind))
    updatedAt = Date()
    if activities.count > 500 { activities.removeFirst(activities.count - 500) }
  }
}

public struct AppSettings: Codable, Equatable {
  public var codexPath = ""
  // Optional for compatibility with queues saved before Claude Code support.
  public var claudePath: String?
  public var claudeModel: String?
  public var defaultAgent: AgentKind?
  public var preferredAgent: AgentKind { defaultAgent ?? .codex }
  /// Missing in older queues uses the default; an explicitly empty value disables the add-on.
  public var defaultPromptAddOn: String?
  public static let defaultPromptAddOnText = """
    When preparing a pull request for a visual fix, include a clearly labeled Before / After comparison in the PR description: the original issue screenshot and a new screenshot of the fixed version after rebuilding and retesting the reported scenario. Use the same view, state, and scale where practical so the change is easy to compare at a glance. Briefly describe the retest and its result. ScreenClip publishes the report screenshots and retested images to the project repository. If either screenshot or the retest is unavailable, explain what is missing and why; do not invent evidence or claim a retest you did not perform.
    """
  public var effectivePromptAddOn: String {
    (defaultPromptAddOn ?? Self.defaultPromptAddOnText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public var ghPath = "/opt/homebrew/bin/gh"
  public var model = ""
  public var paused = false
  // Optional for compatibility with queues saved before parallel reports per project.
  public var maxParallelReports: Int?
  public static let parallelReportRange = 1...6
  /// How many reports of one project may run at once; each runs in its own worktree.
  public var parallelReportLimit: Int {
    min(
      max(maxParallelReports ?? 3, Self.parallelReportRange.lowerBound),
      Self.parallelReportRange.upperBound)
  }
  // Optional for compatibility with queues saved before this preference existed.
  public var unattendedAnswerMinutes: Int?
  /// Offered waits, in minutes, before a live Codex request is answered for an absent tester. 0 is never.
  public static let unattendedAnswerChoices = [0, 5, 10, 30, 60]
  public var unattendedAnswerDelay: Int {
    let minutes = unattendedAnswerMinutes ?? 10
    return Self.unattendedAnswerChoices.contains(minutes) ? minutes : 10
  }
  public var browserContext = false
  // Optional for compatibility with queues saved before this preference existed.
  public var hideScreenClipDuringCapture: Bool?
  public var shouldHideScreenClipDuringCapture: Bool { hideScreenClipDuringCapture ?? true }
  public var notifications = false
  /// When this queue was first opened. Optional so queues saved before the tip prompt still decode.
  public var firstLaunchedAt: Date?
  /// The automatic tip prompt stays off after Don't ask again.
  public var donationOptOut: Bool?
  /// Not now hides the automatic prompt until this instant.
  public var donationSnoozeUntil: Date?
  public var shortcutKey: UInt32 = 19  // ANSI 2
  public var shortcutModifiers: UInt32 = 768  // cmdKey | shiftKey
  public var shortcutDescription = "⌘⇧2"
  public var sessionName = ""
  public var testedVersion = ""
  /// This Grok Bot connection has posted a `screenclip/grok-bot` status. Optional so old queues decode.
  /// While it is unset, a missing status keeps the 2-hour reminder and does not warn at 15 minutes.
  public var externalStatusSeen: Bool? = nil
  public init() {}
}

public struct StoreSnapshot: Codable {
  public var version = 1
  /// The oldest reader that can open and resave this queue without losing data. A later
  /// build that adds a field or an enum case writes a higher number, and this build then
  /// refuses the queue instead of dropping what it cannot decode.
  public var minimumReaderVersion: Int?
  public static let readerVersion = 1
  public var projects: [Project] = []
  public var issues: [Issue] = []
  public var settings = AppSettings()
  // A persisted high-water mark prevents reuse after reports are deleted.
  public internal(set) var nextReportNumber: Int?
  public init() {}
  mutating func assignReportNumbers(startingAt minimum: Int = 1) {
    var next = max(
      minimum, nextReportNumber ?? 1, (issues.compactMap(\.reportNumber).max() ?? 0) + 1)
    // Migrate old reports in creation order without changing the visible queue order.
    let unnumbered = issues.indices.filter { issues[$0].reportNumber == nil }.sorted {
      if issues[$0].createdAt != issues[$1].createdAt {
        return issues[$0].createdAt < issues[$1].createdAt
      }
      return issues[$0].id.uuidString < issues[$1].id.uuidString
    }
    for index in unnumbered {
      issues[index].reportNumber = next
      next += 1
    }
    nextReportNumber = next
  }
  public var activeCount: Int { issues.filter { !$0.archived && $0.status.isActive }.count }
  public var attentionCount: Int {
    issues.filter { !$0.archived && $0.wantsAttention }.count
  }
}
