import Foundation

public struct RoutingDecision: Equatable {
  public let projectID: UUID?
  public let reason: String
  public init(projectID: UUID?, reason: String) {
    self.projectID = projectID
    self.reason = reason
  }
}
public enum ProjectRouter {
  public static func infer(_ context: CaptureContext, projects: [Project]) -> RoutingDecision {
    let matches = projects.filter { project in
      if let source = context.browserURL, let url = URLComponents(string: source) {
        return project.origins.contains { rule in
          let value = rule.contains("://") ? rule : "http://" + rule
          guard let target = URLComponents(string: value), let host = target.host,
            host.caseInsensitiveCompare(url.host ?? "") == .orderedSame
          else { return false }
          let targetPort = target.port ?? (target.scheme == "https" ? 443 : 80)
          let sourcePort = url.port ?? (url.scheme == "https" ? 443 : 80)
          guard targetPort == sourcePort, target.scheme == url.scheme else { return false }
          let prefix = target.path
          return prefix.isEmpty || prefix == "/" || url.path == prefix
            || url.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }
      }
      let browsers = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox",
        "company.thebrowser.Browser",
      ]
      return !context.bundleID.isEmpty && !browsers.contains(context.bundleID)
        && project.bundleIDs.contains(context.bundleID)
    }
    if matches.count == 1 {
      return RoutingDecision(
        projectID: matches[0].id,
        reason: context.browserURL == nil ? "Matched app identifier" : "Matched website rule")
    }
    return RoutingDecision(
      projectID: nil,
      reason: matches.isEmpty
        ? "No matching project rule" : "Multiple projects match; choose a project")
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
  public init(
    expectedHead: String, currentHead: String, inputRevision: Int, coveredRevision: Int,
    validationPassed: Bool, hasValidation: Bool, checksPassed: Bool, mergeable: Bool,
    reviewSatisfied: Bool, unresolvedQuestions: Bool, screenclipEvidenceCleared: Bool = true
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
  }
  public var canMerge: Bool {
    !expectedHead.isEmpty && expectedHead == currentHead && inputRevision == coveredRevision
      && validationPassed && hasValidation && checksPassed && mergeable && reviewSatisfied
      && !unresolvedQuestions && screenclipEvidenceCleared
  }
}
