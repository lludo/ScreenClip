import ScreenClipCore
import SwiftUI
import XCTest

@testable import ScreenClip

/// Renders fixed fixture data for every supported locale. Set SCREENCLIP_RENDER_LOCALIZATIONS=1.
@MainActor final class LocalizationSnapshotTests: XCTestCase {
  private let locales = [
    "en", "zh-Hans", "es", "ja", "pt-BR", "de", "fr", "ko", "ru", "zh-Hant",
  ]

  func testRenderLocalizationScreenshots() async throws {
    guard ProcessInfo.processInfo.environment["SCREENCLIP_RENDER_LOCALIZATIONS"] == "1" else {
      throw XCTSkip("Set SCREENCLIP_RENDER_LOCALIZATIONS=1 to write locale screenshots.")
    }
    _ = NSApplication.shared
    let root = try ScreenshotFixture.materialize()
    let model = try AppModel(root: root, recoverInterruptedWork: false)
    ScreenshotFixture.configure(model)
    let output = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("build/localization-screenshots")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var written: [URL] = []
    for identifier in locales {
      for dark in [false, true] {
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        let suffix = "\(identifier)-\(dark ? "dark" : "light")"
        written.append(try render(
          QueueView(model: model), name: "main-\(suffix)", size: NSSize(width: 1180, height: 760),
          locale: identifier, appearance: appearance, output: output))
        if let issue = model.snapshot.issues.first(where: { $0.status == .needsYou }) {
          written.append(try render(
            IssueDetailView(model: model, issue: issue), name: "report-\(suffix)",
            size: NSSize(width: 760, height: 900), locale: identifier, appearance: appearance,
            output: output))
        }
        written.append(try render(
          MenuPopover(model: model), name: "menu-\(suffix)", size: NSSize(width: 460, height: 640),
          locale: identifier, appearance: appearance, output: output))
        written.append(try render(
          SettingsView(model: model, close: {}, initialTab: 0), name: "settings-\(suffix)",
          size: NSSize(width: 780, height: 720), locale: identifier, appearance: appearance,
          output: output))
        written.append(try render(
          GrokConnectSheet(model: model, initialCode: nil, projectID: nil, onSaved: {}),
          name: "connect-grok-\(suffix)", size: NSSize(width: 720, height: 860),
          locale: identifier, appearance: appearance, output: output))
      }
    }
    try writeContactSheet(urls: written, to: output.appendingPathComponent("contact-sheet.png"))
    XCTAssertEqual(written.count, locales.count * 2 * 5)
  }

  private func render<V: View>(
    _ view: V, name: String, size: NSSize, locale: String, appearance: NSAppearance.Name,
    output: URL
  ) throws -> URL {
    let themed = view.environment(\.locale, Locale(identifier: locale))
      .environment(\.timeZone, ScreenshotFixture.timeZone)
      .preferredColorScheme(appearance == .darkAqua ? .dark : .light)
      .frame(width: size.width, height: size.height)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = NSHostingView(rootView: themed)
    window.orderFront(nil)
    window.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()
    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw XCTSkip("This environment cannot snapshot AppKit views.")
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let destination = output.appendingPathComponent("\(name).png")
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    window.close()
    return destination
  }

  private func writeContactSheet(urls: [URL], to destination: URL) throws {
    let columns = 5
    let thumb = NSSize(width: 280, height: 180)
    let rows = Int(ceil(Double(urls.count) / Double(columns)))
    let canvas = NSImage(size: NSSize(width: thumb.width * CGFloat(columns), height: thumb.height * CGFloat(rows)))
    canvas.lockFocus()
    NSColor.black.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()
    for (index, url) in urls.enumerated() {
      guard let image = NSImage(contentsOf: url) else { continue }
      let column = index % columns
      let row = rows - 1 - index / columns
      let rect = NSRect(
        x: CGFloat(column) * thumb.width, y: CGFloat(row) * thumb.height, width: thumb.width - 8,
        height: thumb.height - 22)
      image.draw(in: rect)
      (url.deletingPathExtension().lastPathComponent as NSString).draw(
        at: NSPoint(x: rect.minX, y: rect.maxY + 2),
        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
    }
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return }
    try png.write(to: destination)
  }
}
