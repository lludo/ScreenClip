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

/// The local coding agent that investigates and fixes an issue.
public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex, claude
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    }
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
  public init(
    title: String, requestID: JSONValue? = nil, questions: JSONValue? = nil,
    requestMethod: String? = nil
  ) {
    id = UUID()
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
    if ![.working, .needsYou].contains(status) {
      status = projectID == nil ? .needsProject : .queued
    }
    activities.append(Activity("Added capture \(captures.count)"))
  }
  public mutating func addContext(_ text: String) {
    prepareForNewEvidence()
    contextNotes = (contextNotes ?? []) + [ContextNote(text)]
    revision += 1
    archived = false
    if ![.draft, .working, .needsYou].contains(status) {
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
    }
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
  public var ghPath = "/opt/homebrew/bin/gh"
  public var model = ""
  public var paused = false
  public var browserContext = false
  // Optional for compatibility with queues saved before this preference existed.
  public var hideScreenClipDuringCapture: Bool?
  public var shouldHideScreenClipDuringCapture: Bool { hideScreenClipDuringCapture ?? true }
  public var notifications = false
  public var shortcutKey: UInt32 = 19  // ANSI 2
  public var shortcutModifiers: UInt32 = 768  // cmdKey | shiftKey
  public var shortcutDescription = "⌘⇧2"
  public var sessionName = ""
  public var testedVersion = ""
  public init() {}
}

public struct StoreSnapshot: Codable {
  public var version = 1
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
    issues.filter { !$0.archived && $0.status.needsAttention }.count
  }
}
