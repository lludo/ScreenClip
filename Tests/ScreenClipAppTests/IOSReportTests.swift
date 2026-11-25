import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class IOSReportTests: XCTestCase {
  private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-ios-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.settings.paused = true }
    return (model, root)
  }

  private func png() throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 30, height: 60, bitsPerComponent: 8, bytesPerRow: 120, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 30, height: 60))
    return try XCTUnwrap(PNG.encode(XCTUnwrap(context.makeImage())))
  }

  private func report(bundleID: String = "com.example.shop", note: String = "Checkout button is cut off") throws
    -> WireReport
  {
    WireReport(
      note: note, image: try png(),
      device: DeviceContext(
        deviceModel: "iPhone17,1", deviceName: "QA iPhone", osVersion: "26.1", appName: "Shop",
        bundleID: bundleID, appVersion: "2.0", build: "88", locale: "en_US", screenWidth: 402,
        screenHeight: 874, screenScale: 3, orientation: "portrait",
        screenPath: ["UITabBarController", "CheckoutViewController"], screenTitle: "Checkout"))
  }

  func testReportRoutesByBundleIDAndKeepsDeviceContext() throws {
    let (model, root) = try makeModel()
    var project = Project(name: "Shop", path: root.path)
    project.bundleIDs = ["com.example.shop"]
    try model.commit { $0.projects.append(project) }
    let incoming = try report()
    XCTAssertEqual(try model.importIOSReport(incoming), .imported)
    let issue = try XCTUnwrap(try model.store.load().issues.first)
    XCTAssertEqual(issue.projectID, project.id)
    XCTAssertEqual(issue.status, .queued)
    XCTAssertTrue(issue.isFromIOS)
    let capture = try XCTUnwrap(issue.captures.first)
    XCTAssertEqual(capture.id, incoming.id)
    XCTAssertEqual(capture.note, "Checkout button is cut off")
    XCTAssertEqual(capture.context.windowTitle, "Checkout")
    XCTAssertEqual(capture.context.testedVersion, "2.0 (88)")
    XCTAssertEqual(capture.context.device?.deviceModel, "iPhone17,1")
    XCTAssertNil(capture.originalPath)
    XCTAssertNotNil(capture.imagePath)
    let prompt = AgentPrompt.text(for: issue, project: project)
    XCTAssertTrue(prompt.contains("iOS app capture: Shop (com.example.shop) on iPhone17,1"))
    XCTAssertTrue(prompt.contains("UITabBarController > CheckoutViewController"))
  }

  func testResentReportIsADuplicateAndUnknownAppNeedsAProject() throws {
    let (model, _) = try makeModel()
    let incoming = try report(bundleID: "com.example.unknown")
    XCTAssertEqual(try model.importIOSReport(incoming), .imported)
    XCTAssertEqual(try model.importIOSReport(incoming), .duplicate)
    let issues = try model.store.load().issues
    XCTAssertEqual(issues.count, 1)
    XCTAssertEqual(issues.first?.status, .needsProject)
  }

  func testDraftSettingAndUnreadableImage() throws {
    let (model, _) = try makeModel()
    model.setIOSReportsAsDrafts(true)
    try model.importIOSReport(report())
    XCTAssertEqual(try model.store.load().issues.first?.status, .draft)
    var broken = try report()
    broken.image = Data("not a png".utf8)
    XCTAssertThrowsError(try model.importIOSReport(broken))
  }

  func testReportFilesImportOnce() throws {
    let (model, root) = try makeModel()
    let url = root.appendingPathComponent("one.\(ReportFile.pathExtension)")
    try ReportFile.write(report(), to: url)
    XCTAssertEqual(model.importIOSReportFiles([url]), 1)
    XCTAssertEqual(model.importIOSReportFiles([url]), 0)
    XCTAssertEqual(try model.store.load().issues.count, 1)
  }

  func testCapturesSavedBeforeIOSSupportStillDecode() throws {
    let old = Data(
      #"{"capturedAt":0,"appName":"Safari","bundleID":"com.apple.Safari","selection":[],"scale":2,"sessionName":"","testedVersion":"","routingReason":""}"#
        .utf8)
    let context = try JSONDecoder().decode(CaptureContext.self, from: old)
    XCTAssertNil(context.device)
  }
}
