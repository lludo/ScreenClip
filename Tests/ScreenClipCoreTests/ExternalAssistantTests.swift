import XCTest

@testable import ScreenClipCore

final class ExternalAssistantTests: XCTestCase {
  func testPayloadOmitsPageContextAndImageBytesUntilContextIsAllowed() throws {
    let issue = sampleIssue()
    let project = Project(
      name: "ScreenClip", path: "/repo", baseBranch: "main", validationCommand: "bash scripts/test.sh")
    let hidden = ExternalAssistant.makePayload(
      issue: issue, project: project, repo: "lludo/ScreenClip", branch: "screenclip/234-clipped-button",
      includePageContext: false, commit: nil)
    let shown = ExternalAssistant.makePayload(
      issue: issue, project: project, repo: "lludo/ScreenClip", branch: "screenclip/234-clipped-button",
      includePageContext: true, commit: "abc123")
    let hiddenJSON = try ExternalAssistant.json(hidden)
    let shownJSON = try ExternalAssistant.json(shown)
    XCTAssertEqual(try ExternalAssistant.json(hidden), hiddenJSON)
    let hiddenObject = try jsonObject(hiddenJSON)
    let shownObject = try jsonObject(shownJSON)
    XCTAssertEqual(hiddenObject["schema"] as? String, "screenclip.external.v1")
    XCTAssertEqual(hiddenObject["reportNumber"] as? Int, 234)
    XCTAssertEqual(hiddenObject["issueID"] as? String, issue.id.uuidString)
    XCTAssertEqual(hiddenObject["revision"] as? Int, 2)
    XCTAssertEqual(hiddenObject["title"] as? String, "Clipped button")
    XCTAssertEqual(hiddenObject["notes"] as? [String], ["First", "Second"])
    let hiddenContext = try XCTUnwrap(hiddenObject["context"] as? [String: Any])
    XCTAssertEqual(hiddenContext["appName"] as? String, "Safari")
    XCTAssertEqual(hiddenContext["bundleID"] as? String, "com.apple.Safari")
    XCTAssertNil(hiddenContext["browserURL"])
    XCTAssertNil(hiddenContext["windowTitle"])
    let shownContext = try XCTUnwrap(shownObject["context"] as? [String: Any])
    XCTAssertEqual(shownContext["browserURL"] as? String, "https://example.com/checkout")
    XCTAssertEqual(shownContext["windowTitle"] as? String, "Checkout")
    let projectObject = try XCTUnwrap(hiddenObject["project"] as? [String: Any])
    XCTAssertEqual(projectObject["repo"] as? String, "lludo/ScreenClip")
    XCTAssertEqual(projectObject["baseBranch"] as? String, "main")
    XCTAssertEqual(projectObject["validationCommand"] as? String, "bash scripts/test.sh")
    let evidence = try XCTUnwrap(hiddenObject["evidence"] as? [String: Any])
    XCTAssertEqual(evidence["branch"] as? String, "screenclip/234-clipped-button")
    XCTAssertTrue(evidence["commit"] is NSNull)
    XCTAssertEqual(
      evidence["paths"] as? [String],
      [".screenclip/234/report.json", ".screenclip/234/capture-1.png", ".screenclip/234/capture-2.png"])
    let wireEvidence = try XCTUnwrap(shownObject["evidence"] as? [String: Any])
    XCTAssertEqual(wireEvidence["commit"] as? String, "abc123")
    XCTAssertEqual(wireEvidence["paths"] as? [String], evidence["paths"] as? [String])
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    XCTAssertNil(hiddenJSON.range(of: png))
    XCTAssertFalse(String(decoding: hiddenJSON, as: UTF8.self).contains("base64"))
    let test = try jsonObject(ExternalAssistant.testJSON())
    XCTAssertEqual(test["schema"] as? String, "screenclip.external.v1.test")
    XCTAssertEqual(test.count, 1)
    var withContext = issue
    withContext.addContext("The purchase button, not the title.")
    let contextPayload = ExternalAssistant.makePayload(
      issue: withContext, project: project, repo: "lludo/ScreenClip",
      branch: "screenclip/234-clipped-button", includePageContext: false, commit: nil)
    let contextObject = try jsonObject(try ExternalAssistant.json(contextPayload))
    XCTAssertEqual(contextObject["notes"] as? [String], ["First", "Second"])
    XCTAssertEqual(
      contextObject["contextNotes"] as? [String], ["The purchase button, not the title."])
    XCTAssertEqual(
      (contextObject["evidence"] as? [String: Any])?["paths"] as? [String],
      [".screenclip/234/report.json", ".screenclip/234/capture-1.png", ".screenclip/234/capture-2.png"])
  }

  func testEvidenceWriterStoresApprovedFilesOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-evidence-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1])
    let report = Data("{\"schema\":\"screenclip.external.v1\"}".utf8)
    let paths = try ExternalEvidenceWriter.write(
      worktree: root.path, reportNumber: 234, report: report, images: [png])
    XCTAssertEqual(paths, [".screenclip/234/report.json", ".screenclip/234/capture-1.png"])
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(".screenclip/234/capture-1.png")), png)
    _ = try ExternalEvidenceWriter.write(
      worktree: root.path, reportNumber: 234, report: report, images: [png, Data([2])])
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".screenclip/234/capture-1.png").path))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(".screenclip/234/capture-2.png")), Data([2]))
    XCTAssertNil(report.range(of: png))
  }

  func testBranchSlugIsStableAndGitSafe() {
    XCTAssertEqual(
      ExternalAssistant.branchName(reportNumber: 234, title: "Clipped button on home"),
      "screenclip/234-clipped-button-on-home")
    XCTAssertEqual(ExternalAssistant.slug("Hello, World!"), "hello-world")
    XCTAssertEqual(ExternalAssistant.slug("Café menu"), "cafe-menu")
    XCTAssertEqual(ExternalAssistant.slug("   "), "report")
    XCTAssertEqual(ExternalAssistant.slug(""), "report")
    let long = ExternalAssistant.slug(String(repeating: "word ", count: 30))
    XCTAssertLessThanOrEqual(long.count, 40)
    XCTAssertFalse(long.hasSuffix("-"))
    for title in ["", "Hello, World!", "a/b", "lead.ing", ".hidden", "semi;colon", "at@{"] {
      let branch = ExternalAssistant.branchName(reportNumber: 12, title: title)
      XCTAssertTrue(branch.hasPrefix("screenclip/12-"), branch)
      XCTAssertFalse(branch.contains(" "))
      XCTAssertFalse(branch.contains(".."))
      XCTAssertFalse(branch.contains("~"))
      XCTAssertFalse(branch.contains("^"))
      XCTAssertFalse(branch.contains(":"))
      XCTAssertFalse(branch.contains("?"))
      XCTAssertFalse(branch.contains("*"))
      XCTAssertFalse(branch.contains("["))
      XCTAssertFalse(branch.contains("\\"))
      XCTAssertFalse(branch.contains("@{"))
      XCTAssertFalse(branch.contains("//"))
      XCTAssertFalse(branch.hasSuffix(".lock"))
      XCTAssertFalse(branch.hasSuffix("."))
    }
  }

  func testRepositorySlugParsesGitHubRemotesOnly() {
    XCTAssertEqual(GitHubRepository.parse(remote: "https://github.com/lludo/ScreenClip.git")?.slug, "lludo/ScreenClip")
    XCTAssertEqual(GitHubRepository.parse(remote: "git@github.com:lludo/ScreenClip.git")?.slug, "lludo/ScreenClip")
    XCTAssertEqual(
      GitHubRepository.parse(remote: "ssh://git@github.com/lludo/ScreenClip.git")?.slug, "lludo/ScreenClip")
    XCTAssertEqual(
      GitHubRepository.parse(remote: "https://github.com/lludo/ScreenClip/")?.slug, "lludo/ScreenClip")
    XCTAssertEqual(
      GitHubRepository.parse(remote: "https://www.github.com/lludo/ScreenClip.git")?.slug,
      "lludo/ScreenClip")
    XCTAssertNil(GitHubRepository.parse(remote: "https://gitlab.com/lludo/ScreenClip.git"))
    XCTAssertNil(GitHubRepository.parse(remote: "https://notgithub.com/lludo/ScreenClip"))
  }

  func testOptInIsRequiredForPublicAndPrivateRepositories() {
    let publicRefusal = ExternalScreenshotGate.refusal(optIn: false, repositoryIsPublic: true)
    let privateRefusal = ExternalScreenshotGate.refusal(optIn: false, repositoryIsPublic: false)
    let unknownRefusal = ExternalScreenshotGate.refusal(optIn: false, repositoryIsPublic: nil)
    XCTAssertTrue(publicRefusal?.contains("public") == true)
    XCTAssertTrue(privateRefusal?.contains("Allow sending screenshots") == true)
    XCTAssertFalse(privateRefusal?.contains("public") == true)
    XCTAssertEqual(privateRefusal, unknownRefusal)
    XCTAssertNil(ExternalScreenshotGate.refusal(optIn: true, repositoryIsPublic: true))
    XCTAssertNil(ExternalScreenshotGate.refusal(optIn: true, repositoryIsPublic: false))
    let older: [String: Any] = [
      "id": UUID().uuidString, "name": "P", "path": "/p", "baseBranch": "main", "origins": [String](),
      "bundleIDs": [String](), "validationCommand": "", "autoMerge": true,
    ]
    let decoded = try? JSONDecoder().decode(
      Project.self, from: JSONSerialization.data(withJSONObject: older))
    XCTAssertEqual(decoded?.sendsExternalScreenshots, false)
  }

  func testGrokDetectionAndPickerAvailability() {
    let missing = AgentDetector.detectExternal(.empty)
    XCTAssertEqual(missing.kind, .external)
    XCTAssertEqual(missing.label, "Grok Bot — not configured")
    XCTAssertFalse(missing.usable)
    XCTAssertFalse(missing.installed)
    XCTAssertTrue(missing.detail.contains("Not configured"))
    XCTAssertTrue(missing.detail.contains("Connections"))
    let partial = AgentDetector.detectExternal(
      ExternalAssistantConfiguration(webhookURL: "not a url", authorization: "Bearer x", testSucceeded: false))
    XCTAssertFalse(partial.usable)
    XCTAssertTrue(partial.detail.contains("http"))
    let ready = AgentDetector.detectExternal(
      ExternalAssistantConfiguration(
        webhookURL: " https://assistant.example/hook ", authorization: "Bearer secret",
        testSucceeded: false))
    XCTAssertTrue(ready.usable)
    XCTAssertEqual(ready.label, "Grok Bot")
    XCTAssertTrue(ready.detail.contains("Detected"))
    XCTAssertFalse(ready.detail.contains("Send test"))
    let tested = AgentDetector.detectExternal(
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
        testSucceeded: true))
    XCTAssertTrue(tested.detail.contains("Send test succeeded"))
    XCTAssertNil(
      ExternalAssistantConfiguration(webhookURL: "", authorization: "Bearer secret", testSucceeded: false)
        .endpoint)
    XCTAssertFalse(
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer one\nBearer two",
        testSucceeded: false
      ).isConfigured)
    XCTAssertFalse(ExternalAssistantConfiguration.isSafeHeaderValue("Bearer\r\nX-Injected: 1"))

    let unconfigured = AgentPicker.externalAvailability(
      configured: false, hasProject: true, projectOptIn: true)
    XCTAssertFalse(unconfigured.enabled)
    XCTAssertTrue(unconfigured.hint?.contains("Connections") == true)
    let noProject = AgentPicker.externalAvailability(
      configured: true, hasProject: false, projectOptIn: false)
    XCTAssertFalse(noProject.enabled)
    XCTAssertTrue(noProject.hint?.contains("Choose a project") == true)
    let optedOut = AgentPicker.externalAvailability(
      configured: true, hasProject: true, projectOptIn: false)
    XCTAssertFalse(optedOut.enabled)
    XCTAssertTrue(optedOut.hint?.contains("Allow sending screenshots") == true)
    let available = AgentPicker.externalAvailability(
      configured: true, hasProject: true, projectOptIn: true)
    XCTAssertTrue(available.enabled)
    XCTAssertNil(available.hint)
  }

  func testRetryPostsTheSameRevisionWithoutANewEvidenceCommit() {
    let initial = ExternalHandoffState(
      revision: 2, handoffRevision: nil, handoffCommit: nil, uncertain: false)
    XCTAssertEqual(ExternalHandoff.action(initial), .commitEvidence)
    let sending = ExternalHandoff.beginSend(initial, revision: 2, commit: "abc")
    XCTAssertTrue(sending.uncertain)
    XCTAssertEqual(sending.handoffCommit, "abc")
    XCTAssertEqual(sending.handoffRevision, 2)
    XCTAssertEqual(ExternalHandoff.action(sending), .postExisting(commit: "abc"))
    let failed = ExternalHandoff.finishSend(sending, succeeded: false)
    XCTAssertFalse(failed.uncertain)
    XCTAssertEqual(failed.handoffCommit, "abc")
    XCTAssertEqual(ExternalHandoff.action(failed), .postExisting(commit: "abc"))
    XCTAssertEqual(ExternalHandoff.beginSend(failed, revision: 2, commit: "abc"), sending)
    let followUp = ExternalHandoffState(
      revision: 3, handoffRevision: 2, handoffCommit: "abc", uncertain: false)
    XCTAssertEqual(ExternalHandoff.action(followUp), .commitEvidence)
    XCTAssertEqual(
      ExternalRecovery.afterRestart(status: .working, uncertain: true), .retrySend)
    XCTAssertEqual(
      ExternalRecovery.afterRestart(status: .working, uncertain: false), .watchForPullRequest)
    XCTAssertEqual(ExternalRecovery.afterRestart(status: .failed, uncertain: false), .retrySend)
  }

  func testPullRequestMatchRequiresBranchAndReportMarker() {
    let branch = "screenclip/234-clipped-button"
    let open = ExternalPullRequestCandidate(
      url: "https://github.com/lludo/ScreenClip/pull/9", headRefName: branch,
      body: "Fixes the clip.\n\nScreenClip: #234\n", state: "OPEN")
    let prefixed = ExternalPullRequestCandidate(
      url: "https://github.com/lludo/ScreenClip/pull/10", headRefName: branch,
      body: "ScreenClip: #2345", state: "OPEN")
    let otherBranch = ExternalPullRequestCandidate(
      url: "https://github.com/lludo/ScreenClip/pull/11", headRefName: "screenclip/99-other",
      body: "ScreenClip: #234", state: "OPEN")
    let closed = ExternalPullRequestCandidate(
      url: "https://github.com/lludo/ScreenClip/pull/12", headRefName: branch,
      body: "ScreenClip: #234", state: "CLOSED")
    let merged = ExternalPullRequestCandidate(
      url: "https://github.com/lludo/ScreenClip/pull/8", headRefName: branch,
      body: "ScreenClip: #234", state: "MERGED")
    XCTAssertEqual(
      ExternalPullRequestFinder.match(
        reportNumber: 234, branch: branch, candidates: [prefixed, otherBranch, closed, merged, open]
      )?.url,
      open.url)
    XCTAssertEqual(
      ExternalPullRequestFinder.match(
        reportNumber: 234, branch: branch, candidates: [merged, closed])?.url,
      merged.url)
    XCTAssertNil(
      ExternalPullRequestFinder.match(
        reportNumber: 234, branch: branch, candidates: [prefixed, otherBranch]))
    XCTAssertEqual(
      ExternalPullRequestFinder.closedMatch(
        reportNumber: 234, branch: branch, candidates: [closed])?.url,
      closed.url)
  }

  func testAuthorizationStaysOnTheSameHostDuringRedirect() {
    var same = URLRequest(url: URL(string: "https://assistant.example/next")!)
    same.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let kept = ExternalAssistantClient.requestKeepingAuthorizationOnSameHost(
      originalHost: "assistant.example", redirected: same)
    XCTAssertEqual(kept.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    var other = URLRequest(url: URL(string: "https://elsewhere.example/next")!)
    other.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let stripped = ExternalAssistantClient.requestKeepingAuthorizationOnSameHost(
      originalHost: "Assistant.Example", redirected: other)
    XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
    let missing = ExternalAssistantClient.requestKeepingAuthorizationOnSameHost(
      originalHost: nil, redirected: same)
    XCTAssertNil(missing.value(forHTTPHeaderField: "Authorization"))
  }

  func testScreenclipPathsBlockAutomaticMerge() {
    XCTAssertTrue(ExternalAssistant.containsScreenclipEvidence([".screenclip/234/report.json"]))
    XCTAssertTrue(ExternalAssistant.containsScreenclipEvidence([".screenclip/234/capture-1.png"]))
    XCTAssertFalse(ExternalAssistant.containsScreenclipEvidence([]))
    XCTAssertFalse(ExternalAssistant.containsScreenclipEvidence(["Sources/App.swift"]))
    XCTAssertFalse(ExternalAssistant.containsScreenclipEvidence(["docs/screenclip/readme.md"]))
    var evidence = MergeEvidence(
      expectedHead: "abc", currentHead: "abc", inputRevision: 2, coveredRevision: 2,
      validationPassed: true, hasValidation: true, checksPassed: true, mergeable: true,
      reviewSatisfied: true, unresolvedQuestions: false, screenclipEvidenceCleared: false)
    XCTAssertFalse(evidence.canMerge)
    evidence.screenclipEvidenceCleared = true
    XCTAssertTrue(evidence.canMerge)
  }

  func testFollowUpRequeuesExternalWorkAndOlderIssuesStayCodex() throws {
    var issue = Issue(
      projectID: UUID(), title: "Clipped button",
      capture: Capture(note: "First", imagePath: "/a.png", context: CaptureContext()), agent: .external)
    issue.status = .working
    issue.prURL = "https://github.com/lludo/ScreenClip/pull/9"
    issue.branch = "screenclip/1-clipped-button"
    issue.add(Capture(note: "Second", imagePath: "/b.png", context: CaptureContext()))
    XCTAssertEqual(issue.status, .queued)
    XCTAssertEqual(issue.revision, 2)
    XCTAssertEqual(issue.agent, .external)
    XCTAssertEqual(issue.prURL, "https://github.com/lludo/ScreenClip/pull/9")
    XCTAssertEqual(issue.branch, "screenclip/1-clipped-button")
    var local = Issue(
      projectID: UUID(), title: "Local",
      capture: Capture(note: "", imagePath: "/a.png", context: CaptureContext()), agent: .codex)
    local.status = .working
    local.add(Capture(note: "more", imagePath: "/c.png", context: CaptureContext()))
    XCTAssertEqual(local.status, .working)
    var stored = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(issue)) as? [String: Any]
    stored?.removeValue(forKey: "handoffRevision")
    stored?.removeValue(forKey: "handoffCommit")
    stored?.removeValue(forKey: "agent")
    let decoded = try JSONDecoder().decode(
      Issue.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(stored)))
    XCTAssertEqual(decoded.resolvedAgent, .codex)
    XCTAssertNil(decoded.handoffCommit)
    XCTAssertNil(decoded.externalConversationNote)
    var remote = issue
    remote.prURL = nil
    XCTAssertEqual(remote.externalConversationNote, ExternalAssistant.conversationNote)
  }

  func testTestRequestSendsTheAuthorizationHeaderVerbatim() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExternalHeaderCapture.self]
    ExternalHeaderCapture.statusCode = 204
    let session = URLSession(configuration: configuration)
    let response = try await ExternalAssistantClient.post(
      url: try XCTUnwrap(URL(string: "https://assistant.example/hook")),
      authorization: "Bearer custom-value", body: try ExternalAssistant.testJSON(), session: session)
    XCTAssertTrue(response.succeeded)
    XCTAssertEqual(response.status, 204)
    let captured = ExternalHeaderCapture.snapshot()
    XCTAssertEqual(captured.authorization, "Bearer custom-value")
    let body = try jsonObject(try XCTUnwrap(captured.body))
    XCTAssertEqual(body["schema"] as? String, "screenclip.external.v1.test")
    ExternalHeaderCapture.statusCode = 422
    let rejected = try await ExternalAssistantClient.post(
      url: try XCTUnwrap(URL(string: "https://assistant.example/hook")),
      authorization: "Token raw", body: Data("{}".utf8), session: session)
    XCTAssertFalse(rejected.succeeded)
    XCTAssertEqual(rejected.status, 422)
    XCTAssertEqual(ExternalHeaderCapture.snapshot().authorization, "Token raw")
  }

  private func sampleIssue() -> Issue {
    var issue = Issue(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(), projectID: UUID(),
      title: "Clipped button",
      capture: Capture(
        note: "First", imagePath: "/approved.png", originalPath: "/original.png",
        context: CaptureContext(
          appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Checkout",
          browserURL: "https://example.com/checkout")),
      agent: .external)
    issue.reportNumber = 234
    issue.add(
      Capture(
        note: "Second", imagePath: "/approved-2.png",
        context: CaptureContext(
          appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Checkout",
          browserURL: "https://example.com/checkout")))
    return issue
  }

  private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private final class ExternalHeaderCapture: URLProtocol, @unchecked Sendable {
  static var statusCode = 204
  private static let lock = NSLock()
  private static var authorization: String?
  private static var body: Data?
  static func snapshot() -> (authorization: String?, body: Data?) {
    lock.lock()
    defer { lock.unlock() }
    return (authorization, body)
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let authorization = request.value(forHTTPHeaderField: "Authorization")
    let body = Self.bodyData(from: request)
    Self.lock.lock()
    Self.authorization = authorization
    Self.body = body
    Self.lock.unlock()
    let response = HTTPURLResponse(
      url: request.url ?? URL(fileURLWithPath: "/"), statusCode: Self.statusCode, httpVersion: nil,
      headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
  private static func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: 1024)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
