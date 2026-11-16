import XCTest
@testable import ScreenClipCore

final class PRScreenshotEvidenceTests: XCTestCase {
  // A real one-pixel PNG; invalid image data must never become a broken PR embed.
  let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII=")!

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

  func testMissingInvalidAndOldRevisionImagesCannotBePublished() async throws {
    let (root, issue) = try await fixture()
    do {
      try await PRScreenshotEvidence.prepare(issue: issue, worktree: root.path)
      XCTFail("Missing After must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Missing After")) }
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
    do {
      try await PRScreenshotEvidence.prepare(issue: next, worktree: root.path)
      XCTFail("Previous revision must not count as a retest")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Missing After")) }
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
