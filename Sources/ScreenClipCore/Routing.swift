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
    let browsers = [
      "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox",
      "company.thebrowser.Browser",
    ]
    var matches: [Project]
    if let source = context.browserURL, let url = URLComponents(string: source) {
      // The most specific website rule wins: "localhost:3000/admin" beats "localhost:3000".
      let scored = projects.compactMap { project -> (Project, Int)? in
        let best = project.origins.compactMap { matchLength(rule: $0, url: url) }.max()
        return best.map { (project, $0) }
      }
      let top = scored.map(\.1).max()
      matches = scored.filter { $0.1 == top }.map(\.0)
    } else {
      matches = projects.filter { project in
        !context.bundleID.isEmpty && !browsers.contains(context.bundleID)
          && project.bundleIDs.contains(context.bundleID)
      }
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

  /// Length of the rule's path prefix when it matches the URL, or nil.
  static func matchLength(rule: String, url: URLComponents) -> Int? {
    let value = rule.contains("://") ? rule : "http://" + rule
    guard let target = URLComponents(string: value), let host = target.host,
      host.caseInsensitiveCompare(url.host ?? "") == .orderedSame
    else { return nil }
    let targetScheme = target.scheme?.lowercased()
    let sourceScheme = url.scheme?.lowercased()
    let targetPort = target.port ?? (targetScheme == "https" ? 443 : 80)
    let sourcePort = url.port ?? (sourceScheme == "https" ? 443 : 80)
    guard targetPort == sourcePort, targetScheme == sourceScheme else { return nil }
    let prefix = target.path
    if prefix.isEmpty || prefix == "/" { return 0 }
    let matches =
      url.path == prefix || url.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    return matches ? prefix.count : nil
  }
}
