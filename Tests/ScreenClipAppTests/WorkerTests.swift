import AppKit
import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class WorkerTests: XCTestCase {
  func testNativeWorkerGroupsEvidenceAndContinuesQuestionInSameChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-worker-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await CommandRunner.checked("/usr/bin/git", ["init", "-b", "main"], cwd: repo.path)
    try Data("original".utf8).write(to: repo.appendingPathComponent("source.txt"))
    _ = try await CommandRunner.checked("/usr/bin/git", ["add", "source.txt"], cwd: repo.path)
    _ = try await CommandRunner.checked(
      "/usr/bin/git",
      [
        "-c", "user.name=ScreenClip", "-c", "user.email=test@example.invalid", "commit", "-m",
        "initial",
      ], cwd: repo.path)
    let script = root.appendingPathComponent("fake-codex")
    let source = """
      #!/usr/bin/python3
      import sys,json
      def send(value): print(json.dumps(value),flush=True)
      for line in sys.stdin:
          m=json.loads(line); method=m.get('method')
          if 'id' not in m: continue
          result={}
          if method in ['thread/start','thread/resume']: result={'thread':{'id':'test-thread','status':{'type':'idle'}}}
          if method=='turn/start': result={'turn':{'id':'turn-1'}}
          send({'id':m['id'],'result':result})
          if method=='turn/start':
              send({'method':'item/completed','params':{'threadId':'test-thread','item':{'type':'agentMessage','phase':'final_answer','text':json.dumps({'outcome':'question','summary':'Need context','question':'Should this label wrap?'})}}})
              send({'method':'turn/completed','params':{'threadId':'test-thread','turn':{'id':'turn-1','status':'completed'}}})
      """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let model = try AppModel(root: root.appendingPathComponent("queue"))
    let project = Project(name: "Test", path: repo.path)
    try model.saveProject(project)
    var settings = model.snapshot.settings
    settings.codexPath = script.path
    settings.paused = false
    model.saveSettings(settings)
    let context = CaptureContext(appName: "Test")
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "First capture",
      context: context, projectID: project.id, existingID: nil, draft: false)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    try await wait { model.issue(id)?.status == .needsYou }
    let issue = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(issue.threadID, "test-thread")
    XCTAssertEqual(issue.questions.count, 1)
    try model.submit(
      imageData: Data([2]), originalData: nil, annotations: [], note: "More detail",
      context: context, projectID: project.id, existingID: id, draft: false)
    await model.worker.reply(
      issueID: id, questionID: issue.questions[0].id, answers: ["reply": "Yes, wrap it"])
    try await wait { model.issue(id)?.questions.count == 2 }
    let continued = try XCTUnwrap(model.issue(id))
    XCTAssertEqual(model.snapshot.issues.count, 1)
    XCTAssertEqual(continued.threadID, "test-thread")
    XCTAssertEqual(continued.captures.count, 2)
    XCTAssertEqual(continued.questions[0].reply, "Yes, wrap it")
    XCTAssertEqual(continued.coveredRevision, 2)
    XCTAssertEqual(
      try String(contentsOf: repo.appendingPathComponent("source.txt"), encoding: .utf8), "original"
    )
    await model.worker.resetConnection()
  }
  func testDraftCanBeAssignedAProjectBeforeSubmission() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-draft-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.commit { $0.settings.paused = true }
    try model.submit(
      imageData: Data([1]), originalData: nil, annotations: [], note: "Draft",
      context: CaptureContext(), projectID: nil, existingID: nil, draft: true)
    let id = try XCTUnwrap(model.snapshot.issues.first?.id)
    let project = UUID()
    try model.submit(
      imageData: Data([2]), originalData: nil, annotations: [], note: "Ready",
      context: CaptureContext(), projectID: project, existingID: id, draft: false)
    XCTAssertEqual(model.issue(id)?.projectID, project)
    XCTAssertEqual(model.issue(id)?.captures.count, 1)
    XCTAssertEqual(model.issue(id)?.status, .queued)
  }
  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else {
      throw ScreenClipError.message("Worker did not reach the expected state")
    }
  }
}
