import XCTest

@testable import ScreenClipCore

final class CoreTests: XCTestCase {
  func testSelfCapturePreferenceLoadsOlderSettingsAndPersistsBothChoices() throws {
    let older = try JSONEncoder().encode(AppSettings())
    var settings = try JSONDecoder().decode(AppSettings.self, from: older)
    XCTAssertTrue(settings.shouldHideScreenClipDuringCapture)
    for hide in [true, false] {
      settings.hideScreenClipDuringCapture = hide
      let store = try temporaryStore()
      var snapshot = StoreSnapshot()
      snapshot.settings = settings
      try store.save(snapshot)
      XCTAssertEqual(try store.load().settings.shouldHideScreenClipDuringCapture, hide)
    }
  }
  func temporaryStore() throws -> IssueStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-test-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try IssueStore(root: root)
  }
  func capture() -> Capture {
    Capture(
      note: "A clipped label", imagePath: "/tmp/test.png", context: CaptureContext(appName: "Test"))
  }
  func testNewStoreHidesScreenClipDuringCaptureByDefault() throws {
    let store = try temporaryStore()
    XCTAssertTrue(try store.load().settings.shouldHideScreenClipDuringCapture)
  }
  func testLegacySettingsDefaultToHidingScreenClipWithoutChangingOtherPreferences() throws {
    var settings = AppSettings()
    settings.browserContext = true
    settings.sessionName = "Legacy session"
    settings.shortcutKey = 20
    settings.testedVersion = "build 42"
    let legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
      .filter { $0.key != "hideScreenClipDuringCapture" }
    let decoded = try JSONDecoder().decode(
      AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertTrue(decoded.shouldHideScreenClipDuringCapture)
    XCTAssertEqual(decoded, settings)
  }
  func testCaptureVisibilityChoicePersistsAcrossStoreReloads() throws {
    let store = try temporaryStore()
    for hidden in [false, true] {
      var state = StoreSnapshot()
      state.settings.hideScreenClipDuringCapture = hidden
      try store.save(state)
      let reopened = try IssueStore(root: store.root, readOnly: true).load()
      XCTAssertEqual(reopened.settings.hideScreenClipDuringCapture, hidden)
    }
  }
  func testDurableSubmissionPreservesImageRevisionAndContext() throws {
    let store = try temporaryStore()
    let bytes = Data([1, 2, 3, 4])
    let path = try store.writeAsset(bytes)
    var state = StoreSnapshot()
    var context = CaptureContext(
      appName: "Safari", bundleID: "com.apple.Safari", browserURL: "http://localhost:3000/checkout",
      testedVersion: "build 42")
    context.selection = [10, 20, 100, 200]
    state.issues = [
      Issue(
        projectID: UUID(), title: "Clipped",
        capture: Capture(note: "Label", imagePath: path, context: context))
    ]
    state = try store.save(state)
    let reopened = try IssueStore(root: store.root, readOnly: true).load()
    XCTAssertEqual(reopened.issues, state.issues)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: reopened.issues[0].captures[0].imagePath)), bytes)
    XCTAssertEqual(reopened.issues[0].status, .queued)
  }
  func testLegacyReportNumbersMigrateInCreationOrderWithoutReordering() throws {
    var older = Issue(projectID: nil, title: "Older", capture: capture())
    older.createdAt = Date(timeIntervalSince1970: 1)
    older.archived = true
    var newer = Issue(projectID: nil, title: "Newer draft", capture: capture(), draft: true)
    newer.createdAt = Date(timeIntervalSince1970: 2)
    var state = StoreSnapshot()
    state.issues = [newer, older]
    let legacyData = try JSONEncoder().encode(state)
    let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
    XCTAssertNil(legacyJSON["nextReportNumber"])
    XCTAssertNil((legacyJSON["issues"] as? [[String: Any]])?.first?["reportNumber"])
    let legacy = try JSONDecoder().decode(StoreSnapshot.self, from: legacyData)
    let store = try temporaryStore()
    let migrated = try store.save(legacy)
    XCTAssertEqual(migrated.issues.map(\.id), [newer.id, older.id])
    XCTAssertEqual(migrated.issues.map(\.reportNumber), [2, 1])
    XCTAssertEqual(migrated.nextReportNumber, 3)
    let reopened = try IssueStore(root: store.root, readOnly: true).load()
    XCTAssertEqual(reopened.issues, migrated.issues)
    // Saving the same pre-migration value cannot renumber existing reports.
    XCTAssertEqual(try store.save(legacy).issues, migrated.issues)
  }
  func testReportNumbersSurviveUpdatesAndAreNeverReusedAfterDeletion() throws {
    let store = try temporaryStore()
    var state = StoreSnapshot()
    state.issues = [Issue(projectID: nil, title: "First", capture: capture())]
    state = try store.save(state)
    XCTAssertEqual(state.issues[0].reportNumber, 1)
    state.issues[0].add(capture())
    state.issues[0].title = "Renamed"
    state = try store.save(state)
    XCTAssertEqual(state.issues[0].reportNumber, 1)
    state.issues.append(Issue(projectID: nil, title: "Second", capture: capture()))
    state = try store.save(state)
    XCTAssertEqual(state.issues[1].reportNumber, 2)
    // Delete every report, including the highest number, then simulate a fresh caller.
    try store.save(StoreSnapshot())
    let empty = try IssueStore(root: store.root, readOnly: true).load()
    XCTAssertEqual(empty.nextReportNumber, 3)
    var replacement = StoreSnapshot()
    replacement.issues = [Issue(projectID: nil, title: "Third", capture: capture())]
    XCTAssertEqual(try store.save(replacement).issues[0].reportNumber, 3)
  }
  func testReportReferenceSearchIsExactAndStillMatchesDescriptions() {
    var issue = Issue(projectID: nil, title: "Clipped label", capture: capture())
    issue.reportNumber = 234
    XCTAssertEqual(issue.reportReference, "#234")
    XCTAssertEqual(issue.referencedTitle, "#234 Clipped label")
    for query in ["#234", "234", " #234\n", "LABEL", " "] {
      XCTAssertTrue(issue.matchesSearch(query), query)
    }
    for query in ["#23", "23", "#2340", "#", "#0", "#-234", "unrelated"] {
      XCTAssertFalse(issue.matchesSearch(query), query)
    }
  }
  func testRelatedCaptureDoesNotCreateAnIssueOrChangeChat() {
    var state = StoreSnapshot()
    var issue = Issue(projectID: UUID(), title: "Button", capture: capture())
    issue.threadID = "thr_abc"
    issue.status = .working
    issue.coveredRevision = 1
    issue.add(capture())
    state.issues = [issue]
    XCTAssertEqual(state.activeCount, 1)
    XCTAssertEqual(issue.threadID, "thr_abc")
    XCTAssertEqual(issue.revision, 2)
    XCTAssertEqual(issue.coveredRevision, 1)
    XCTAssertEqual(issue.status, .working)
  }
  func testReopeningMergedIssueKeepsChatAndStartsFreshWorkspace() {
    var issue = Issue(projectID: UUID(), title: "Button", capture: capture())
    let old = issue.workspaceID
    issue.threadID = "thr"
    issue.status = .merged
    issue.prURL = "https://github.com/a/b/pull/1"
    issue.worktreePath = "/tmp/old"
    issue.add(capture())
    XCTAssertEqual(issue.threadID, "thr")
    XCTAssertNotEqual(issue.workspaceID, old)
    XCTAssertNil(issue.prURL)
    XCTAssertNil(issue.worktreePath)
    XCTAssertEqual(issue.status, .queued)
  }
  func testBadgeCountsExcludeDraftsMergedArchivedAndCanceled() {
    var snapshot = StoreSnapshot()
    for status in IssueStatus.allCases {
      var issue = Issue(projectID: UUID(), title: status.rawValue, capture: capture())
      issue.status = status
      snapshot.issues.append(issue)
    }
    XCTAssertEqual(snapshot.activeCount, 6)
    XCTAssertEqual(snapshot.attentionCount, 3)
    snapshot.issues[1].archived = true
    XCTAssertEqual(snapshot.activeCount, 5)
  }
  func testRoutingUsesHostPortAndPathBoundaries() {
    let checkout = Project(name: "Checkout", path: "/a", origins: ["http://localhost:3000/app"])
    let other = Project(name: "Other", path: "/b", origins: ["http://localhost:3001"])
    XCTAssertEqual(
      ProjectRouter.infer(
        CaptureContext(browserURL: "http://localhost:3000/app/pay"), projects: [checkout, other]
      ).projectID, checkout.id)
    XCTAssertNil(
      ProjectRouter.infer(
        CaptureContext(browserURL: "http://localhost:3000/apple"), projects: [checkout, other]
      ).projectID)
    XCTAssertNil(
      ProjectRouter.infer(
        CaptureContext(browserURL: "http://localhost.evil:3000/app"), projects: [checkout, other]
      ).projectID)
    XCTAssertEqual(
      ProjectRouter.infer(
        CaptureContext(browserURL: "http://localhost:3001"), projects: [checkout, other]
      ).projectID, other.id)
  }
  func testAmbiguousRoutingNeverDispatches() {
    let first = Project(name: "A", path: "/a", bundleIDs: ["test.app"])
    let second = Project(name: "B", path: "/b", bundleIDs: ["test.app"])
    XCTAssertNil(
      ProjectRouter.infer(CaptureContext(bundleID: "test.app"), projects: [first, second]).projectID
    )
    XCTAssertNil(
      ProjectRouter.infer(
        CaptureContext(bundleID: "com.apple.Safari"),
        projects: [Project(name: "Wrong", path: "/c", bundleIDs: ["com.apple.Safari"])]
      ).projectID)
  }
  func testRoutingFallsBackToAppNameAndLearnsTheChosenApp() {
    let genealogy = Project(name: "Genealogy", path: "/repos/Genealogy")
    let clip = Project(name: "Clip tool", path: "/repos/ScreenClip")
    let projects = [genealogy, clip]
    let capture = CaptureContext(appName: "Genealogy", bundleID: "com.example.Genealogy")
    let decision = ProjectRouter.infer(capture, projects: projects)
    XCTAssertEqual(decision.projectID, genealogy.id)
    XCTAssertEqual(decision.reason, "Matched app name")
    // The repository folder name also matches.
    XCTAssertEqual(
      ProjectRouter.infer(
        CaptureContext(appName: "ScreenClip", bundleID: "com.example.screenclip"), projects: projects
      ).projectID, clip.id)
    // A browser or an app another project claims never routes by name.
    XCTAssertNil(
      ProjectRouter.infer(
        CaptureContext(appName: "Genealogy", bundleID: "com.apple.Safari"), projects: projects
      ).projectID)
    let claimed = Project(name: "Other", path: "/o", bundleIDs: ["com.example.Genealogy"])
    XCTAssertEqual(
      ProjectRouter.infer(capture, projects: projects + [claimed]).projectID, claimed.id)
    XCTAssertEqual(
      ProjectRouter.identifierToLearn(from: capture, for: genealogy.id, projects: projects),
      "com.example.Genealogy")
    XCTAssertNil(
      ProjectRouter.identifierToLearn(from: capture, for: genealogy.id, projects: projects + [claimed]))
    XCTAssertNil(
      ProjectRouter.identifierToLearn(
        from: CaptureContext(bundleID: "com.google.Chrome"), for: genealogy.id, projects: projects))
    // Shared tools and less common browsers are never pinned to one project.
    for shared in [
      "com.apple.iphonesimulator", "com.apple.dt.Xcode", "com.apple.Terminal",
      "com.mirageteam.screenclip", "com.brave.Browser", "com.google.Chrome.canary",
    ] {
      XCTAssertNil(
        ProjectRouter.identifierToLearn(
          from: CaptureContext(bundleID: shared), for: genealogy.id, projects: projects), shared)
    }
  }
  func testMergeRejectsStaleRevisionsHeadsAndMissingValidation() {
    var e = MergeEvidence(
      expectedHead: "abc", currentHead: "abc", inputRevision: 2, coveredRevision: 2,
      validationPassed: true, hasValidation: true, checksPassed: true, mergeable: true,
      reviewSatisfied: true, unresolvedQuestions: false)
    XCTAssertTrue(e.canMerge)
    e.currentHead = "def"
    XCTAssertFalse(e.canMerge)
    e.currentHead = "abc"
    e.coveredRevision = 1
    XCTAssertFalse(e.canMerge)
    e.coveredRevision = 2
    e.hasValidation = false
    XCTAssertFalse(e.canMerge)
    e.hasValidation = true
    e.reviewSatisfied = false
    XCTAssertFalse(e.canMerge)
    e.reviewSatisfied = true
    e.unresolvedQuestions = true
    XCTAssertFalse(e.canMerge)
    e.unresolvedQuestions = false
    e.screenclipEvidenceCleared = false
    XCTAssertFalse(e.canMerge)
    e.screenclipEvidenceCleared = true
    XCTAssertTrue(e.canMerge)
  }
  func testPullRequestStateNeverTreatsNoChecksOrPendingAsPassing() throws {
    func state(_ check: String) throws -> PRState {
      PRState.parse(try JSONDecoder().decode(JSONValue.self, from: Data(check.utf8)))
    }
    XCTAssertFalse(try state("{\"statusCheckRollup\":[]}").checksPassed)
    XCTAssertFalse(
      try state("{\"statusCheckRollup\":[{\"status\":\"IN_PROGRESS\",\"conclusion\":\"\"}]}")
        .checksPassed)
    XCTAssertTrue(
      try state("{\"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"},{\"state\":\"SUCCESS\"}]}")
        .checksPassed)
    XCTAssertTrue(try state("{\"statusCheckRollup\":[{\"conclusion\":\"FAILURE\"}]}").checksFailed)
  }
  func testExportCopiesOnlyApprovedEvidence() throws {
    let store = try temporaryStore()
    let path = try store.writeAsset(Data([1]))
    let original = try store.writeAsset(Data([2]), original: true)
    var state = StoreSnapshot()
    state.issues = [
      Issue(
        projectID: nil, title: "test",
        capture: Capture(
          note: "hello", imagePath: path, originalPath: original, context: CaptureContext()))
    ]
    try store.save(state)
    let destination = store.root.appendingPathComponent("export")
    try store.export(to: destination)
    let exported = try JSONDecoder().decode(
      StoreSnapshot.self,
      from: Data(contentsOf: destination.appendingPathComponent("screenclip-export.json")))
    XCTAssertEqual(exported.issues[0].reportNumber, 1)
    XCTAssertEqual(exported.nextReportNumber, 2)
    XCTAssertNil(exported.issues[0].captures[0].originalPath)
    XCTAssertEqual(
      try Data(
        contentsOf: destination.appendingPathComponent(exported.issues[0].captures[0].imagePath)),
      Data([1]))
  }
  func testSecondWriterCannotDispatchTheSameQueue() throws {
    let store = try temporaryStore()
    try store.save(StoreSnapshot())
    XCTAssertThrowsError(try IssueStore(root: store.root))
    XCTAssertNoThrow(try IssueStore(root: store.root, readOnly: true).load())
  }
  func testShellArgumentsAreNotInterpolated() async throws {
    let result = try await CommandRunner.checked(
      "/usr/bin/printf", ["%s", "literal $(whoami) `echo bad`\nnext"])
    XCTAssertEqual(result, "literal $(whoami) `echo bad`\nnext")
  }
}
