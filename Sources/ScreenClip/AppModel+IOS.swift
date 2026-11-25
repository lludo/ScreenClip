import Foundation
import ScreenClipCore

/// Reports from iOS apps that embed ScreenClipKit, over the local network or from a
/// `.screenclipreport` file.
extension AppModel {
  /// Builds the receiver once and connects it to the queue. Not started until asked.
  func makeIOSReceiver() -> IOSReceiver {
    let receiver = IOSReceiver()
    receiver.importReport = { [weak self] report in
      guard let self else { throw ScreenClipError.message("ScreenClip is closing.") }
      return try self.importIOSReport(report)
    }
    return receiver
  }

  func startIOSServerIfEnabled() {
    if snapshot.settings.iosServerEnabled == true { iosReceiver.start() }
  }

  func setIOSServer(enabled: Bool) {
    var settings = snapshot.settings
    settings.iosServerEnabled = enabled
    saveSettings(settings)
    if enabled { iosReceiver.start() } else { iosReceiver.stop() }
  }

  func setIOSReportsAsDrafts(_ drafts: Bool) {
    var settings = snapshot.settings
    settings.iosReportsAsDrafts = drafts
    saveSettings(settings)
  }

  /// The capture context an iOS report is stored with. Routing uses the app's bundle ID, the
  /// same rule as Mac apps, so a project learns its iOS app the first time the tester picks it.
  static func captureContext(for report: WireReport, sessionName: String) -> CaptureContext {
    let device = report.device
    var context = CaptureContext(
      appName: device.appName, bundleID: device.bundleID, windowTitle: device.screenName,
      browserURL: nil,
      selection: [0, 0, device.screenWidth, device.screenHeight], scale: device.screenScale,
      sessionName: sessionName, testedVersion: device.testedVersion, device: device)
    context.capturedAt = report.createdAt
    return context
  }

  /// Saves one iOS report into the queue. A report already imported (same id) is a duplicate,
  /// so a device that resends after a lost acknowledgment never creates a second report.
  @discardableResult func importIOSReport(_ report: WireReport) throws -> IOSReceiver.ImportResult {
    if snapshot.issues.contains(where: { $0.captures.contains { $0.id == report.id } }) {
      return .duplicate
    }
    if let image = report.image, PNG.decode(image) == nil {
      throw ScreenClipError.message("The screenshot in this report could not be read.")
    }
    var context = Self.captureContext(for: report, sessionName: snapshot.settings.sessionName)
    let decision = Self.route(context, projects: snapshot.projects, scan: scanBundleIDs)
    context.routingReason = decision.reason
    let drafts = snapshot.settings.iosReportsAsDrafts == true
    let diagnostics = try saveDiagnostics(report.diagnostics)
    do {
      try submit(
        imageData: report.image, originalData: nil, annotations: [], note: report.note,
        context: context, projectID: decision.projectID, existingID: nil, draft: drafts,
        captureID: report.id, diagnostics: diagnostics)
    } catch {
      if let folder = diagnostics?.folder { try? FileManager.default.removeItem(atPath: folder) }
      throw error
    }
    if let issue = snapshot.issues.first(where: { $0.captures.contains { $0.id == report.id } }) {
      notify(
        issue,
        text: Chrome.format(
          "ios.notification.received",
          "New report from \(report.device.deviceName)",
          comment: "Notification body when an iOS report arrives. %@ is the device name."))
    }
    return .imported
  }

  static let sourceMatchReason = "Matched app identifier in project source"

  /// Routes like a Mac capture, with one more step: when no project lists the iOS app's bundle
  /// ID, the projects' source is searched for it. A source match beats a match by app name.
  static func route(
    _ context: CaptureContext, projects: [Project],
    scan: (String) -> [BundleIDScanner.Declaration] = BundleIDScanner.cachedScan
  ) -> RoutingDecision {
    let decision = ProjectRouter.infer(context, projects: projects)
    let listed = projects.contains { $0.bundleIDs.contains(context.bundleID) }
    guard !listed, decision.projectID == nil || decision.reason == "Matched app name" else { return decision }
    let declaring = BundleIDScanner.projects(declaring: context.bundleID, in: projects, scan: scan)
    guard declaring.count == 1 else { return decision }
    return RoutingDecision(projectID: declaring[0].id, reason: sourceMatchReason)
  }

  /// Stores a report's optional diagnostic files. Only plain `.txt` and `.json` names are kept,
  /// within the size limit, and token-like strings in text files are hidden.
  func saveDiagnostics(_ files: [DiagnosticFile]?) throws -> ReportDiagnostics? {
    var seen = Set<String>()
    var total = 0
    var accepted: [DiagnosticFile] = []
    for var file in files ?? [] where file.hasSafeName && seen.insert(file.name).inserted {
      if file.name.hasSuffix(".txt") {
        file.data = Data(GitHubService.redactTokens(String(decoding: file.data, as: UTF8.self)).utf8)
      }
      guard total + file.data.count <= DiagnosticFile.maximumTotalBytes else { continue }
      total += file.data.count
      file.summary = String(file.summary.prefix(200))
      accepted.append(file)
    }
    guard !accepted.isEmpty else { return nil }
    let folder = try store.writeDiagnostics(accepted.map { ($0.name, $0.data) })
    return ReportDiagnostics(
      folder: folder,
      files: accepted.map { ReportDiagnostics.Entry(name: $0.name, summary: $0.summary, bytes: $0.data.count) })
  }

  /// Imports `.screenclipreport` files exported or AirDropped from a device.
  /// Returns how many were new.
  @discardableResult func importIOSReportFiles(_ urls: [URL]) -> Int {
    var imported = 0
    var failure: String?
    for url in urls where url.pathExtension == ReportFile.pathExtension {
      do {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if try importIOSReport(ReportFile.read(from: url)) == .imported { imported += 1 }
      } catch {
        failure = error.localizedDescription
      }
    }
    if let failure { banner = failure }
    return imported
  }
}
