import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class ExternalAssistantAppTests: XCTestCase {
  func testGrokStaysListedAndReportsWhetherItIsConfigured() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-grok-status-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    model.agents = [
      AgentDetection(kind: .codex, path: "/codex", version: "1", signedIn: nil, detail: "Codex 1"),
      AgentDetection(
        kind: .external, path: "", version: nil, signedIn: false,
        detail: "Not configured. Add the webhook URL and Authorization header in Settings → Connections → External assistant."
      ),
    ]
    XCTAssertEqual(model.availableAgents, [.codex, .external])
    try model.commit { $0.settings.defaultAgent = .external }
    XCTAssertEqual(model.agentStatus.text, "Grok Bot is not connected")
    XCTAssertFalse(model.agentStatus.ready)
    model.agents = [
      AgentDetection(
        kind: .external, path: "", version: "configured", signedIn: true, detail: "Detected.")
    ]
    XCTAssertEqual(model.agentStatus.text, "Grok Bot ready")
    XCTAssertTrue(model.agentStatus.ready)
    XCTAssertEqual(model.detection(.external)?.label, "Grok Bot")
  }

  func testSubmitRequiresConnectionButNoScreenshotOptIn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-grok-submit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    model.loadExternalAssistant = { .empty }
    try model.commit { $0.settings.paused = true }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try model.saveProject(Project(name: "Demo", path: repo.path, validationCommand: "true"))
    let project = try XCTUnwrap(model.snapshot.projects.first)
    XCTAssertThrowsError(
      try model.submit(
        imageData: Data([1]), originalData: nil, annotations: [], note: "Clipped",
        context: CaptureContext(), projectID: project.id, existingID: nil, draft: false,
        agent: .external)
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("Grok Bot is not connected"))
    }
    model.loadExternalAssistant = {
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
        testSucceeded: false)
    }
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Clipped",
      context: CaptureContext(), projectID: project.id, existingID: nil, draft: false,
      agent: .external)
    let issue = try XCTUnwrap(model.snapshot.issues.first)
    XCTAssertEqual(issue.agent, .external)
    XCTAssertEqual(issue.resolvedAgent.title, "Grok Bot")
    XCTAssertEqual(issue.status, .queued)
  }

  func testRestartKeepsAnUncertainGrokHandoffRetryable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-grok-restart-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var prepared: AppModel? = try AppModel(root: root)
    try XCTUnwrap(prepared).commit { state in
      var issue = Issue(
        projectID: nil, title: "Clipped",
        capture: Capture(note: "Label", imagePath: "/a.png", context: CaptureContext()),
        agent: .external)
      issue.status = .working
      issue.dispatchUncertain = true
      issue.handoffRevision = 1
      issue.handoffCommit = "abc"
      state.issues = [issue]
    }
    prepared = nil
    let reloaded = try AppModel(root: root)
    let issue = try XCTUnwrap(reloaded.snapshot.issues.first)
    XCTAssertEqual(issue.status, .failed)
    XCTAssertFalse(issue.dispatchUncertain)
    XCTAssertEqual(issue.handoffCommit, "abc")
    XCTAssertEqual(issue.handoffRevision, 1)
    XCTAssertTrue(issue.activities.contains { $0.text == ExternalAssistant.restartRetryActivity })
  }
}
