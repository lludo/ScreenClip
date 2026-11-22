import XCTest
@testable import ScreenClipCore

final class PRScreenshotEvidenceTests: XCTestCase {
  // A real one-pixel PNG; invalid image data must never become a broken PR embed.
  let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII=")!

  func testPrivateImageLookupIsScopedToTheReportAndThePublishedCommit() throws {
    let pr = try XCTUnwrap(URL(string: "https://github.com/example/app/pull/24"))
    let id = UUID()
    let head = String(repeating: "a", count: 40)
    let path = ".screenclip/pr/\(id.uuidString.lowercased())/revision-1/after/1.png"
    let image = "https://github.com/example/app/blob/\(head)/\(path)?raw=true"
    func endpoint(_ link: String) throws -> String? {
      PRScreenshotEvidence.contentsEndpoint(image: try XCTUnwrap(URL(string: link)), pullRequest: pr, issueID: id)
    }
    XCTAssertEqual(try endpoint(image)?.removingPercentEncoding, "repos/example/app/contents/\(path)?ref=\(head)")
    for (original, replacement) in [
      ("example/app", "example/another"), (head, "main"), (id.uuidString.lowercased(), UUID().uuidString),
      ("after/1.png", "notes.txt"), ("github.com", "example.org"),
    ] {
      XCTAssertNil(try endpoint(image.replacingOccurrences(of: original, with: replacement)))
    }
  }

  /// Evidence is prefetched and served locally, so the description never shows a broken image.
  func testRenderedDescriptionImagesArePointedAtPrefetchedEvidence() throws {
    let pr = try XCTUnwrap(URL(string: "https://github.com/example/app/pull/24"))
    let id = UUID()
    let head = String(repeating: "b", count: 40)
    let base = "https://github.com/example/app/blob/\(head)/.screenclip/pr/\(id.uuidString.lowercased())/revision-1"
    let html = """
      <p><a target="_blank" rel="noopener noreferrer" href="\(base)/before/1.png?raw=true"><img \
      src="\(base)/before/1.png?raw=true" alt="Before 1" style="max-width: 100%;"></a></p>
      <p><a href="\(base)/after/1.png?raw=true&amp;x=1"><img src="https://camo.githubusercontent.com/abc" \
      data-canonical-src="\(base)/after/1.png?raw=true" alt="After 1"></a></p>
      <p><img src="\(base)/after/1.png?raw=true" alt="Repeated"></p>
      <p><a href="\(base)/after/2.png"></a><img src="https://example.org/other.png" alt="Unrelated"></p>
      """
    let endpoints = PRScreenshotEvidence.imageEndpoints(html: html, pullRequest: pr, issueID: id)
    XCTAssertEqual(endpoints.map { $0.removingPercentEncoding?.components(separatedBy: "/revision-1/").last },
      ["before/1.png?ref=\(head)", "after/1.png?ref=\(head)"])
    let rewritten = PRScreenshotEvidence.replacingImageSources(html: html, pullRequest: pr, issueID: id) {
      $0 == endpoints[0] ? "local://0?a&b" : nil
    }
    XCTAssertTrue(rewritten.contains(#"<img src="local://0?a&amp;b" alt="Before 1""#))
    XCTAssertTrue(rewritten.contains(#"href="\#(base)/before/1.png?raw=true""#), "Links still open GitHub")
    XCTAssertTrue(rewritten.contains(#"<img src="https://camo.githubusercontent.com/abc""#))
    XCTAssertTrue(rewritten.contains(#"<img src="https://example.org/other.png""#))
    XCTAssertEqual(PRScreenshotEvidence.replacingImageSources(html: html, pullRequest: pr, issueID: UUID()) {
      _ in "local://never"
    }, html)
  }

  func fixture() async throws -> (URL, Issue) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-images-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await CommandRunner.checked(GitWorkspace.git, ["init", "-b", "main"], cwd: root.path)
    let approved = root.appendingPathComponent("approved.png")
    try image.write(to: approved)
    var issue = Issue(projectID: nil, title: "Clipped", capture: Capture(
      note: "", imagePath: approved.path, originalPath: "/must-not-be-read.png", context: CaptureContext()))
    issue.worktreePath = root.path
    return (root, issue)
  }

  /// Grok Bot's webhook names every capture, so an ignore rule must not leave one out of the
  /// evidence commit, and an ignored `.screenclip/` must not fail the hand-off.
  func testGrokBotEvidenceIsCommittedDespiteIgnoreRules() async throws {
    let (root, _) = try await fixture()
    for (key, value) in ["user.name": "ScreenClip Test", "user.email": "test@example.invalid"] {
      _ = try await CommandRunner.checked(GitWorkspace.git, ["config", key, value], cwd: root.path)
    }
    try ".screenclip/\n*.png\n".write(
      to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    let directory = root.appendingPathComponent(".screenclip/5")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try image.write(to: directory.appendingPathComponent("capture-1.png"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("report.json"))
    let head = try await GitHubService.commitEvidence(
      directory: ".screenclip/5", message: "Evidence", cwd: root.path)
    let committed = try await GitHubService.listScreenclipPaths(revision: head, cwd: root.path)
    XCTAssertEqual(committed.sorted(), [".screenclip/5/capture-1.png", ".screenclip/5/report.json"])
  }

  func testTextOnlyReportNeedsNoImagesAndMixedReportPublishesOnlyPhotos() async throws {
    let (root, original) = try await fixture()
    var issue = original
    issue.captures = [Capture(note: "Text only", imagePath: nil, context: CaptureContext())]
    try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
    XCTAssertEqual(try PRScreenshotEvidence.markdown(issue: issue, worktree: root.path, remote: "", head: ""), "")
    issue.add(original.captures[0])
    let folder = root.appendingPathComponent(PRScreenshotEvidence.directory(for: issue))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("after"), withIntermediateDirectories: true)
    try image.write(to: folder.appendingPathComponent("after/2.png"))
    try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
    let before = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("before").path)
    XCTAssertEqual(before, ["2.png"])
    let payload = ExternalAssistant.makePayload(issue: issue, project: Project(name: "Demo", path: root.path),
      repo: "owner/demo", branch: "demo", includePageContext: false, commit: nil)
    XCTAssertEqual(payload.notes.first, "Text only")
    XCTAssertEqual(payload.evidence.paths.filter { $0.hasSuffix(".png") }.count, 1)
  }

  func testImagesAreStagedDespiteIgnoreRulesAndUseImmutableLinks() async throws {
    let (root, issue) = try await fixture()
    try ".screenclip/\n*.png\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    let after = root.appendingPathComponent(PRScreenshotEvidence.directory(for: issue) + "/after")
    try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
    try image.write(to: after.appendingPathComponent("retest #1.png"))
    try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
    let before = root.appendingPathComponent(PRScreenshotEvidence.directory(for: issue) + "/before/1.png")
    XCTAssertEqual(try Data(contentsOf: before), image)
    let tracked = try await CommandRunner.checked(GitWorkspace.git, ["ls-files"], cwd: root.path)
    XCTAssertTrue(tracked.contains("before/1.png"))
    XCTAssertTrue(tracked.contains("after/retest #1.png"))
    let markdown = try PRScreenshotEvidence.markdown(issue: issue, worktree: root.path, remote: "git@github.com:owner/demo.git", head: "abc123")
    XCTAssertTrue(markdown.contains("![Before 1](https://github.com/owner/demo/blob/abc123/"))
    XCTAssertTrue(markdown.contains("![After 1]"))
    XCTAssertTrue(markdown.contains("retest%20%231.png?raw=true"))
    XCTAssertFalse(markdown.contains("/must-not-be-read"))
    XCTAssertFalse(markdown.contains(root.path))
  }

  func testMissingAfterPublishesBeforeImagesWithANote() async throws {
    let (root, issue) = try await fixture()
    try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
    let tracked = try await CommandRunner.checked(GitWorkspace.git, ["ls-files"], cwd: root.path)
    XCTAssertTrue(tracked.contains("before/1.png"))
    XCTAssertFalse(tracked.contains("/after/"))
    let markdown = try PRScreenshotEvidence.markdown(issue: issue, worktree: root.path, remote: "git@github.com:owner/demo.git", head: "abc123")
    XCTAssertTrue(markdown.contains("![Before 1]"))
    XCTAssertFalse(markdown.contains("![After"))
    XCTAssertTrue(markdown.contains(PRScreenshotEvidence.missingAfterNote))
  }

  func testInvalidAndOldRevisionImagesCannotBePublished() async throws {
    let (root, issue) = try await fixture()
    let after = root.appendingPathComponent(PRScreenshotEvidence.directory(for: issue) + "/after")
    try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
    let file = after.appendingPathComponent("1.png")
    try Data("not a PNG".utf8).write(to: file)
    do {
      try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
      XCTFail("Invalid PNG must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid PNG")) }
    try image.write(to: file)
    var next = issue
    next.revision += 1
    try await PRScreenshotEvidence.prepare(issue: next, worktree: root.path)
    let markdown = try PRScreenshotEvidence.markdown(issue: next, worktree: root.path, remote: "git@github.com:owner/demo.git", head: "abc123")
    XCTAssertFalse(markdown.contains("![After"), "Previous revision must not count as a retest")
    XCTAssertTrue(markdown.contains(PRScreenshotEvidence.missingAfterNote))
  }

  func testEvidenceFolderSymlinksAreRejected() async throws {
    let (root, issue) = try await fixture()
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".screenclip"), withDestinationURL: root)
    do {
      try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
      XCTFail("Symlink must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("symbolic links")) }
  }
}
