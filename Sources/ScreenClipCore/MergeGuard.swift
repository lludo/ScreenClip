import Foundation

// Evidence ScreenClip checks itself before promoting a PR to merged.

public struct PRState {
  public var url: String
  public var head: String
  public var base: String
  public var merged: Bool
  public var open: Bool
  public var mergeCommit: String?
  public var checksPassed: Bool
  public var noChecksReported: Bool
  public var checksFailed: Bool
  public var mergeable: Bool
  /// GitHub reports that the head no longer merges into the base. Nothing but integrating the
  /// base into the issue branch clears it, so ScreenClip does that instead of waiting.
  public var conflicting = false
  public var reviewSatisfied: Bool
  /// A draft is never ready to merge. Missing `isDraft` stays false so older responses still parse.
  public var draft: Bool
  public var details: String
  public static func parse(_ value: JSONValue) -> PRState {
    let checks = value["statusCheckRollup"].array
    let passing: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]
    let pending: Set<String> = [
      "PENDING", "EXPECTED", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED",
    ]
    let conclusions = checks.map {
      $0["conclusion"].string.flatMap { $0.isEmpty ? nil : $0 } ?? $0["state"].string ?? $0[
        "status"
      ].string ?? "UNKNOWN"
    }
    let failed = conclusions.contains { !passing.contains($0) && !pending.contains($0) }
    let passed = !checks.isEmpty && conclusions.allSatisfy { passing.contains($0) }
    return PRState(
      url: value["url"].string ?? "", head: value["headRefOid"].string ?? "",
      base: value["baseRefName"].string ?? "", merged: value["state"].string == "MERGED",
      open: value["state"].string == "OPEN",
      mergeCommit: value["mergeCommit"]["oid"].string, checksPassed: passed,
      noChecksReported: value["statusCheckRollup"] == .array([]), checksFailed: failed,
      mergeable: value["mergeStateStatus"].string == "CLEAN"
        && value["mergeable"].string == "MERGEABLE",
      conflicting: value["mergeable"].string == "CONFLICTING",
      reviewSatisfied: !["REVIEW_REQUIRED", "CHANGES_REQUESTED"].contains(
        value["reviewDecision"].string ?? ""),
      draft: value["isDraft"].bool == true,
      details: checks.isEmpty
        ? "Waiting for check results. Configure at least one required CI check for automatic merge."
        : (failed
          ? "One or more checks failed." : (passed ? "Checks passed." : "Checks are running.")))
  }
}

public struct ValidationReceipt: Codable {
  public var head: String
  public var command: String
  public var passed: Bool
  public var date: Date
  public var output: String
  public var fingerprint: String
  public init(
    head: String, command: String, passed: Bool, date: Date, output: String, fingerprint: String
  ) {
    self.head = head
    self.command = command
    self.passed = passed
    self.date = date
    self.output = output
    self.fingerprint = fingerprint
  }
}

public struct MergeEvidence: Equatable {
  public var expectedHead: String
  public var currentHead: String
  public var inputRevision: Int
  public var coveredRevision: Int
  public var validationPassed: Bool
  public var hasValidation: Bool
  public var checksPassed: Bool
  public var mergeable: Bool
  public var reviewSatisfied: Bool
  public var unresolvedQuestions: Bool
  /// Grok Bot deletes `.screenclip/` in its last commit. Automatic merge waits until that is gone.
  public var screenclipEvidenceCleared: Bool
  /// Draft pull requests are attached and watched, and are never merged.
  public var draft: Bool
  public init(
    expectedHead: String, currentHead: String, inputRevision: Int, coveredRevision: Int,
    validationPassed: Bool, hasValidation: Bool, checksPassed: Bool, mergeable: Bool,
    reviewSatisfied: Bool, unresolvedQuestions: Bool, screenclipEvidenceCleared: Bool = true,
    draft: Bool = false
  ) {
    self.expectedHead = expectedHead
    self.currentHead = currentHead
    self.inputRevision = inputRevision
    self.coveredRevision = coveredRevision
    self.validationPassed = validationPassed
    self.hasValidation = hasValidation
    self.checksPassed = checksPassed
    self.mergeable = mergeable
    self.reviewSatisfied = reviewSatisfied
    self.unresolvedQuestions = unresolvedQuestions
    self.screenclipEvidenceCleared = screenclipEvidenceCleared
    self.draft = draft
  }
  public var readyForValidation: Bool {
    !expectedHead.isEmpty && expectedHead == currentHead && inputRevision == coveredRevision
      && checksPassed && mergeable && reviewSatisfied
      && !unresolvedQuestions && screenclipEvidenceCleared && !draft
  }
  public var canMerge: Bool { readyForValidation && validationPassed && hasValidation }
}
