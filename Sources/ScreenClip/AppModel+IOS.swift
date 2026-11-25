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
    let decision = ProjectRouter.infer(context, projects: snapshot.projects)
    context.routingReason = decision.reason
    let drafts = snapshot.settings.iosReportsAsDrafts == true
    try submit(
      imageData: report.image, originalData: nil, annotations: [], note: report.note,
      context: context, projectID: decision.projectID, existingID: nil, draft: drafts,
      captureID: report.id)
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
