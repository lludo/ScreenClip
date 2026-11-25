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

  func testDiagnosticsAreStoredRedactedAndOfferedNotAttached() throws {
    let (model, root) = try makeModel()
    var incoming = try report()
    let token = String(repeating: "a1B2", count: 12)
    incoming.diagnostics = [
      DiagnosticFile(name: "logs.txt", summary: "3 app log lines", data: Data("ok\nauth \(token)\nend".utf8)),
      DiagnosticFile(name: "view-tree.json", summary: "views", data: Data("{}".utf8)),
      DiagnosticFile(name: "../../escape.txt", summary: "nope", data: Data("x".utf8)),
      DiagnosticFile(name: "logs.txt", summary: "duplicate", data: Data("y".utf8)),
    ]
    try model.importIOSReport(incoming)
    let issue = try XCTUnwrap(try model.store.load().issues.first)
    let diagnostics = try XCTUnwrap(issue.captures.first?.diagnostics)
    XCTAssertEqual(diagnostics.files.map(\.name), ["logs.txt", "view-tree.json"])
    XCTAssertTrue(diagnostics.folder.hasPrefix(root.appendingPathComponent("diagnostics").path))
    let logs = try String(contentsOfFile: diagnostics.folder + "/logs.txt", encoding: .utf8)
    XCTAssertFalse(logs.contains(token))
    XCTAssertTrue(logs.contains("auth …"))
    let prompt = AgentPrompt.text(for: issue, project: Project(name: "Shop", path: root.path))
    XCTAssertTrue(prompt.contains("Optional diagnostics from the device, not included here"))
    XCTAssertTrue(prompt.contains(diagnostics.folder))
    XCTAssertTrue(prompt.contains("logs.txt (3 app log lines)"))
    XCTAssertFalse(prompt.contains(token))
    try model.store.deleteAssets(for: issue)
    XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostics.folder))
  }

  func testUnknownBundleIDRoutesToTheProjectWhoseSourceDeclaresIt() throws {
    let (model, root) = try makeModel()
    // "Shop" matches the app name, but the source of "Storefront" declares the bundle ID.
    let named = Project(name: "Shop", path: root.appendingPathComponent("shop").path)
    let declaring = Project(name: "Storefront", path: root.appendingPathComponent("store").path)
    try model.commit { $0.projects += [named, declaring] }
    model.scanBundleIDs = { path in
      path == declaring.path ? [.init(identifier: "com.example.shop", source: "Store.xcodeproj/project.pbxproj")] : []
    }
    try model.importIOSReport(report())
    let issue = try XCTUnwrap(try model.store.load().issues.first)
    XCTAssertEqual(issue.projectID, declaring.id)
    XCTAssertEqual(issue.captures.first?.context.routingReason, AppModel.sourceMatchReason)
    // The identifier is learned, so the next report matches without scanning.
    XCTAssertEqual(model.project(declaring.id)?.bundleIDs, ["com.example.shop"])
    model.scanBundleIDs = { _ in XCTFail("should not scan"); return [] }
    try model.importIOSReport(report(note: "Second"))
    XCTAssertEqual(try model.store.load().issues.filter { $0.projectID == declaring.id }.count, 2)
  }
}
