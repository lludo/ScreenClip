import XCTest

@testable import ScreenClip
@testable import ScreenClipCore

/// Resumed turns send only new evidence, validation feedback is kept apart from other errors,
/// and agent progress does not rewrite the queue on every line.
@MainActor final class PromptEfficiencyTests: XCTestCase {
  private let project = Project(name: "App", path: "/tmp/app")

  private func issue() -> Issue {
    var issue = Issue(
      projectID: project.id, title: "Label clipped",
      capture: Capture(note: "First", imagePath: "/a.png", context: CaptureContext()))
    issue.worktreePath = "/tmp/worktree"
    issue.branch = "screenclip/1"
    return issue
  }

  func testFirstTurnAndNewConversationsGetEverything() {
    var issue = issue()
    let first = AgentPrompt.turn(for: issue, project: project, threadID: "thread")
    XCTAssertTrue(first.text.contains("Resolve this ScreenClip issue"))
    XCTAssertEqual(first.captures.count, 1)
    XCTAssertTrue(first.text.contains(AppSettings.defaultPromptAddOnText))

    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "thread")
    // A relinked or replacement conversation has seen nothing.
    let other = AgentPrompt.turn(for: issue, project: project, threadID: "other-thread")
    XCTAssertTrue(other.text.contains("Resolve this ScreenClip issue"))
    XCTAssertEqual(other.captures.count, 1)
  }

  func testCurrentPromptAddOnReplacesEarlierInstructionsOnResumedTurns() {
    var issue = issue()
    var settings = AppSettings()
    settings.defaultPromptAddOn = "Include accessibility checks."
    let first = AgentPrompt.turn(for: issue, project: project, threadID: nil, settings: settings)
    XCTAssertTrue(first.text.contains("Include accessibility checks."))
    XCTAssertFalse(first.text.contains(AppSettings.defaultPromptAddOnText))
    XCTAssertTrue(first.text.contains("Do not commit, push, open a PR"))

    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "thread")
    settings.defaultPromptAddOn = "Explain the validation result."
    let resumed = AgentPrompt.turn(
      for: issue, project: project, threadID: "thread", settings: settings)
    XCTAssertTrue(resumed.text.contains("Explain the validation result."))
    XCTAssertTrue(resumed.text.contains("replaces any add-on from earlier turns"))
    XCTAssertFalse(resumed.text.contains("Include accessibility checks."))
    XCTAssertTrue(resumed.captures.isEmpty)

    settings.defaultPromptAddOn = " \n "
    let disabled = AgentPrompt.turn(
      for: issue, project: project, threadID: "thread", settings: settings)
    XCTAssertTrue(disabled.text.contains("No add-on is configured."))
    XCTAssertFalse(disabled.text.contains(AppSettings.defaultPromptAddOnText))
    XCTAssertTrue(disabled.text.contains("do not commit, push, open a PR"))
  }

  func testResumedTurnSendsOnlyNewEvidence() {
    var issue = issue()
    issue.questions = [PendingQuestion(title: "Wrap it?")]
    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "thread")
    issue.captures.append(
      Capture(note: "Second capture", imagePath: "/b.png", context: CaptureContext()))
    issue.addContext("The label is in the toolbar")
    issue.questions[0].reply = "Yes"

    let turn = AgentPrompt.turn(for: issue, project: project, threadID: "thread")
    XCTAssertEqual(turn.captures.map(\.note), ["Second capture"])
    XCTAssertTrue(turn.text.contains("Only what is new"))
    XCTAssertTrue(turn.text.contains("Capture 2"))
    XCTAssertFalse(turn.text.contains("Capture 1"))
    XCTAssertTrue(turn.text.contains("The label is in the toolbar"))
    XCTAssertTrue(turn.text.contains("User reply: Yes"))
    XCTAssertFalse(turn.text.contains("<validation_feedback>"))

    // Once that turn completes, nothing is repeated.
    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "thread")
    let next = AgentPrompt.turn(for: issue, project: project, threadID: "thread")
    XCTAssertTrue(next.captures.isEmpty)
    XCTAssertFalse(next.text.contains("<additional_context>"))
    XCTAssertFalse(next.text.contains("<user_replies>"))
  }

  func testValidationFeedbackIsSentOnceAndUnrelatedErrorsAreNot() {
    var issue = issue()
    issue.lastError = "Codex disconnected."
    XCTAssertFalse(AgentPrompt.text(for: issue, project: project).contains("Codex disconnected"))
    XCTAssertTrue(
      AgentPrompt.text(for: issue, project: project).contains("No previous validation failure"))

    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "thread")
    issue.validationFeedback = "Project validation failed:\n2 tests failed"
    let repair = AgentPrompt.turn(for: issue, project: project, threadID: "thread")
    XCTAssertTrue(repair.text.contains("2 tests failed"))
    XCTAssertTrue(repair.captures.isEmpty)

    issue.deliveredContext = AgentPrompt.delivered(issue, threadID: "thread")
    let after = AgentPrompt.turn(for: issue, project: project, threadID: "thread")
    XCTAssertFalse(after.text.contains("2 tests failed"))
  }

  func testProgressIsSavedWithinASecondOrWithTheNextStateChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-progress-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.issues = [self.issue()] }
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    func saved() throws -> [String] {
      try IssueStore(root: root, readOnly: true).load().issues.first?.activities.map(\.text) ?? []
    }

    model.updateIssueSoon(id) { $0.record("Reading the toolbar code") }
    XCTAssertEqual(model.issue(id)?.activities.last?.text, "Reading the toolbar code")
    XCTAssertFalse(try saved().contains("Reading the toolbar code"))
    try await Task.sleep(nanoseconds: 1_300_000_000)
    XCTAssertTrue(try saved().contains("Reading the toolbar code"))

    model.updateIssueSoon(id) { $0.record("Running the tests") }
    try model.updateIssue(id) { $0.record("Done", status: .needsYou) }
    XCTAssertEqual(try saved().suffix(2), ["Running the tests", "Done"])
  }
}
