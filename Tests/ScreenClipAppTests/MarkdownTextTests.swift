import AppKit
import ScreenClipCore
import SwiftUI
import XCTest

@testable import ScreenClip

@MainActor final class MarkdownTextTests: XCTestCase {
  private let summary = """
    ## Report summaries render as Markdown

    The result card used `Text(verbatim:)`, so headings, **bold** and lists showed their raw syntax.

    **What changed**
    - Summaries go through Foundation's `AttributedString(markdown:)`.
      Inline code, *emphasis* and [links](https://example.com) keep their style.
    - Lists keep their markers:
      1. nested first
      2. nested second

    > Quoted notes are indented.

    ```
    bash scripts/test.sh
    ```

    3. Third
    4. Fourth

    | Check | Result |
    | --- | --- |
    | Tests | Pass |
    """

  func testBlocksFollowTheMarkdownStructure() {
    let blocks = MarkdownText.blocks(summary)
    let plain = blocks.map { String($0.text.characters) }
    XCTAssertEqual(blocks.first?.kind, .heading(2))
    XCTAssertEqual(plain.first, "Report summaries render as Markdown")
    XCTAssertFalse(plain.joined().contains("**"), "Emphasis markers must not be shown.")
    XCTAssertFalse(plain.joined().contains("`"), "Code markers must not be shown.")

    let first = try? XCTUnwrap(blocks.first { $0.text.characters.starts(with: "Summaries go") })
    XCTAssertEqual(first?.marker, "•")
    XCTAssertEqual(first?.depth, 0)
    XCTAssertTrue(first.map { String($0.text.characters).contains("Inline code, emphasis and links") } ?? false,
      "Soft line breaks stay inside the list item.")
    let nested = blocks.filter { $0.text.characters.starts(with: "nested") }
    XCTAssertEqual(nested.map(\.marker), ["1.", "2."])
    XCTAssertEqual(nested.map(\.depth), [1, 1])
    XCTAssertEqual(blocks.filter { ["Third", "Fourth"].contains(String($0.text.characters)) }.map(\.marker),
      ["3.", "4."])

    XCTAssertEqual(blocks.first { $0.quoted }.map { String($0.text.characters) }, "Quoted notes are indented.")
    let code = blocks.first { $0.kind == .code }
    XCTAssertEqual(code.map { String($0.text.characters) }, "bash scripts/test.sh")
    XCTAssertEqual(blocks.filter { $0.kind == .tableRow(header: true) }.count, 1)
    XCTAssertEqual(blocks.last.map { String($0.text.characters) }, "Tests   ·   Pass")
  }

  func testInlineStylesSurviveForText() throws {
    let block = try XCTUnwrap(MarkdownText.blocks("Use **bold** and `code`.").first)
    XCTAssertEqual(block.kind, .paragraph)
    let intents = block.text.runs.compactMap(\.inlinePresentationIntent)
    XCTAssertTrue(intents.contains(.stronglyEmphasized))
    XCTAssertTrue(intents.contains(.code))
  }

  func testSingleLineBreaksAreKept() {
    let blocks = MarkdownText.blocks("Changed:\nCartView.swift\nBadge.swift\n\n```\nlet a = 1\nlet b = 2\n```")
    XCTAssertEqual(blocks.map { String($0.text.characters) },
      ["Changed:\nCartView.swift\nBadge.swift", "let a = 1\nlet b = 2"])
    XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code])
  }

  func testPlainTextIsOneParagraph() {
    let blocks = MarkdownText.blocks("The order summary now stays visible.")
    XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    XCTAssertEqual(blocks.map(\.marker), [""])
  }

  /// Writes the report view with a Markdown summary. Set SCREENCLIP_RENDER_MARKDOWN to a directory.
  func testRenderSummaryInReport() throws {
    guard let directory = ProcessInfo.processInfo.environment["SCREENCLIP_RENDER_MARKDOWN"] else {
      throw XCTSkip("Set SCREENCLIP_RENDER_MARKDOWN to a directory to render a report summary.")
    }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "screenclip-markdown-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(root: root, recoverInterruptedWork: false)
    let project = Project(name: "ScreenClip", path: "/tmp/screenclip-markdown")
    var issue = Issue(
      projectID: project.id, title: "Report summaries show raw Markdown",
      capture: Capture(
        note: "This is Markdown but not rendered.", imagePath: nil,
        context: CaptureContext(appName: "ScreenClip", bundleID: "com.example.screenclip")))
    issue.status = .needsYou
    issue.threadID = "preview-thread"
    issue.resultSummary = summary
    try model.commit {
      $0.settings.paused = true
      $0.projects = [project]
      $0.issues = [issue]
    }
    let size = NSSize(width: 920, height: 1080)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(
      rootView: IssueDetailView(model: model, issue: issue).frame(width: size.width, height: size.height)
        .background(Color.white).preferredColorScheme(.light))
    window.orderFront(nil)
    window.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()
    // Match the 2x scale of the original capture whatever display the test runs on.
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: output.appendingPathComponent("report-summary.png"))
    window.close()
  }
}
