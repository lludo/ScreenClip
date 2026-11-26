import AppKit
import SwiftUI
import XCTest
@testable import ScreenClip
@testable import ScreenClipCore

@MainActor final class PRScreenshotPublishingTests: XCTestCase {
  /// Capture a real native view in two states without accessing the user's screen or queue.
  private func screenshot(width: CGFloat) throws -> Data {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    let button = NSButton(title: "Complete purchase", target: nil, action: nil)
    button.frame = NSRect(x: 20, y: 30, width: width, height: 32)
    view.addSubview(button)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  func testRenderProjectSettingsForVisualReview() throws {
    guard let destination = ProcessInfo.processInfo.environment["SCREENCLIP_SETTINGS_SNAPSHOT"] else {
      throw XCTSkip("Set SCREENCLIP_SETTINGS_SNAPSHOT to render the synthetic project settings")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-settings-snapshot-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    let project = Project(name: "Demo storefront", path: "/tmp/demo-storefront", validationCommand: "swift test")
    try model.commit { $0.projects = [project]; $0.settings.paused = true }
    _ = NSApplication.shared
    let content = ProjectEditor(model: model, project: project)
      .environment(\.locale, Locale(identifier: "en"))
      .preferredColorScheme(.dark)
      .frame(width: 760, height: 980)
      .background(Color(white: 0.13))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 980),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(rootView: content)
    window.orderFront(nil)
    window.display()
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    let view = try XCTUnwrap(window.contentView)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: destination))
  }

  /// A broken After image is a warning, not a repair: publishing carries on without screenshots.
  func testInvalidAfterScreenshotIsAWarningNotARepair() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-missing-after-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    let project = Project(name: "Demo", path: root.path, validationCommand: "true")
    var issue = Issue(projectID: project.id, title: "Clipped", capture: Capture(
      note: "", imagePath: "/unread.png", context: CaptureContext()))
    issue.worktreePath = root.path
    issue.status = .working
    issue.coveredRevision = issue.revision
    let after = root.appendingPathComponent(PRScreenshotEvidence.directory(for: issue) + "/after")
    try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
    try Data("not a PNG".utf8).write(to: after.appendingPathComponent("1.png"))
    try model.commit { $0.projects = [project]; $0.issues = [issue]; $0.settings.paused = true }
    await model.worker.publish(issue.id, project: project, summary: "Fixed")
    let published = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(published.repairAttempts ?? 0, 0)
    XCTAssertNotEqual(published.status, .queued)
    XCTAssertNil(published.validationFeedback)
    let warning = try XCTUnwrap(published.activities.first { $0.kind == PRScreenshotEvidence.warningKind })
    XCTAssertTrue(warning.text.contains("Invalid PNG screenshot"), warning.text)
    // This folder is no Git repository, so publishing stops later, at the base update.
    XCTAssertFalse(published.lastError?.contains("Invalid PNG") ?? false)
  }

  /// Opt-in live check: uses a dedicated private fixture, real git/gh and the native worker.
  /// No LLM is invoked; a completed agent result enters the same finish/publish/merge path.
  func testLiveWorkerPublishesUpdatesAndMergesScreenshots() async throws {
    guard let repo = ProcessInfo.processInfo.environment["SCREENCLIP_SCREENSHOT_LIVE_REPO"] else {
      throw XCTSkip("Set SCREENCLIP_SCREENSHOT_LIVE_REPO to a disposable screenclip-integration-* checkout")
    }
    guard URL(fileURLWithPath: repo).lastPathComponent.hasPrefix("screenclip-integration-") else {
      return XCTFail("A dedicated fixture checkout is required")
    }
    let root = URL(fileURLWithPath: repo).deletingLastPathComponent().appendingPathComponent("screenshot-live-queue-" + UUID().uuidString)
    let model = try AppModel(root: root)
    var project = Project(name: "Screenshot publishing fixture", path: repo,
      validationCommand: "test -f fixed.txt", autoMerge: false)
    try model.saveProject(project)
    try model.commit { $0.settings.paused = true }
    let before = try screenshot(width: 80)
    let after = try screenshot(width: 240)
    XCTAssertNotEqual(before, after)
    try model.submit(imageData: before, originalData: nil, annotations: [], note: "Clipped button",
      context: CaptureContext(appName: "Synthetic native view"), projectID: project.id,
      existingID: nil, draft: false, agent: .codex)
    var issue = try XCTUnwrap(model.snapshot.issues.first)
    let workspace = try await GitWorkspace.prepare(project: project, issueID: issue.workspaceID, root: root)
    try "fixed".write(toFile: workspace.path + "/fixed.txt", atomically: true, encoding: .utf8)
    func saveAfter(_ issue: Issue, _ data: Data) throws {
      let folder = URL(fileURLWithPath: workspace.path).appendingPathComponent(PRScreenshotEvidence.directory(for: issue) + "/after")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("1.png"))
    }
    try saveAfter(issue, after)
    try model.updateIssue(issue.id) {
      $0.worktreePath = workspace.path; $0.branch = workspace.branch
      $0.coveredRevision = $0.revision; $0.status = .working
    }
    model.worker.texts[issue.id] = "{\"outcome\":\"implemented\",\"summary\":\"Rebuilt and retested the native purchase button at 240px.\",\"question\":\"\"}"
    await model.worker.finish(issue.id)
    issue = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(issue.status, .prOpen, issue.lastError ?? "")
    let url = try XCTUnwrap(issue.prURL)
    let gh = AgentDetector.ghPath(model.snapshot.settings)
    func body() async throws -> String {
      try await CommandRunner.checked(gh, ["pr", "view", url, "--json", "body", "--jq", ".body"], cwd: repo)
    }
    let firstBody = try await body()
    XCTAssertTrue(firstBody.contains("![Before 1]"))
    XCTAssertTrue(firstBody.contains("![After 1]"))
    XCTAssertFalse(firstBody.contains("Screenshots and source context remain"))
    // Images are linked at the commit that added them, which is the pull request's head.
    func evidenceCommit(_ body: String) throws -> String {
      let match = try XCTUnwrap(body.range(
        of: #"/blob/[0-9a-f]{40}/\.screenclip/"#, options: .regularExpression))
      return String(body[match].dropFirst("/blob/".count).prefix(40))
    }
    let firstEvidence = try evidenceCommit(firstBody)
    XCTAssertEqual(firstEvidence, issue.prHead)

    // A follow-up gets a fresh After image and updates the same PR description.
    try model.updateIssue(issue.id) { $0.revision += 1; $0.coveredRevision = $0.revision; $0.status = .working }
    issue = try XCTUnwrap(model.issue(issue.id))
    try saveAfter(issue, after)
    await model.worker.publish(issue.id, project: project, summary: "Retested the follow-up revision.")
    issue = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(issue.status, .prOpen, issue.lastError ?? "")
    XCTAssertEqual(issue.prURL, url)
    let latestBody = try await body()
    XCTAssertTrue(latestBody.contains("Retested the follow-up revision."))
    XCTAssertTrue(latestBody.contains("revision-\(issue.revision)/after/1.png"))
    XCTAssertFalse(latestBody.contains("/blob/\(firstEvidence)/"))
    let evidence = try evidenceCommit(latestBody)
    let head = try XCTUnwrap(issue.prHead)
    let remote = try await CommandRunner.checked(GitWorkspace.git, ["remote", "get-url", "origin"], cwd: repo)
    let slug = try XCTUnwrap(GitHubRepository.parse(remote: remote)?.slug)
    // Verify the exact bytes that GitHub hosts at the embedded immutable commit paths.
    for (relative, expected) in [("before/1.png", before), ("after/1.png", after)] {
      let path = PRScreenshotEvidence.directory(for: issue) + "/" + relative
      let content = try await CommandRunner.checked(gh,
        ["api", "repos/\(slug)/contents/\(path)?ref=\(evidence)", "--jq", ".content"], cwd: repo)
      XCTAssertEqual(Data(base64Encoded: content, options: .ignoreUnknownCharacters), expected)
    }
    func hasEvidence(_ ref: String) async throws -> Bool {
      try await CommandRunner.run(gh, ["api", "repos/\(slug)/contents/.screenclip?ref=\(ref)"], cwd: repo).status == 0
    }
    let headHasEvidence = try await hasEvidence(head)
    XCTAssertTrue(headHasEvidence, "The evidence stays on the pull request's head")
    // Publish the actual local validation result as a commit status, avoiding paid CI.
    _ = try await CommandRunner.checked(gh,
      ["api", "--method", "POST", "repos/\(slug)/statuses/\(head)",
       "-f", "state=success", "-f", "context=screenclip/local-screenshot-test",
       "-f", "description=Native project validation and screenshot byte verification passed"], cwd: repo)
    project.autoMerge = true
    try model.saveProject(project)
    try model.commit { $0.settings.paused = false }
    for _ in 0..<10 {
      await model.worker.refreshPR(issue.id)
      if model.issue(issue.id)?.status == .merged { break }
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    let merged = try XCTUnwrap(model.issue(issue.id))
    XCTAssertEqual(merged.status, .merged, merged.lastError ?? merged.checkSummary ?? "")
    guard merged.status == .merged else { return }
    let finalBody = try await body()
    XCTAssertEqual(finalBody, latestBody)
    let content = try await CommandRunner.checked(gh,
      ["api", "repos/\(slug)/contents/\(PRScreenshotEvidence.directory(for: issue))/after/1.png?ref=\(evidence)", "--jq", ".content"], cwd: repo)
    XCTAssertEqual(Data(base64Encoded: content, options: .ignoreUnknownCharacters), after)
    let mergeCommit = try XCTUnwrap(merged.mergeCommit)
    let baseHasEvidence = try await hasEvidence(mergeCommit)
    XCTAssertTrue(baseHasEvidence, "The evidence stays in the repository until the tester removes it")
    try "\(url)\n\(head)\n".write(to: root.appendingPathComponent("verified-pr.txt"), atomically: true, encoding: .utf8)
    print("LIVE SCREENSHOT PR VERIFIED: \(url)")
  }
}
