import ScreenClipCore
import SwiftUI

@MainActor enum PreviewSupport {
  static func exampleImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 800, height: 420))
    image.lockFocus()
    NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 800, height: 420).fill()
    let card = NSRect(x: 70, y: 55, width: 660, height: 310)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 20, yRadius: 20).fill()
    "Order summary".draw(
      at: NSPoint(x: 105, y: 300),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black,
      ])
    "Your next adventure starts here.".draw(
      at: NSPoint(x: 105, y: 255),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.secondaryLabelColor,
      ])
    NSColor(calibratedRed: 0.94, green: 0.39, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 105, y: 110, width: 290, height: 56), xRadius: 12, yRadius: 12
    ).fill()
    "Complete purchase".draw(
      at: NSPoint(x: 135, y: 128),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white,
      ])
    "Total          $48.00".draw(
      at: NSPoint(x: 490, y: 128),
      withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .medium),
        .foregroundColor: NSColor.black,
      ])
    image.unlockFocus()
    return image
  }
  static func seed(model: AppModel) throws {
    guard model.snapshot.issues.isEmpty else { return }
    let project = Project(
      name: "Demo storefront", path: "/tmp/screenclip-preview", origins: ["http://localhost:3000"],
      validationCommand: "npm test")
    let image = try AnnotationRenderer.png(
      image: exampleImage(),
      marks: [Annotation(kind: .arrow, points: [MarkPoint(0.58, 0.33), MarkPoint(0.45, 0.65)])])
    let asset = try model.store.writeAsset(image)
    let context = CaptureContext(
      appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Checkout · Demo",
      browserURL: "http://localhost:3000/checkout", sessionName: "Checkout on a narrow window",
      testedVersion: "Preview build", routingReason: "Matched website rule")
    var first = Issue(
      projectID: project.id, title: "Button label is clipped at this width",
      capture: Capture(
        note: "The purchase button needs a little more breathing room on small windows.",
        imagePath: asset, context: context))
    first.status = .working
    first.record("Checking the button's responsive layout")
    var second = Issue(
      projectID: project.id, title: "Should the total include shipping?",
      capture: Capture(
        note: "The total looks different from the previous step.", imagePath: asset,
        context: context))
    second.status = .needsYou
    second.questions = [
      PendingQuestion(
        title: "Should shipping be included in the total before the address is entered?")
    ]
    second.unread = true
    var third = Issue(
      projectID: project.id, title: "Keep the order summary visible",
      capture: Capture(
        note: "The summary disappears when I move to payment.", imagePath: asset, context: context))
    third.status = .merged
    third.resultSummary =
      "The order summary now stays visible through the payment step. Rebuild the app to retest."
    try model.commit {
      $0.settings.paused = true
      $0.projects = [project]
      $0.issues = [first, second, third]
    }
    model.selectedIssueID = second.id
  }
  static func render(model: AppModel, root: URL) throws {
    try seed(model: model)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: QueueView(model: model).background(Color.white).preferredColorScheme(.light))
    window.center()
    window.orderFront(nil)
    window.display()
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    guard let view = window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { throw ScreenClipError.message("Could not render preview") }
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])?.write(
      to: root.appendingPathComponent("queue-preview.png"))
    if let project = model.snapshot.projects.first {
      window.contentView = NSHostingView(
        rootView: QueueView(model: model, selection: .project(project.id))
          .background(Color.white).preferredColorScheme(.light))
      window.display()
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      if let view = window.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: root.appendingPathComponent("project-settings-preview.png"))
      }
      window.contentView = NSHostingView(
        rootView: QueueView(model: model, projectFilter: project.id, agentFilter: .codex)
          .background(Color.white).preferredColorScheme(.light))
      window.display()
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      if let view = window.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: root.appendingPathComponent("queue-filtered-preview.png"))
      }
    }
    let test = try AnnotationRenderer.png(
      image: exampleImage(),
      marks: [Annotation(kind: .redact, points: [MarkPoint(0.1, 0.1), MarkPoint(0.3, 0.25)])])
    try test.write(to: root.appendingPathComponent("redaction-preview.png"))
    window.contentView = NSHostingView(
      rootView: ComposerView(
        model: model, image: exampleImage(),
        context: CaptureContext(
          appName: "Safari", bundleID: "com.apple.Safari",
          browserURL: "http://localhost:3000/checkout"), existing: nil, close: {}
      ).background(Color.white).preferredColorScheme(.light))
    window.setContentSize(NSSize(width: 780, height: 690))
    window.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    if let view = window.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: root.appendingPathComponent("composer-preview.png"))
    }
    window.contentView = NSHostingView(
      rootView: SettingsView(model: model, close: {}).background(Color.white).preferredColorScheme(.light))
    window.setContentSize(NSSize(width: 700, height: 590))
    window.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    if let view = window.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: root.appendingPathComponent("settings-preview.png"))
    }
    window.setContentSize(NSSize(width: 370, height: 440))
    for scheme in [ColorScheme.light, .dark] {
      window.contentView = NSHostingView(
        rootView: MenuPopover(model: model)
          .background(scheme == .light ? Color(white: 0.97) : Color(white: 0.13))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .preferredColorScheme(scheme))
      window.display()
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      if let view = window.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: root.appendingPathComponent("menu-\(scheme == .light ? "light" : "dark")-preview.png"))
      }
    }
    window.orderOut(nil)
  }
}
