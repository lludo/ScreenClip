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
  static let browsers: Set<String> = [
    "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
    "com.google.Chrome.canary", "com.microsoft.edgemac", "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition", "company.thebrowser.Browser", "company.thebrowser.dia",
    "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
  ]
  /// Apps shared across projects. Captures from them are never learned as a project's app,
  /// so one pick cannot pin every later Simulator or Xcode capture to that project.
  static let sharedTools: Set<String> = [
    "com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.apple.Terminal",
    "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.apple.finder",
    "com.apple.Preview", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    "com.mirageteam.screenclip", "com.screenclip.app",
  ]
  static func isAppCapture(_ context: CaptureContext) -> Bool {
    !context.bundleID.isEmpty && !browsers.contains(context.bundleID)
  }
  public static func infer(_ context: CaptureContext, projects: [Project]) -> RoutingDecision {
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
      matches = projects.filter { isAppCapture(context) && $0.bundleIDs.contains(context.bundleID) }
    }
    if matches.count == 1 {
      return RoutingDecision(
        projectID: matches[0].id,
        reason: context.browserURL == nil ? "Matched app identifier" : "Matched website rule")
    }
    if matches.isEmpty, context.browserURL == nil, let named = matchByAppName(context, projects) {
      return RoutingDecision(projectID: named.id, reason: "Matched app name")
    }
    return RoutingDecision(
      projectID: nil,
      reason: matches.isEmpty
        ? "No matching project rule" : "Multiple projects match; choose a project")
  }

  /// Projects added without app identifiers still route when exactly one project's name or
  /// repository folder matches the captured app's name, unless another project claims the app.
  static func matchByAppName(_ context: CaptureContext, _ projects: [Project]) -> Project? {
    guard isAppCapture(context), !projects.contains(where: { $0.bundleIDs.contains(context.bundleID) })
    else { return nil }
    let app = normalized(context.appName)
    guard !app.isEmpty else { return nil }
    let named = projects.filter {
      normalized($0.name) == app
        || normalized(URL(fileURLWithPath: $0.path).lastPathComponent) == app
    }
    return named.count == 1 ? named[0] : nil
  }
  /// The app identifier to remember for a project the tester picked, so the next capture of that
  /// app routes automatically. Nil when no app was captured or another project already claims it.
  public static func identifierToLearn(
    from context: CaptureContext, for projectID: UUID, projects: [Project]
  ) -> String? {
    guard isAppCapture(context), !sharedTools.contains(context.bundleID),
      context.bundleID != Bundle.main.bundleIdentifier,
      projects.contains(where: { $0.id == projectID }),
      !projects.contains(where: { $0.bundleIDs.contains(context.bundleID) })
    else { return nil }
    return context.bundleID
  }
  private static func normalized(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
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
