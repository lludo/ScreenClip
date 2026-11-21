import XCTest

@testable import ScreenClipCore

final class AgentModelTests: XCTestCase {
  func testCodexModelListKeepsVisibleModelsWithTheirEfforts() {
    let list: JSONValue = .object([
      "data": .array([
        .object([
          "id": .string("gpt-5.5"), "model": .string("gpt-5.5"), "displayName": .string("GPT-5.5"),
          "isDefault": .bool(true), "defaultReasoningEffort": .string("medium"),
          "supportedReasoningEfforts": .array([
            .object(["reasoningEffort": .string("low"), "description": .string("Fast")]),
            .object(["reasoningEffort": .string("medium")]),
            .object(["reasoningEffort": .string("xhigh")]),
          ]),
        ]),
        .object(["id": .string("old"), "hidden": .bool(true)]),
        .object(["id": .string("mini")]),
      ])
    ])
    let models = AgentModelCatalog.codex(fromModelList: list)
    XCTAssertEqual(models.map(\.id), ["gpt-5.5", "mini"])
    XCTAssertEqual(models[0].title, "GPT-5.5")
    XCTAssertEqual(models[0].efforts, ["low", "medium", "xhigh"])
    XCTAssertEqual(models[0].defaultEffort, "medium")
    XCTAssertTrue(models[0].isDefault)
    XCTAssertEqual(models[1].title, "mini")
    XCTAssertEqual(models[1].efforts, [])
    XCTAssertEqual(AgentModelCatalog.defaultModel(in: models, configured: "")?.id, "gpt-5.5")
    XCTAssertEqual(AgentModelCatalog.defaultModel(in: models, configured: "mini")?.id, "mini")
    XCTAssertEqual(AgentModelCatalog.defaultModel(in: models, configured: "custom")?.title, "custom")
  }

  func testStoredChoiceIsKeptOnlyWhileOffered() {
    let claude = AgentModelCatalog.claude
    XCTAssertTrue(AgentModelCatalog.reconcile(model: "opus", effort: "xhigh", in: claude) == ("opus", "xhigh"))
    XCTAssertTrue(AgentModelCatalog.reconcile(model: "haiku", effort: "high", in: claude) == ("haiku", nil))
    XCTAssertTrue(AgentModelCatalog.reconcile(model: "gone", effort: "high", in: claude) == (nil, nil))
    // A catalog that has not loaded yet does not clear the choice.
    XCTAssertTrue(AgentModelCatalog.reconcile(model: "gpt-5.5", effort: "high", in: []) == ("gpt-5.5", "high"))
  }

  func testClaudeTurnPassesEffortOnlyWhenChosen() {
    var request = ClaudeTurnRequest(
      executable: "/bin/true", cwd: "/tmp", sessionID: "s", resume: false, model: "opus",
      effort: "xhigh", prompt: "p", images: [], schema: .object([:]))
    var arguments = ClaudeCodeClient.arguments(for: request)
    XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "opus")
    XCTAssertEqual(arguments[arguments.firstIndex(of: "--effort")! + 1], "xhigh")
    request.effort = nil
    arguments = ClaudeCodeClient.arguments(for: request)
    XCTAssertFalse(arguments.contains("--effort"))
  }

  func testIssuesSavedBeforeModelChoicesDecode() throws {
    var issue = Issue(
      projectID: nil, title: "T",
      capture: Capture(note: "", imagePath: "/x.png", context: CaptureContext()), agent: .claude)
    issue.agentModel = "opus"
    issue.agentEffort = "max"
    let decoded = try JSONDecoder().decode(Issue.self, from: JSONEncoder().encode(issue))
    XCTAssertEqual(decoded.agentModel, "opus")
    XCTAssertEqual(decoded.agentEffort, "max")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(issue)) as? [String: Any])
    object.removeValue(forKey: "agentModel")
    object.removeValue(forKey: "agentEffort")
    let old = try JSONDecoder().decode(
      Issue.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(old.agentModel)
    XCTAssertNil(old.agentEffort)
  }
}
