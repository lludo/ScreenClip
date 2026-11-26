import Foundation

/// A coding agent closing a report through ScreenClip's MCP server, usually because it finished
/// the work itself (its own PR or commit) or found the report no longer applies. The server never
/// writes the queue: it drops one JSON file per request in `closures/`, and the app applies it.
public struct AgentClosure: Identifiable, Equatable, Sendable {
  public enum Resolution: String, Sendable {
    /// The fix landed some other way. Needs a pull request or a commit as evidence.
    case done
    /// Nothing to do: a duplicate, already fixed, or not reproducible.
    case canceled
  }
  public var id: UUID
  public var issueID: UUID
  public var resolution: Resolution
  public var pullRequest: String?
  public var commit: String?
  /// The agent's explanation. Untrusted text, recorded as written.
  public var summary: String
  /// The MCP client that sent it, such as "claude-code".
  public var closer: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), issueID: UUID, resolution: Resolution, pullRequest: String? = nil,
    commit: String? = nil, summary: String, closer: String? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.issueID = issueID
    self.resolution = resolution
    self.pullRequest = pullRequest
    self.commit = commit
    self.summary = summary
    self.closer = closer
    self.createdAt = createdAt
  }

  /// The timeline entry recorded on the report.
  public var activity: String {
    let who = closer.map { "Closed by \($0)" } ?? "Closed by an agent"
    var parts = [resolution == .done ? who + " (done)" : who + " (canceled)"]
    if let pullRequest { parts.append("PR: " + pullRequest) }
    if let commit { parts.append("Commit: " + commit) }
    return parts.joined(separator: " · ") + "\n" + summary
  }
}

public enum AgentClosureInbox {
  static let maximumFileSize = 64 * 1024
  static let maximumSummary = 2000

  public static func folder(root: URL) -> URL { root.appendingPathComponent("closures") }

  /// Waiting requests, oldest first. Unreadable or malformed files are removed.
  public static func load(root: URL, fileManager: FileManager = .default) -> [AgentClosure] {
    let folder = folder(root: root)
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return [] }
    return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
      .compactMap { url -> AgentClosure? in
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileSize,
          let data = try? Data(contentsOf: url),
          let closure = decode(data, fileName: url.deletingPathExtension().lastPathComponent)
        else {
          try? fileManager.removeItem(at: url)
          return nil
        }
        return closure
      }
      .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
  }

  static func decode(_ data: Data, fileName: String) -> AgentClosure? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let idText = object["id"] as? String, let id = UUID(uuidString: idText),
      UUID(uuidString: fileName) == id,
      let issueText = object["issueID"] as? String, let issueID = UUID(uuidString: issueText),
      let resolution = (object["resolution"] as? String).flatMap(AgentClosure.Resolution.init),
      let rawSummary = object["summary"] as? String
    else { return nil }
    let summary = String(
      rawSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumSummary))
    guard !summary.isEmpty else { return nil }
    func clean(_ key: String, limit: Int) -> String? {
      guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty, value.count <= limit,
        !value.unicodeScalars.contains(where: {
          $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
            || $0 == " "
        })
      else { return nil }
      return value
    }
    let pullRequest = clean("pullRequest", limit: 300).flatMap {
      URL(string: $0)?.scheme == "https" ? $0 : nil
    }
    let commit = clean("commit", limit: 64).flatMap {
      $0.allSatisfy(\.isHexDigit) && $0.count >= 7 ? $0 : nil
    }
    // "Done" without anything that shows the fix landed is not accepted.
    if resolution == .done && pullRequest == nil && commit == nil { return nil }
    let closer = (object["closer"] as? String).map { String($0.prefix(80)) }
      .flatMap { $0.isEmpty ? nil : $0 }
    let created = (object["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
    return AgentClosure(
      id: id, issueID: issueID, resolution: resolution, pullRequest: pullRequest, commit: commit,
      summary: summary, closer: closer, createdAt: created)
  }

  public static func remove(_ id: UUID, root: URL, fileManager: FileManager = .default) {
    let folder = folder(root: root)
    for name in [id.uuidString, id.uuidString.lowercased()] {
      try? fileManager.removeItem(at: folder.appendingPathComponent(name + ".json"))
    }
  }

  /// Writes a request the way the MCP server does. Used by tests.
  public static func write(_ closure: AgentClosure, root: URL) throws {
    let folder = folder(root: root)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var object: [String: Any] = [
      "version": 1, "id": closure.id.uuidString, "issueID": closure.issueID.uuidString,
      "resolution": closure.resolution.rawValue, "summary": closure.summary,
      "createdAt": closure.createdAt.timeIntervalSince1970,
    ]
    if let pullRequest = closure.pullRequest { object["pullRequest"] = pullRequest }
    if let commit = closure.commit { object["commit"] = commit }
    if let closer = closure.closer { object["closer"] = closer }
    try JSONSerialization.data(withJSONObject: object)
      .write(to: folder.appendingPathComponent(closure.id.uuidString + ".json"), options: .atomic)
  }
}
