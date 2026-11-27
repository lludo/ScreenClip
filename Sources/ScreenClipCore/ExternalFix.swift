import Foundation

/// A pull request merged on GitHub, as `gh pr list --state merged` returns it.
public struct MergedPullRequest: Equatable, Sendable {
  public var url: String
  public var title: String
  public var body: String
  public var headRefName: String
  public var baseRefName: String
  public var mergedAt: Date?
  public var mergeCommit: String?
  public init(
    url: String, title: String, body: String, headRefName: String, baseRefName: String,
    mergedAt: Date?, mergeCommit: String?
  ) {
    self.url = url
    self.title = title
    self.body = body
    self.headRefName = headRefName
    self.baseRefName = baseRefName
    self.mergedAt = mergedAt
    self.mergeCommit = mergeCommit
  }
  static func parse(_ value: JSONValue) -> MergedPullRequest {
    MergedPullRequest(
      url: value["url"].string ?? "", title: value["title"].string ?? "",
      body: value["body"].string ?? "", headRefName: value["headRefName"].string ?? "",
      baseRefName: value["baseRefName"].string ?? "",
      mergedAt: value["mergedAt"].string.flatMap { ISO8601DateFormatter().date(from: $0) },
      mergeCommit: value["mergeCommit"]["oid"].string)
  }
}

/// Reports fixed outside ScreenClip's own agents: another session fixes a report on its own
/// branch and merges a pull request that names it, such as
/// "Swipe the person panel away (ScreenClip #141, #143)". ScreenClip never watched that pull
/// request, so the report would otherwise stay Failed or Needs you.
public enum ExternalFix {
  /// The statuses a fix made elsewhere may close. Draft, Working, and PR open belong to the
  /// tester or to ScreenClip's own agent; Merged, Verified, and Canceled are finished.
  public static let closableStatuses: Set<IssueStatus> = [.needsYou, .failed, .queued]

  /// Whether `gh`'s error says GitHub answered and has no such pull request, as opposed to not
  /// answering at all (offline, rate limited, signed out). Only the second is worth waiting for.
  public static func saysPullRequestIsMissing(_ error: String) -> Bool {
    error.contains("Could not resolve to a PullRequest") || error.contains("no pull requests found")
  }

  public static func canClose(_ issue: Issue) -> Bool {
    closableStatuses.contains(issue.status) && !issue.archived && !issue.dispatchUncertain
      && issue.reportNumber != nil && issue.projectID != nil
  }

  /// Report numbers named as `ScreenClip #N` (also `ScreenClip report: #N`, ScreenClip's own
  /// wording, and lists such as `ScreenClip #141, #143` or `ScreenClip #141 and #143`).
  /// Only whole numbers count: `ScreenClip #1360` names report 1360, never 136.
  ///
  /// Only the exact spelling "ScreenClip" counts, and text in code spans, code blocks and quoted
  /// lines is ignored: a PR that explains the convention ("lists like `ScreenClip #141, #143`")
  /// or quotes a tester's question ("is screenclip #98 fixed?") fixes nothing.
  public static func reportNumbers(in text: String) -> Set<Int> {
    let text = prose(text)
    let pattern =
      #"\bScreenClip(?:\s+report)?:?\s+#(\d+)(?!\d)((?:\s*(?:,|&|\band\b)?\s*#\d+(?!\d))*)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(text.startIndex..., in: text)
    var numbers = Set<Int>()
    for match in expression.matches(in: text, range: whole) {
      guard let first = Range(match.range(at: 1), in: text) else { continue }
      if let number = Int(text[first]) { numbers.insert(number) }
      guard let rest = Range(match.range(at: 2), in: text) else { continue }
      for part in text[rest].split(separator: "#").dropFirst() {
        if let number = Int(part.prefix { $0.isNumber }) { numbers.insert(number) }
      }
    }
    return numbers.filter { $0 > 0 }
  }

  /// `text` without fenced code blocks, inline code spans, and quoted (`>`) lines.
  static func prose(_ text: String) -> String {
    var kept: [Substring] = []
    var fenced = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.drop { $0 == " " || $0 == "\t" }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenced.toggle()
        continue
      }
      if fenced || trimmed.hasPrefix(">") { continue }
      kept.append(line)
    }
    return kept.joined(separator: "\n").replacingOccurrences(
      of: "`[^`\n]*`", with: " ", options: .regularExpression)
  }

  /// Report IDs a ScreenClip pull request names in its `Issue ID: <uuid>` lines. A PR that has
  /// them identifies its reports exactly; its report numbers may come from another Mac.
  public static func issueIDs(in text: String) -> Set<UUID> {
    guard let expression = try? NSRegularExpression(pattern: #"(?m)^Issue ID:\s*([0-9A-Fa-f-]{36})\s*$"#)
    else { return [] }
    let whole = NSRange(text.startIndex..., in: text)
    return Set(expression.matches(in: text, range: whole).compactMap { match in
      Range(match.range(at: 1), in: text).flatMap { UUID(uuidString: String(text[$0])) }
    })
  }

  /// The pull request number when `url` is a pull request of `repo` (`owner/name`) on GitHub.
  public static func pullRequestNumber(_ url: String, repo: String) -> Int? {
    guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
      components.scheme == "https", components.host?.lowercased() == "github.com",
      components.query == nil, components.fragment == nil
    else { return nil }
    let parts = components.path.split(separator: "/").map(String.init)
    guard parts.count == 4, parts[2] == "pull",
      "\(parts[0])/\(parts[1])".caseInsensitiveCompare(repo) == .orderedSame,
      parts[3].allSatisfy(\.isNumber), let number = Int(parts[3]), number > 0
    else { return nil }
    return number
  }

  /// When the report's current evidence was filed. A pull request merged before that cannot
  /// hold a fix for it: the tester reopened the report, or added to it, after that merge.
  public static func latestEvidence(_ issue: Issue) -> Date {
    ([issue.createdAt] + issue.captures.map(\.context.capturedAt)
      + (issue.contextNotes ?? []).map(\.date)).max() ?? issue.createdAt
  }

  /// The merged pull request that fixed `issue`, if one names it: merged into `base` of
  /// `repo`, after the report's latest evidence. The oldest such merge is the fix.
  public static func fix(for issue: Issue, in pullRequests: [MergedPullRequest], repo: String, base: String)
    -> MergedPullRequest?
  {
    guard canClose(issue), let number = issue.reportNumber else { return nil }
    let evidence = latestEvidence(issue)
    return pullRequests.filter { pr in
      guard pullRequestNumber(pr.url, repo: repo) != nil, pr.baseRefName == base,
        let merged = pr.mergedAt, merged >= evidence
      else { return false }
      let ids = issueIDs(in: pr.body)
      if !ids.isEmpty { return ids.contains(issue.id) }
      return reportNumbers(in: pr.title).contains(number) || reportNumbers(in: pr.body).contains(number)
    }.min { ($0.mergedAt ?? .distantFuture) < ($1.mergedAt ?? .distantFuture) }
  }

  public static func activity(_ url: String) -> String {
    "Fixed outside ScreenClip by \(url), which is merged."
  }
}
