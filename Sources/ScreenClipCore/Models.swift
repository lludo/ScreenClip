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
  public init(
    id: UUID = UUID(), projectID: UUID?, title: String, capture: Capture, draft: Bool = false
  ) {
    self.id = id
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
    activities = [Activity(draft ? "Draft saved" : "Capture submitted")]
    questions = []
    dispatchUncertain = false
  }
  public var codexURL: URL? { threadID.flatMap { URL(string: "codex://threads/\($0)") } }
  public mutating func add(_ capture: Capture) {
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
    captures.append(capture)
    revision += 1
    updatedAt = Date()
    archived = false
    if ![.working, .needsYou].contains(status) {
      status = projectID == nil ? .needsProject : .queued
    }
    activities.append(Activity("Added capture \(captures.count)"))
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
  public var ghPath = "/opt/homebrew/bin/gh"
  public var model = ""
  public var paused = false
  public var browserContext = false
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
  public init() {}
  public var activeCount: Int { issues.filter { !$0.archived && $0.status.isActive }.count }
  public var attentionCount: Int {
    issues.filter { !$0.archived && $0.status.needsAttention }.count
  }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  public subscript(_ key: String) -> JSONValue {
    if case .object(let v) = self { return v[key] ?? .null }
    return .null
  }
  public var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  public var array: [JSONValue] {
    if case .array(let v) = self { return v }
    return []
  }
  public var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  public var int: Int? {
    if case .number(let v) = self { return Int(v) }
    return nil
  }
  public var object: [String: JSONValue] {
    if case .object(let v) = self { return v }
    return [:]
  }
  public static func text(_ value: String) -> JSONValue { .string(value) }
  public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
