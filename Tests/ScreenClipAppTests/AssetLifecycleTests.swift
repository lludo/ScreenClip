import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class AssetLifecycleTests: XCTestCase {
  func testReplacingDraftRemovesSupersededImagesAndPreservesNewOnes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-draft-assets-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try model.submit(
      imageData: Data([1]), originalData: Data([2]), annotations: [], note: "Draft",
      context: CaptureContext(), projectID: nil, existingID: nil, draft: true)
    let draft = try XCTUnwrap(model.snapshot.issues.first)
    try model.submit(
      imageData: Data([3]), originalData: Data([4]), annotations: [], note: "Updated",
      context: CaptureContext(), projectID: nil, existingID: draft.id, draft: true)
    let capture = try XCTUnwrap(model.issue(draft.id)?.captures.first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(draft.captures[0].imagePath)))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try XCTUnwrap(draft.captures[0].originalPath)))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(capture.imagePath))), Data([3]))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(capture.originalPath))), Data([4]))
  }
  func testFailedOriginalImageWriteDoesNotLeaveAnApprovedImageBehind() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-failed-assets-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("originals"))
    XCTAssertThrowsError(
      try model.submit(
        imageData: Data([1]), originalData: Data([2]), annotations: [], note: "Draft",
        context: CaptureContext(), projectID: nil, existingID: nil, draft: true))
    XCTAssertTrue(model.snapshot.issues.isEmpty)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("assets").path
      ).isEmpty)
  }
}
