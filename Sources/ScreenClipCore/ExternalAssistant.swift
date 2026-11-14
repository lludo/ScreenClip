import Foundation

/// Grok Bot, the remote assistant. ScreenClip pushes approved screenshots to a GitHub branch,
/// then POSTs a small JSON handoff. The assistant opens the pull request.
public enum ExternalAssistant {
  public static let handoffSchema = "screenclip.external.v1"
  public static let testSchema = "screenclip.external.v1.test"
  public static let sentActivity = "Sent to external assistant"
  public static let evidenceStillPresentSummary =
    "This pull request still contains .screenclip/ files. Automatic merge is waiting until Grok Bot removes them."
  public static let canceledActivity =
    "Canceled locally. Grok Bot cannot be stopped from ScreenClip; it may still finish and open a pull request."
  public static let conversationNote = "The conversation is in Grok Bot's chat."
  public static let restartRetryActivity =
    "ScreenClip restarted while sending to Grok Bot. Retry delivers the same report and revision again."
  public static let restartWatchActivity =
    "ScreenClip restarted. Watching for Grok Bot's pull request."

  public static func slug(_ title: String, limit: Int = 40) -> String {
    let folded = title.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
      .lowercased()
    var output = ""
    var dash = false
    for character in folded {
      let asciiLetter = character.isASCII && (character.isLetter || character.isNumber)
      if asciiLetter {
        let separator = dash && !output.isEmpty ? 1 : 0
        if output.count + separator + 1 > limit { break }
        if separator == 1 { output.append("-") }
        dash = false
        output.append(character)
      } else if !output.isEmpty {
        dash = true
      }
    }
    while output.last == "-" { output.removeLast() }
    return output.isEmpty ? "report" : output
  }

  /// Unique per workspace: a follow-up after a merge gets a new workspace, so it never reuses the
  /// merged branch (still checked out in the old worktree) or rediscovers the merged PR.
  public static func branchName(reportNumber: Int, title: String, workspaceID: UUID) -> String {
    "screenclip/\(reportNumber)-\(slug(title))-\(workspaceID.uuidString.lowercased().prefix(8))"
  }

  public static func evidenceDirectory(reportNumber: Int) -> String {
    ".screenclip/\(reportNumber)"
  }

  public static func evidencePaths(reportNumber: Int, captureCount: Int) -> [String] {
    var paths = ["\(evidenceDirectory(reportNumber: reportNumber))/report.json"]
    if captureCount > 0 {
      paths += (1...captureCount).map {
        "\(evidenceDirectory(reportNumber: reportNumber))/capture-\($0).png"
      }
    }
    return paths
  }

  /// The file committed to GitHub cannot contain its own commit id. `commit` is null in that
  /// file and the webhook sends the id of the commit that contains it.
  public static func makePayload(
    issue: Issue, project: Project, repo: String, branch: String, includePageContext: Bool,
    commit: String?
  ) -> ExternalWebhookPayload {
    let number = issue.reportNumber ?? 0
    let source = issue.captures.last?.context
    var context = ExternalWebhookContext(
      appName: source?.appName ?? "", bundleID: source?.bundleID ?? "")
    if includePageContext {
      context.browserURL = source?.browserURL.flatMap { $0.isEmpty ? nil : $0 }
      context.windowTitle = source?.windowTitle.flatMap { $0.isEmpty ? nil : $0 }
    }
    return ExternalWebhookPayload(
      schema: handoffSchema, reportNumber: number, issueID: issue.id.uuidString,
      revision: issue.revision, title: issue.title, notes: issue.captures.map(\.note),
      contextNotes: (issue.contextNotes ?? []).map(\.text), context: context,
      project: ExternalWebhookProject(
        name: project.name, repo: repo, baseBranch: project.baseBranch,
        validationCommand: project.validationCommand),
      evidence: ExternalWebhookEvidence(
        branch: branch, commit: commit,
        paths: evidencePaths(reportNumber: number, captureCount: issue.captures.count)))
  }

  public static func json(_ payload: ExternalWebhookPayload, pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    if pretty { formatting.insert(.prettyPrinted) }
    encoder.outputFormatting = formatting
    return try encoder.encode(payload)
  }

  public static func testJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(ExternalTestPayload())
  }

  public static func containsScreenclipEvidence(_ paths: [String]) -> Bool {
    paths.contains { path in
      let normalized = path.replacingOccurrences(of: "\\", with: "/")
      return normalized == ".screenclip" || normalized.hasPrefix(".screenclip/")
    }
  }

  public static func body(_ body: String, marks reportNumber: Int) -> Bool {
    let marker = "ScreenClip: #\(reportNumber)"
    var rest = Substring(body)
    while let range = rest.range(of: marker) {
      let next = range.upperBound
      if next == rest.endIndex || !rest[next].isNumber { return true }
      rest = rest[next...]
    }
    return false
  }
}

public struct ExternalAssistantConfiguration: Equatable, Sendable {
  public var webhookURL: String
  public var authorization: String
  public var testSucceeded: Bool
  public init(webhookURL: String, authorization: String, testSucceeded: Bool) {
    self.webhookURL = webhookURL
    self.authorization = authorization
    self.testSucceeded = testSucceeded
  }
  public static let empty = ExternalAssistantConfiguration(
    webhookURL: "", authorization: "", testSucceeded: false)
  public var normalizedURL: String {
    webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public var normalizedAuthorization: String {
    authorization.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  /// Header values are sent verbatim, but a line break would split the HTTP header.
  public static func isSafeHeaderValue(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }
  public var authorizationIsHeaderSafe: Bool { Self.isSafeHeaderValue(normalizedAuthorization) }
  /// The assistant's panel supplies the full header value. Empty is not configured.
  /// HTTPS only, so the Authorization header and report never travel in clear text. Plain
  /// HTTP is accepted for a loopback test server.
  public var endpoint: URL? {
    guard let url = URL(string: normalizedURL), let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased(), !host.isEmpty
    else { return nil }
    let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    return scheme == "https" || (scheme == "http" && loopback) ? url : nil
  }
  public var isConfigured: Bool { endpoint != nil && authorizationIsHeaderSafe }
}

public struct ExternalWebhookContext: Equatable, Encodable {
  public var appName: String
  public var bundleID: String
  public var browserURL: String?
  public var windowTitle: String?
  public init(
    appName: String, bundleID: String, browserURL: String? = nil, windowTitle: String? = nil
  ) {
    self.appName = appName
    self.bundleID = bundleID
    self.browserURL = browserURL
    self.windowTitle = windowTitle
  }
}

public struct ExternalWebhookProject: Equatable, Encodable {
  public var name: String
  public var repo: String
  public var baseBranch: String
  public var validationCommand: String
  public init(name: String, repo: String, baseBranch: String, validationCommand: String) {
    self.name = name
    self.repo = repo
    self.baseBranch = baseBranch
    self.validationCommand = validationCommand
  }
}

public struct ExternalWebhookEvidence: Equatable, Encodable {
  public var branch: String
  public var commit: String?
  public var paths: [String]
  public init(branch: String, commit: String?, paths: [String]) {
    self.branch = branch
    self.commit = commit
    self.paths = paths
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(branch, forKey: .branch)
    if let commit {
      try container.encode(commit, forKey: .commit)
    } else {
      try container.encodeNil(forKey: .commit)
    }
    try container.encode(paths, forKey: .paths)
  }
  private enum CodingKeys: String, CodingKey { case branch, commit, paths }
}

public struct ExternalWebhookPayload: Equatable, Encodable {
  public var schema: String
  public var reportNumber: Int
  public var issueID: String
  public var revision: Int
  public var title: String
  public var notes: [String]
  /// Text-only follow-ups from Add context. Separate from capture notes so image paths stay aligned.
  public var contextNotes: [String]
  public var context: ExternalWebhookContext
  public var project: ExternalWebhookProject
  public var evidence: ExternalWebhookEvidence
  public init(
    schema: String, reportNumber: Int, issueID: String, revision: Int, title: String,
    notes: [String], contextNotes: [String] = [], context: ExternalWebhookContext,
    project: ExternalWebhookProject,
    evidence: ExternalWebhookEvidence
  ) {
    self.schema = schema
    self.reportNumber = reportNumber
    self.issueID = issueID
    self.revision = revision
    self.title = title
    self.notes = notes
    self.contextNotes = contextNotes
    self.context = context
    self.project = project
    self.evidence = evidence
  }
}

public struct ExternalTestPayload: Encodable {
  public var schema = ExternalAssistant.testSchema
  public init() {}
}

public struct GitHubRepository: Equatable, Sendable {
  public var owner: String
  public var name: String
  public var slug: String { "\(owner)/\(name)" }
  public init(owner: String, name: String) {
    self.owner = owner
    self.name = name
  }
  public static func parse(remote: String) -> GitHubRepository? {
    var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasSuffix(".git") { value.removeLast(4) }
    let path: String
    if value.hasPrefix("git@github.com:") {
      path = String(value.dropFirst("git@github.com:".count))
    } else if value.hasPrefix("ssh://git@github.com/") {
      path = String(value.dropFirst("ssh://git@github.com/".count))
    } else if value.hasPrefix("git://github.com/") {
      path = String(value.dropFirst("git://github.com/".count))
    } else if let components = URLComponents(string: value),
      let host = components.host?.lowercased(), host == "github.com" || host == "www.github.com"
    {
      path = components.path
    } else {
      return nil
    }
    let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    guard parts.count >= 2, isComponent(parts[0]), isComponent(parts[1]) else { return nil }
    return GitHubRepository(owner: parts[0], name: parts[1])
  }
  private static func isComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != "..", !value.contains("..") else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
    }
  }
}

public enum ExternalScreenshotGate {
  /// Opt-in is required for every repository. A public repository gets a more specific refusal
  /// until that per-project toggle is on.
  public static func refusal(optIn: Bool, repositoryIsPublic: Bool?) -> String? {
    guard !optIn else { return nil }
    if repositoryIsPublic == true {
      return
        "This project's GitHub repository is public. Turn on Allow sending screenshots to the external assistant in the project settings before sending captures to Grok Bot. Approved screenshots would otherwise be pushed to a public branch."
    }
    return
      "Turn on Allow sending screenshots to the external assistant in this project's settings before sending captures to Grok Bot."
  }
}

public struct ExternalAgentAvailability: Equatable {
  public var enabled: Bool
  public var hint: String?
  public init(enabled: Bool, hint: String?) {
    self.enabled = enabled
    self.hint = hint
  }
}

public enum AgentPicker {
  public static func externalAvailability(
    configured: Bool, hasProject: Bool, projectOptIn: Bool
  ) -> ExternalAgentAvailability {
    if !configured {
      return ExternalAgentAvailability(enabled: false, hint: "Not connected — Connect Grok Bot")
    }
    if !hasProject {
      return ExternalAgentAvailability(
        enabled: false, hint: "Choose a project that can share screenshots with Grok Bot.")
    }
    if !projectOptIn {
      return ExternalAgentAvailability(
        enabled: false,
        hint:
          "Turn on sharing screenshots with Grok Bot for this project. Approved annotated screenshots are pushed to a branch in the project's GitHub repo."
      )
    }
    return ExternalAgentAvailability(enabled: true, hint: nil)
  }
}

public struct ExternalHandoffState: Equatable, Sendable {
  public var revision: Int
  public var handoffRevision: Int?
  public var handoffCommit: String?
  public var uncertain: Bool
  public init(revision: Int, handoffRevision: Int?, handoffCommit: String?, uncertain: Bool) {
    self.revision = revision
    self.handoffRevision = handoffRevision
    self.handoffCommit = handoffCommit
    self.uncertain = uncertain
  }
}

public enum ExternalHandoffAction: Equatable, Sendable {
  case commitEvidence
  case postExisting(commit: String)
}

public enum ExternalHandoff {
  /// Same report number and revision reuse the evidence commit instead of writing another one.
  public static func action(_ state: ExternalHandoffState) -> ExternalHandoffAction {
    if state.handoffRevision == state.revision, let commit = state.handoffCommit, !commit.isEmpty {
      return .postExisting(commit: commit)
    }
    return .commitEvidence
  }
  /// Persisted immediately before the POST. A crash retries this same revision.
  public static func beginSend(
    _ state: ExternalHandoffState, revision: Int, commit: String
  ) -> ExternalHandoffState {
    ExternalHandoffState(
      revision: revision, handoffRevision: revision, handoffCommit: commit, uncertain: true)
  }
  public static func finishSend(
    _ state: ExternalHandoffState, succeeded: Bool
  ) -> ExternalHandoffState {
    var next = state
    next.uncertain = false
    _ = succeeded
    return next
  }
}

public enum ExternalRecovery {
  public enum Step: Equatable { case retrySend, watchForPullRequest }
  /// Watch for a pull request only when the current revision's webhook was delivered. A restart
  /// while evidence was still being prepared or pushed leaves `.working` without a send.
  public static func afterRestart(status: IssueStatus, uncertain: Bool, sentCurrentRevision: Bool)
    -> Step
  {
    if uncertain || status != .working || !sentCurrentRevision { return .retrySend }
    return .watchForPullRequest
  }
  /// True when the latest handoff step recorded for this issue is a successful send of its
  /// current revision.
  public static func sentCurrentRevision(_ issue: Issue) -> Bool {
    guard issue.handoffRevision == issue.revision else { return false }
    let last = issue.activities.last {
      $0.text == ExternalAssistant.sentActivity || $0.text.hasPrefix("Sending report revision")
        || $0.text.hasPrefix("Preparing evidence for Grok Bot")
    }
    return last?.text == ExternalAssistant.sentActivity
  }
}

public struct ExternalPullRequestCandidate: Equatable, Sendable {
  public var url: String
  public var headRefName: String
  public var body: String
  public var state: String
  public init(url: String, headRefName: String, body: String, state: String) {
    self.url = url
    self.headRefName = headRefName
    self.body = body
    self.state = state
  }
}

public enum ExternalPullRequestFinder {
  public static func match(
    reportNumber: Int, branch: String, candidates: [ExternalPullRequestCandidate]
  ) -> ExternalPullRequestCandidate? {
    let matching = candidates.filter {
      $0.headRefName == branch && $0.state.uppercased() != "CLOSED"
        && ExternalAssistant.body($0.body, marks: reportNumber)
    }
    return matching.first { $0.state.uppercased() == "OPEN" } ?? matching.first
  }
  public static func closedMatch(
    reportNumber: Int, branch: String, candidates: [ExternalPullRequestCandidate]
  ) -> ExternalPullRequestCandidate? {
    candidates.first {
      $0.headRefName == branch && $0.state.uppercased() == "CLOSED"
        && ExternalAssistant.body($0.body, marks: reportNumber)
    }
  }
}

public enum ExternalEvidenceWriter {
  /// Writes `report.json` and the approved PNGs. Callers must pass the flattened derivative,
  /// never the unredacted original.
  public static func write(worktree: String, reportNumber: Int, report: Data, images: [Data]) throws
    -> [String]
  {
    let directory = URL(fileURLWithPath: worktree, isDirectory: true).appendingPathComponent(
      ExternalAssistant.evidenceDirectory(reportNumber: reportNumber), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var paths = ["\(ExternalAssistant.evidenceDirectory(reportNumber: reportNumber))/report.json"]
    try report.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    for (offset, image) in images.enumerated() {
      let name = "capture-\(offset + 1).png"
      try image.write(to: directory.appendingPathComponent(name), options: .atomic)
      paths.append("\(ExternalAssistant.evidenceDirectory(reportNumber: reportNumber))/\(name)")
    }
    return paths
  }
}

public struct ExternalHTTPResponse: Equatable, Sendable {
  public var status: Int
  public var body: String
  public var succeeded: Bool { (200..<300).contains(status) }
  public init(status: Int, body: String) {
    self.status = status
    self.body = body
  }
}

public enum ExternalAssistantClient {
  /// Keep the credential only on a same-origin redirect (scheme, host and port). Drop it when
  /// any of them changes, including an https to http downgrade on the same host.
  public static func requestKeepingAuthorizationOnSameOrigin(
    original: URL?, redirected: URLRequest
  ) -> URLRequest {
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
    guard let original, let next = redirected.url, let host = original.host, let nextHost = next.host,
      host.caseInsensitiveCompare(nextHost) == .orderedSame,
      original.scheme?.lowercased() == next.scheme?.lowercased(), port(original) == port(next)
    else {
      var stripped = redirected
      stripped.setValue(nil, forHTTPHeaderField: "Authorization")
      return stripped
    }
    return redirected
  }

  public static func post(
    url: URL, authorization: String, body: Data, session: URLSession? = nil,
    timeout: TimeInterval = 30
  ) async throws -> ExternalHTTPResponse {
    guard ExternalAssistantConfiguration.isSafeHeaderValue(authorization) else {
      throw ScreenClipError.message(
        "The secret can't contain a line break. Connect Grok Bot again from Settings."
      )
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    request.httpBody = body
    let activeSession = session ?? ownedSession
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await activeSession.data(for: request)
    } catch {
      throw ScreenClipError.message("Could not reach Grok Bot. \(error.localizedDescription)")
    }
    guard let http = response as? HTTPURLResponse else {
      throw ScreenClipError.message("Grok Bot did not return an HTTP response.")
    }
    let text = String(decoding: data.prefix(2000), as: UTF8.self)
    return ExternalHTTPResponse(status: http.statusCode, body: text)
  }

  private static let redirectGuard = RedirectGuard()
  private static let ownedSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    return URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
  }()

  private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(
        ExternalAssistantClient.requestKeepingAuthorizationOnSameOrigin(
          original: task.originalRequest?.url, redirected: request))
    }
  }
}
