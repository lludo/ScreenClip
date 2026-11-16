import XCTest

@testable import ScreenClipCore

final class ExternalAssistantTests: XCTestCase {
  func testScreenshotContractAndOptionalPromptAddOnReachEvidenceAndWebhook() throws {
    let project = Project(name: "Demo", path: "/tmp/demo")
    let issue = Issue(
      projectID: project.id, title: "Clipped", capture: Capture(
        note: "Report evidence", imagePath: "/tmp/approved.png", context: CaptureContext()))
    for commit in [nil, "abc123"] as [String?] {
      for value in [nil, "Include accessibility checks.", "", " \n "] as [String?] {
        var settings = AppSettings()
        settings.defaultPromptAddOn = value
        let payload = ExternalAssistant.makePayload(
          issue: issue, project: project, repo: "owner/demo", branch: "screenclip/1",
          includePageContext: false, commit: commit, settings: settings)
        let object = try jsonObject(ExternalAssistant.json(payload))
        XCTAssertEqual(
          object["promptAddOn"] as? String,
          [ExternalAssistant.screenshotPublicationInstructions, settings.effectivePromptAddOn]
            .filter { !$0.isEmpty }.joined(separator: "\n\n"))
        XCTAssertEqual(object["notes"] as? [String], ["Report evidence"])
      }
    }
  }
  func testFilingChoicesIncludeOnlyUsableAgentsForTheProject() {
    let detections = [
      AgentDetection(kind: .codex, path: "/codex", version: "1", signedIn: nil, detail: ""),
      AgentDetection(kind: .claude, path: "/claude", version: "1", signedIn: false, detail: ""),
      AgentDetection(kind: .external, path: "", version: "configured", signedIn: true, detail: ""),
    ]
    XCTAssertEqual(AgentPicker.filingChoices(detections: [], externalAvailable: true), [])
    XCTAssertEqual(AgentPicker.filingChoices(detections: detections, externalAvailable: false), [.codex])
    XCTAssertEqual(AgentPicker.filingChoices(detections: detections, externalAvailable: true), [.codex, .external])
  }
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
      ExternalAssistant.branchName(
        reportNumber: 234, title: "Clipped button on home",
        workspaceID: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!),
      "screenclip/234-clipped-button-on-home-abcdef12")
    XCTAssertEqual(ExternalAssistant.slug("Hello, World!"), "hello-world")
    XCTAssertEqual(ExternalAssistant.slug("Café menu"), "cafe-menu")
    XCTAssertEqual(ExternalAssistant.slug("   "), "report")
    XCTAssertEqual(ExternalAssistant.slug(""), "report")
    let long = ExternalAssistant.slug(String(repeating: "word ", count: 30))
    XCTAssertLessThanOrEqual(long.count, 40)
    XCTAssertFalse(long.hasSuffix("-"))
    for title in ["", "Hello, World!", "a/b", "lead.ing", ".hidden", "semi;colon", "at@{"] {
      let branch = ExternalAssistant.branchName(reportNumber: 12, title: title, workspaceID: UUID())
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

  func testScreenshotSharingIsAlwaysEnabledForOlderAndOptedOutProjects() throws {
    var project = Project(name: "P", path: "/p")
    for preference: Bool? in [nil, false, true] {
      project.allowExternalScreenshots = preference
      let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
      XCTAssertTrue(decoded.sendsExternalScreenshots)
    }
  }

  func testGrokDetectionAndPickerAvailability() {
    let missing = AgentDetector.detectExternal(.empty)
    XCTAssertEqual(missing.kind, .external)
    XCTAssertEqual(missing.label, "Grok Bot")
    XCTAssertFalse(missing.usable)
    XCTAssertFalse(missing.installed)
    XCTAssertEqual(missing.detail, "Grok Bot is not connected")
    XCTAssertFalse(missing.detail.contains("Bearer"))
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
    XCTAssertEqual(ready.detail, "Grok Bot ready · assistant.example")
    XCTAssertFalse(ready.detail.contains("secret"))
    XCTAssertFalse(ready.detail.contains("Bearer"))
    let tested = AgentDetector.detectExternal(
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
        testSucceeded: true))
    XCTAssertEqual(tested.detail, "Grok Bot ready · assistant.example")
    XCTAssertFalse(tested.detail.contains("secret"))
    XCTAssertNil(
      ExternalAssistantConfiguration(webhookURL: "", authorization: "Bearer secret", testSucceeded: false)
        .endpoint)
    // The secret must not travel in clear text, except to a local test server.
    func endpoint(_ url: String) -> URL? {
      ExternalAssistantConfiguration(webhookURL: url, authorization: "Bearer s", testSucceeded: false)
        .endpoint
    }
    XCTAssertNil(endpoint("http://assistant.example/hook"))
    XCTAssertNil(endpoint("ftp://assistant.example/hook"))
    XCTAssertNotNil(endpoint("http://127.0.0.1:8080/hook"))
    XCTAssertNotNil(endpoint("http://localhost/hook"))
    XCTAssertNotNil(endpoint("https://assistant.example/hook"))
    XCTAssertFalse(
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer one\nBearer two",
        testSucceeded: false
      ).isConfigured)
    XCTAssertFalse(ExternalAssistantConfiguration.isSafeHeaderValue("Bearer\r\nX-Injected: 1"))

    let unconfigured = AgentPicker.externalAvailability(
      configured: false, hasProject: true, projectOptIn: true)
    XCTAssertFalse(unconfigured.enabled)
    XCTAssertEqual(unconfigured.hint, "Grok Bot is not connected")
    let noProject = AgentPicker.externalAvailability(
      configured: true, hasProject: false, projectOptIn: false)
    XCTAssertFalse(noProject.enabled)
    XCTAssertTrue(noProject.hint?.contains("Choose a project") == true)
    let optedOut = AgentPicker.externalAvailability(
      configured: true, hasProject: true, projectOptIn: false)
    XCTAssertTrue(optedOut.enabled)
    XCTAssertNil(optedOut.hint)
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
    XCTAssertEqual(ExternalDeliveryAttempt.next(stored: nil, handoffRevision: 2, revision: 2), 1)
    XCTAssertEqual(ExternalDeliveryAttempt.next(stored: 1, handoffRevision: 2, revision: 2), 2)
    XCTAssertEqual(ExternalDeliveryAttempt.next(stored: 4, handoffRevision: 2, revision: 3), 1)
    let followUp = ExternalHandoffState(
      revision: 3, handoffRevision: 2, handoffCommit: "abc", uncertain: false)
    XCTAssertEqual(ExternalHandoff.action(followUp), .commitEvidence)
    XCTAssertEqual(
      ExternalRecovery.afterRestart(status: .working, uncertain: true, sentCurrentRevision: true),
      .retrySend)
    XCTAssertEqual(
      ExternalRecovery.afterRestart(status: .working, uncertain: false, sentCurrentRevision: true),
      .watchForPullRequest)
    // Quitting while evidence was still being prepared or pushed: nothing was sent.
    XCTAssertEqual(
      ExternalRecovery.afterRestart(status: .working, uncertain: false, sentCurrentRevision: false),
      .retrySend)
    XCTAssertEqual(
      ExternalRecovery.afterRestart(status: .failed, uncertain: false, sentCurrentRevision: true),
      .retrySend)
    var issue = Issue(
      projectID: nil, title: "t",
      capture: Capture(note: "", imagePath: "/a.png", originalPath: nil, annotations: [], context: CaptureContext()))
    issue.handoffRevision = issue.revision
    issue.record("Preparing evidence for Grok Bot", status: .working)
    XCTAssertFalse(ExternalRecovery.sentCurrentRevision(issue))
    issue.record(ExternalAssistant.sentActivity)
    XCTAssertTrue(ExternalRecovery.sentCurrentRevision(issue))
    issue.record(ExternalAssistant.restartWatchActivity)
    XCTAssertTrue(ExternalRecovery.sentCurrentRevision(issue))
    issue.revision += 1
    XCTAssertFalse(ExternalRecovery.sentCurrentRevision(issue))
  }

  func testPullRequestMatchRequiresBranchAndReportMarker() {
    let issueID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
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
        reportNumber: 234, issueID: issueID, branch: branch,
        candidates: [prefixed, otherBranch, closed, merged, open]
      )?.url,
      open.url)
    XCTAssertEqual(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [merged, closed])?.url,
      merged.url)
    XCTAssertNil(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [prefixed, otherBranch]))
    XCTAssertEqual(
      ExternalPullRequestFinder.closedMatch(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [closed])?.url,
      closed.url)
  }

  func testAuthorizationStaysOnlyOnTheSameOriginDuringRedirect() {
    let origin = URL(string: "https://Assistant.Example/hook")!
    func redirect(_ target: String) -> URLRequest {
      var request = URLRequest(url: URL(string: target)!)
      request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
      return ExternalAssistantClient.requestKeepingAuthorizationOnSameOrigin(
        original: origin, redirected: request)
    }
    XCTAssertEqual(
      redirect("https://assistant.example/next").value(forHTTPHeaderField: "Authorization"),
      "Bearer secret")
    XCTAssertEqual(
      redirect("https://assistant.example:443/next").value(forHTTPHeaderField: "Authorization"),
      "Bearer secret")
    XCTAssertNil(redirect("https://elsewhere.example/next").value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirect("http://assistant.example/next").value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirect("https://assistant.example:8443/next").value(forHTTPHeaderField: "Authorization"))
    var request = URLRequest(url: URL(string: "https://assistant.example/next")!)
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    XCTAssertNil(
      ExternalAssistantClient.requestKeepingAuthorizationOnSameOrigin(original: nil, redirected: request)
        .value(forHTTPHeaderField: "Authorization"))
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

  func testForkAndMismatchedReportAreRejectedAndTheReportLineIsOptional() {
    let issueID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    let otherID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let branch = "screenclip/234-clipped-button"
    let repo = "owner/name"
    func candidate(
      _ url: String, body: String, crossRepository: Bool? = nil, draft: Bool? = nil,
      headOwner: String? = "owner"
    ) -> ExternalPullRequestCandidate {
      ExternalPullRequestCandidate(
        url: url, headRefName: branch, body: body, state: "OPEN", crossRepository: crossRepository,
        draft: draft, headOwner: headOwner)
    }
    let marker = candidate(
      "https://github.com/owner/name/pull/9", body: "ScreenClip: #234")
    let fork = candidate(
      "https://github.com/other/name/pull/3", body: "ScreenClip: #234", crossRepository: true,
      headOwner: "other")
    let wrongReport = candidate(
      "https://github.com/owner/name/pull/4",
      body: "ScreenClip: #234\nScreenClip-Report: \(otherID.uuidString)\n")
    let rightReport = candidate(
      "https://github.com/owner/name/pull/5",
      body: "ScreenClip-Report: \(issueID.uuidString.lowercased())\nScreenClip-Revision: 2\n")
    let draft = candidate(
      "https://github.com/owner/name/pull/6", body: "ScreenClip: #234", draft: true)
    XCTAssertEqual(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [fork, marker], repo: repo
      )?.url,
      marker.url)
    XCTAssertNil(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [fork], repo: repo))
    XCTAssertNil(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [wrongReport], repo: repo))
    XCTAssertEqual(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [rightReport], repo: repo
      )?.url,
      rightReport.url)
    XCTAssertEqual(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [draft], repo: repo)?.draft,
      true)
    let ownerMismatch = candidate(
      "https://github.com/other/name/pull/7", body: "ScreenClip: #234", crossRepository: nil,
      headOwner: "other")
    XCTAssertNil(
      ExternalPullRequestFinder.match(
        reportNumber: 234, issueID: issueID, branch: branch, candidates: [ownerMismatch], repo: repo))
  }

  func testAgentLinkAllowlistAcceptsOnlyTheAgentOrThisReposPullRequest() {
    let agent = "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000"
    let repo = "owner/name"
    XCTAssertEqual(ExternalAssistant.acceptedAgentURL(agent, repo: repo)?.absoluteString, agent)
    XCTAssertEqual(
      ExternalAssistant.cursorAgentURL(agent.uppercased())?.absoluteString, agent)
    XCTAssertEqual(
      ExternalAssistant.acceptedAgentURL("https://github.com/owner/name/pull/12", repo: repo)?
        .absoluteString,
      "https://github.com/owner/name/pull/12")
    XCTAssertEqual(
      ExternalAssistant.acceptedAgentURL("https://github.com/OWNER/name/pull/12", repo: repo)?
        .absoluteString,
      "https://github.com/owner/name/pull/12")
    let rejected = [
      "http://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000",
      "grokbot://app/v1/prompt?id=bot&text=ScreenClip%20%23234",
      "https://evil.example/agents/bc-00000000-0000-4000-8000-000000000000",
      "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000/extra",
      "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000?x=1",
      "https://github.com/other/name/pull/12",
      "https://github.com/owner/name/pull/12/files",
      "https://github.com/owner/name/issues/12",
    ]
    for value in rejected {
      XCTAssertNil(ExternalAssistant.acceptedAgentURL(value, repo: repo), value)
      XCTAssertNil(ExternalAssistant.cursorAgentURL(value), value)
    }
    XCTAssertNil(
      ExternalAssistant.cursorAgentURL("https://github.com/owner/name/pull/12"))
    let dirty = "Grok Bot: rev 2 accepted\u{0007}\n· agent working " + String(repeating: "x", count: 200)
    let cleaned = ExternalAssistant.statusText(dirty)
    XCTAssertFalse(cleaned.contains("\u{0007}"))
    XCTAssertFalse(cleaned.contains("\n"))
    XCTAssertEqual(cleaned.count, 140)
    XCTAssertTrue(cleaned.hasPrefix("Grok Bot: rev 2 accepted"))
  }

  func testStatusEffectKeepsTheAgentLinkAndClearsTheReminder() {
    var issue = sampleIssue()
    issue.handoffRevision = 2
    issue.status = .needsYou
    issue.prURL = nil
    issue.lastError = ExternalAssistant.noPullRequestActivity
    let status = ExternalStatus(
      state: "pending",
      targetURL: "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000",
      description: "Grok Bot: rev 2 accepted · agent working", updatedAt: "2026-11-14T00:00:00Z")
    let effect = ExternalAssistant.statusEffect(issue: issue, status: status, repo: "owner/name")
    XCTAssertEqual(
      effect.agentURL, "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000")
    XCTAssertEqual(effect.ackRevision, 2)
    XCTAssertEqual(effect.activity, "Grok Bot: rev 2 accepted · agent working")
    XCTAssertTrue(effect.clearReminder)
    XCTAssertTrue(effect.resumeWatching)
    issue.externalAgentURL = effect.agentURL
    issue.externalAckRevision = effect.ackRevision
    issue.externalStatusText = effect.statusText
    let pull = ExternalStatus(
      state: "success", targetURL: "https://github.com/owner/name/pull/12",
      description: "Grok Bot: PR #12 opened", updatedAt: nil)
    let later = ExternalAssistant.statusEffect(issue: issue, status: pull, repo: "owner/name")
    XCTAssertEqual(later.agentURL, effect.agentURL)
    XCTAssertEqual(later.activity, "Grok Bot: PR #12 opened")
    let rows = """
      [{"context":"other","state":"failure","description":"ignore","target_url":"https://evil.example"},
       {"context":"screenclip/grok-bot","state":"pending","description":"Grok Bot: rev 2","target_url":"\(status.targetURL!)",
        "updated_at":"2026-11-14T00:00:00Z"}]
      """
    let parsed = ExternalStatus.first(
      in: try! JSONDecoder().decode(JSONValue.self, from: Data(rows.utf8)))
    XCTAssertEqual(parsed?.state, "pending")
    XCTAssertEqual(parsed?.description, "Grok Bot: rev 2")
    XCTAssertNil(ExternalStatus.first(in: .array([])))
  }

  func testMissingStatusWarnsEarlyOnlyAfterAStatusWasSeen() {
    let sent = Date(timeIntervalSince1970: 1_000)
    let early = sent.addingTimeInterval(14 * 60)
    let due = sent.addingTimeInterval(15 * 60)
    XCTAssertFalse(
      ExternalAssistant.shouldWarnAboutMissingStatus(
        statusSeen: false, acknowledged: false, alreadyWarned: false, awaitingPullRequest: true,
        sentAt: sent, now: due))
    XCTAssertFalse(
      ExternalAssistant.shouldWarnAboutMissingStatus(
        statusSeen: true, acknowledged: false, alreadyWarned: false, awaitingPullRequest: true,
        sentAt: sent, now: early))
    XCTAssertTrue(
      ExternalAssistant.shouldWarnAboutMissingStatus(
        statusSeen: true, acknowledged: false, alreadyWarned: false, awaitingPullRequest: true,
        sentAt: sent, now: due))
    XCTAssertFalse(
      ExternalAssistant.shouldWarnAboutMissingStatus(
        statusSeen: true, acknowledged: true, alreadyWarned: false, awaitingPullRequest: true,
        sentAt: sent, now: due))
    XCTAssertFalse(
      ExternalAssistant.shouldWarnAboutMissingStatus(
        statusSeen: true, acknowledged: false, alreadyWarned: true, awaitingPullRequest: true,
        sentAt: sent, now: due))
    XCTAssertEqual(
      ExternalAssistant.pickupWarning(revision: 2),
      "Grok Bot hasn't picked up revision 2 yet (run may have failed or hit a rate limit). Continue resends it.")
  }

  func testDeliveryKeyStaysOutOfTheReportFileAndAttemptsDoNotChangeTheKey() throws {
    var issue = sampleIssue()
    issue.activities.append(Activity("Previous fix: https://github.com/owner/name/pull/12"))
    issue.activities.append(Activity("Previous fix: https://github.com/owner/name/pull/12"))
    let project = Project(name: "ScreenClip", path: "/repo", validationCommand: "true")
    let commit = "0123456789abcdef0123456789abcdef01234567"
    let file = ExternalAssistant.makePayload(
      issue: issue, project: project, repo: "owner/name", branch: "screenclip/234-clipped-button",
      includePageContext: false, commit: nil, attempt: 2,
      previousPullRequests: ExternalAssistant.previousPullRequests(in: issue.activities))
    let fileObject = try jsonObject(try ExternalAssistant.json(file, pretty: true))
    XCTAssertNil(fileObject["delivery"])
    XCTAssertFalse(String(decoding: try ExternalAssistant.json(file), as: UTF8.self).contains(":r2:"))
    XCTAssertEqual(fileObject["workspaceID"] as? String, issue.workspaceID.uuidString)
    XCTAssertEqual(
      fileObject["previousPullRequests"] as? [String], ["https://github.com/owner/name/pull/12"])
    let wire = ExternalAssistant.makePayload(
      issue: issue, project: project, repo: "owner/name", branch: "screenclip/234-clipped-button",
      includePageContext: false, commit: commit, attempt: 2,
      previousPullRequests: ExternalAssistant.previousPullRequests(in: issue.activities))
    let wireObject = try jsonObject(try ExternalAssistant.json(wire))
    let delivery = try XCTUnwrap(wireObject["delivery"] as? [String: Any])
    XCTAssertEqual(
      delivery["key"] as? String, "\(issue.id.uuidString):r2:\(commit)")
    XCTAssertEqual(delivery["attempt"] as? Int, 2)
    XCTAssertEqual(wireObject["schema"] as? String, "screenclip.external.v1")
    let retried = ExternalAssistant.makePayload(
      issue: issue, project: project, repo: "owner/name", branch: "screenclip/234-clipped-button",
      includePageContext: false, commit: commit, attempt: 3)
    let retriedDelivery = try XCTUnwrap(
      (try jsonObject(try ExternalAssistant.json(retried)))["delivery"] as? [String: Any])
    XCTAssertEqual(retriedDelivery["key"] as? String, delivery["key"] as? String)
    XCTAssertEqual(retriedDelivery["attempt"] as? Int, 3)
    XCTAssertEqual(
      ExternalAssistant.rejectionMessage(status: 401), "Grok Bot rejected the report (HTTP 401).")
    XCTAssertFalse(ExternalAssistant.rejectionMessage(status: 401).contains("secret"))
  }

  func testIdempotencyHeaderIsSentAndTheReplyBodyIsNotRequired() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExternalHeaderCapture.self]
    let session = URLSession(configuration: configuration)
    let key = "00000000-0000-4000-8000-000000000000:r2:0123456789abcdef0123456789abcdef01234567"
    _ = try await ExternalAssistantClient.post(
      url: try XCTUnwrap(URL(string: "https://assistant.example/hook")),
      authorization: "Bearer secret", body: Data("{}".utf8), session: session, idempotencyKey: key)
    XCTAssertEqual(ExternalHeaderCapture.snapshot().idempotencyKey, key)
    _ = try await ExternalAssistantClient.post(
      url: try XCTUnwrap(URL(string: "https://assistant.example/hook")),
      authorization: "Bearer secret", body: Data("{}".utf8), session: session)
    XCTAssertNil(ExternalHeaderCapture.snapshot().idempotencyKey)
  }

  func testCancelPayloadAndCapabilityGate() throws {
    var issue = sampleIssue()
    let payload = try XCTUnwrap(
      ExternalAssistant.makeCancelPayload(
        issue: issue, repo: "owner/name", branch: "screenclip/234-clipped-button-a1b2c3d4"))
    let object = try jsonObject(try ExternalAssistant.jsonCancel(payload))
    XCTAssertEqual(object["schema"] as? String, "screenclip.external.v1.cancel")
    XCTAssertEqual(object["issueID"] as? String, issue.id.uuidString)
    XCTAssertEqual(object["reportNumber"] as? Int, 234)
    XCTAssertEqual(object["revision"] as? Int, issue.revision)
    XCTAssertEqual((object["project"] as? [String: Any])?["repo"] as? String, "owner/name")
    XCTAssertEqual(
      (object["evidence"] as? [String: Any])?["branch"] as? String,
      "screenclip/234-clipped-button-a1b2c3d4")
    XCTAssertEqual(object.count, 6)
    XCTAssertNil(object["delivery"])
    let absent = ExternalAssistantConfiguration(
      webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
      testSucceeded: true)
    XCTAssertFalse(absent.supportsCancel)
    let present = ExternalAssistantConfiguration(
      webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
      testSucceeded: true, capabilities: ["cancel"])
    XCTAssertTrue(present.supportsCancel)
    XCTAssertFalse(
      ExternalAssistantConfiguration(
        webhookURL: "https://assistant.example/hook", authorization: "Bearer secret",
        testSucceeded: true, capabilities: ["ask"]
      ).supportsCancel)
    XCTAssertEqual(
      ExternalAssistantConfiguration.resolvedCapabilities(
        explicit: nil, url: "https://assistant.example/hook", previous: present),
      ["cancel"])
    XCTAssertEqual(
      ExternalAssistantConfiguration.resolvedCapabilities(
        explicit: nil, url: "https://other.example/hook", previous: present),
      [])
    issue.reportNumber = nil
    XCTAssertNil(
      ExternalAssistant.makeCancelPayload(issue: issue, repo: "owner/name", branch: "screenclip/1"))
  }

  func testDraftPullRequestIsNeverReadyToMerge() {
    var evidence = MergeEvidence(
      expectedHead: "abc", currentHead: "abc", inputRevision: 2, coveredRevision: 2,
      validationPassed: true, hasValidation: true, checksPassed: true, mergeable: true,
      reviewSatisfied: true, unresolvedQuestions: false, screenclipEvidenceCleared: true,
      draft: true)
    XCTAssertFalse(evidence.canMerge)
    evidence.draft = false
    XCTAssertTrue(evidence.canMerge)
    let draftState = try! JSONDecoder().decode(
      JSONValue.self, from: Data("{\"isDraft\":true,\"state\":\"OPEN\"}".utf8))
    XCTAssertTrue(PRState.parse(draftState).draft)
    let older = try! JSONDecoder().decode(JSONValue.self, from: Data("{\"state\":\"OPEN\"}".utf8))
    XCTAssertFalse(PRState.parse(older).draft)
  }

  func testOldQueueDecodesWithoutTheNewHandoffFields() throws {
    var issue = sampleIssue()
    issue.externalAgentURL = "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000"
    issue.externalAckRevision = 2
    issue.externalStatusText = "working"
    issue.handoffAttempts = 2
    var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(issue)) as? [String: Any]
    stored?.removeValue(forKey: "externalAgentURL")
    stored?.removeValue(forKey: "externalAckRevision")
    stored?.removeValue(forKey: "externalStatusText")
    stored?.removeValue(forKey: "handoffAttempts")
    stored?.removeValue(forKey: "handoffRevision")
    stored?.removeValue(forKey: "handoffCommit")
    let decoded = try JSONDecoder().decode(
      Issue.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(stored)))
    XCTAssertNil(decoded.externalAgentURL)
    XCTAssertNil(decoded.externalAgentLink)
    XCTAssertNil(decoded.externalAckRevision)
    XCTAssertNil(decoded.externalStatusText)
    XCTAssertNil(decoded.handoffAttempts)
    XCTAssertEqual(decoded.externalConversationNote, ExternalAssistant.conversationNote)
    issue.prURL = nil
    issue.externalAgentURL = "https://cursor.com/agents/bc-00000000-0000-4000-8000-000000000000"
    XCTAssertNil(issue.externalConversationNote)
    XCTAssertNotNil(issue.externalAgentLink)
    var settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings()))
      as? [String: Any]
    settings?.removeValue(forKey: "externalStatusSeen")
    let decodedSettings = try JSONDecoder().decode(
      AppSettings.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(settings)))
    XCTAssertNil(decodedSettings.externalStatusSeen)
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
  private static var idempotencyKey: String?
  static func snapshot() -> (authorization: String?, body: Data?, idempotencyKey: String?) {
    lock.lock()
    defer { lock.unlock() }
    return (authorization, body, idempotencyKey)
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let authorization = request.value(forHTTPHeaderField: "Authorization")
    let body = Self.bodyData(from: request)
    let idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
    Self.lock.lock()
    Self.authorization = authorization
    Self.body = body
    Self.idempotencyKey = idempotencyKey
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
