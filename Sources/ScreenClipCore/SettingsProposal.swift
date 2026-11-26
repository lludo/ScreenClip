import Foundation

/// Project settings a coding agent proposed through ScreenClip's MCP server. The server never
/// writes the queue: it drops one JSON file per proposal in `proposals/`, and nothing changes
/// until the tester accepts it in the app.
public struct SettingsProposal: Identifiable, Equatable, Sendable {
  public enum Field: String, CaseIterable, Sendable {
    case validationCommand, baseBranch
  }
  public var id: UUID
  public var projectID: UUID
  /// Only the fields this app knows. Unknown keys from a newer server are dropped.
  public var changes: [Field: String]
  /// The agent's explanation. Untrusted text, shown as written.
  public var reason: String?
  /// The MCP client that sent it, such as "claude-code".
  public var proposer: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), projectID: UUID, changes: [Field: String], reason: String? = nil,
    proposer: String? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.projectID = projectID
    self.changes = changes
    self.reason = reason
    self.proposer = proposer
    self.createdAt = createdAt
  }

  /// The changes in a stable order for display.
  public var orderedChanges: [(field: Field, value: String)] {
    Field.allCases.compactMap { field in changes[field].map { (field, $0) } }
  }

  public func currentValue(_ field: Field, in project: Project) -> String {
    switch field {
    case .validationCommand: return project.validationCommand
    case .baseBranch: return project.baseBranch
    }
  }

  /// True when the project already has every proposed value, so there is nothing to decide.
  public func isApplied(to project: Project) -> Bool {
    changes.allSatisfy { currentValue($0.key, in: project) == $0.value }
  }

  public func applied(to project: Project) -> Project {
    var project = project
    for (field, value) in changes {
      switch field {
      case .validationCommand: project.validationCommand = value
      case .baseBranch: project.baseBranch = value
      }
    }
    return project
  }
}

public enum SettingsProposalInbox {
  /// Larger files are not proposals the server writes; they are skipped unread.
  static let maximumFileSize = 64 * 1024
  static let maximumCommand = 4000
  static let maximumReason = 2000

  public static func folder(root: URL) -> URL { root.appendingPathComponent("proposals") }

  /// Waiting proposals, oldest first. Unreadable or malformed files are skipped.
  public static func load(root: URL, fileManager: FileManager = .default) -> [SettingsProposal] {
    let folder = folder(root: root)
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return [] }
    return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
      .compactMap { url -> SettingsProposal? in
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileSize,
          let data = try? Data(contentsOf: url)
        else { return nil }
        return decode(data, fileName: url.deletingPathExtension().lastPathComponent)
      }
      .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
  }

  static func decode(_ data: Data, fileName: String) -> SettingsProposal? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let idText = object["id"] as? String, let id = UUID(uuidString: idText),
      // The file name is the ID, so removing a proposal always removes the file it came from.
      UUID(uuidString: fileName) == id,
      let projectText = object["projectID"] as? String,
      let projectID = UUID(uuidString: projectText),
      let rawChanges = object["changes"] as? [String: Any]
    else { return nil }
    var changes: [SettingsProposal.Field: String] = [:]
    for field in SettingsProposal.Field.allCases {
      guard let value = rawChanges[field.rawValue] as? String else { continue }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      // The tester approves what the card shows, so nothing in the value may be invisible
      // or reorder the text, and a branch can't read as a Git option.
      let hidden = trimmed.unicodeScalars.contains {
        // A validation command can span lines.
        if field == .validationCommand, $0 == "\n" || $0 == "\t" { return false }
        return $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
      }
      guard !trimmed.isEmpty, trimmed.count <= maximumCommand, !hidden,
        field != .baseBranch || (!trimmed.hasPrefix("-") && !trimmed.contains(" ") && trimmed.count <= 255)
      else { return nil }
      changes[field] = trimmed
    }
    guard !changes.isEmpty else { return nil }
    let reason = (object["reason"] as? String).map {
      String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumReason))
    }.flatMap { $0.isEmpty ? nil : $0 }
    let proposer = (object["proposer"] as? String).map { String($0.prefix(80)) }
      .flatMap { $0.isEmpty ? nil : $0 }
    let created = (object["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
    return SettingsProposal(
      id: id, projectID: projectID, changes: changes, reason: reason, proposer: proposer,
      createdAt: created)
  }

  public static func remove(_ id: UUID, root: URL, fileManager: FileManager = .default) {
    let folder = folder(root: root)
    // The server writes upper-case IDs; match either case so a hand-made file can be removed too.
    for name in [id.uuidString, id.uuidString.lowercased()] {
      try? fileManager.removeItem(at: folder.appendingPathComponent(name + ".json"))
    }
  }

  /// Writes a proposal the way the MCP server does. Used by tests and previews.
  public static func write(_ proposal: SettingsProposal, root: URL) throws {
    let folder = folder(root: root)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var object: [String: Any] = [
      "version": 1, "id": proposal.id.uuidString, "projectID": proposal.projectID.uuidString,
      "changes": Dictionary(uniqueKeysWithValues: proposal.changes.map { ($0.key.rawValue, $0.value) }),
      "createdAt": proposal.createdAt.timeIntervalSince1970,
    ]
    if let reason = proposal.reason { object["reason"] = reason }
    if let proposer = proposal.proposer { object["proposer"] = proposer }
    try JSONSerialization.data(withJSONObject: object)
      .write(to: folder.appendingPathComponent(proposal.id.uuidString + ".json"), options: .atomic)
  }
}
