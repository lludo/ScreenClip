import AppKit
import ScreenClipCore
import XCTest

@testable import ScreenClip

@MainActor final class QueueLayoutTests: XCTestCase {
  func testEmptyQueueFillsWindowAndReservesFooterAtNormalAndMinimumSizes() async throws {
    try checkLayout(projectCount: 2, withReports: false)
  }

  func testPopulatedQueueFillsWindowAndReservesFooterWithScrollingProjects() async throws {
    try checkLayout(projectCount: 30, withReports: true)
  }

  private func checkLayout(projectCount: Int, withReports: Bool) throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-queue-layout-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root)
    if withReports { try PreviewSupport.seed(model: model) }
    try model.commit {
      $0.projects = (0..<projectCount).map {
        Project(name: "Project \($0)", path: "/tmp/screenclip-layout-\($0)")
      }
      $0.settings.paused = true
    }
    let window = AppDelegate().makeWindow(
      title: "ScreenClip layout test", view: QueueView(model: model),
      size: NSSize(width: 1180, height: 760))
    defer { window.close() }
    window.orderFront(nil)

    for size in [NSSize(width: 1180, height: 760), NSSize(width: 1000, height: 640)] {
      window.setContentSize(size)
      window.display()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let content = try XCTUnwrap(window.contentView)
      content.layoutSubtreeIfNeeded()
      let split = try XCTUnwrap(descendant(NSSplitView.self, in: content))
      let workspace = content.convert(split.bounds, from: split)
      XCTAssertEqual(workspace.minY, content.bounds.minY, accuracy: 1)
      XCTAssertEqual(workspace.maxY, content.bounds.maxY, accuracy: 1)
      XCTAssertEqual(workspace.width, content.bounds.width, accuracy: 1)
      XCTAssertEqual(split.arrangedSubviews.count, 3)

      let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
      let scroll = try XCTUnwrap(descendant(NSScrollView.self, in: sidebar))
      let listFrame = content.convert(scroll.bounds, from: scroll)
      let top = content.isFlipped ? listFrame.minY : listFrame.maxY
      let contentTop = content.isFlipped ? content.bounds.minY : content.bounds.maxY
      let footerHeight = content.isFlipped
        ? content.bounds.maxY - listFrame.maxY : listFrame.minY - content.bounds.minY
      XCTAssertEqual(top, contentTop, accuracy: 1)
      XCTAssertGreaterThanOrEqual(
        footerHeight, 50,
        "The scrolling project list must leave room for the connection and processing controls.")
      XCTAssertGreaterThan(listFrame.height, 400)
    }
  }

  private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
  }
}
