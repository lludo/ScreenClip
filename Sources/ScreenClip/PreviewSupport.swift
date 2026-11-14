import ScreenClipCore
import SwiftUI

@MainActor enum PreviewSupport {
  static func exampleImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 800, height: 420))
    image.lockFocus()
    NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 800, height: 420).fill()
    func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
      value.draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
      ])
    }
    func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
      color.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    let ink = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.18, alpha: 1)
    let muted = NSColor(calibratedWhite: 0.43, alpha: 1)
    text("FIELD / NOTES", x: 48, y: 374, size: 15, weight: .bold, color: ink)
    text("Shop     Journal     About", x: 470, y: 374, size: 13, color: muted)
    text("Your order", x: 48, y: 316, size: 27, weight: .semibold, color: ink)
    text("Review the details before checkout.", x: 49, y: 292, size: 14, color: muted)
    NSColor.white.setFill()
    rounded(NSRect(x: 48, y: 66, width: 704, height: 204), radius: 15, color: .white)
    rounded(NSRect(x: 70, y: 150, width: 92, height: 92), radius: 10,
      color: NSColor(calibratedRed: 0.84, green: 0.87, blue: 0.81, alpha: 1))
    text("✦", x: 98, y: 175, size: 32, weight: .medium, color: ink)
    text("Everyday notebook", x: 182, y: 216, size: 17, weight: .semibold, color: ink)
    text("Moss green  ·  Set of 2", x: 182, y: 190, size: 13, color: muted)
    text("Qty 1", x: 182, y: 163, size: 13, color: muted)
    text("$48.00", x: 644, y: 216, size: 16, weight: .semibold, color: ink)
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    NSRect(x: 70, y: 134, width: 660, height: 1).fill()
    text("Total", x: 70, y: 99, size: 15, weight: .medium, color: ink)
    text("$48.00", x: 644, y: 99, size: 17, weight: .semibold, color: ink)
    rounded(NSRect(x: 488, y: 13, width: 264, height: 40), radius: 9,
      color: NSColor(calibratedRed: 0.19, green: 0.25, blue: 0.23, alpha: 1))
    text("Continue to checkout  →", x: 515, y: 25, size: 15, weight: .semibold, color: .white)
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
      projectID: project.id, title: "Checkout button needs more space",
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
    model.applyScreenshotAgentStatus()
    // Rendering uses a dedicated preview queue and never starts the worker.
    try model.commit { $0.settings.paused = false }
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
    let previewContext = CaptureContext(
      appName: "Safari", bundleID: "com.apple.Safari",
      browserURL: "https://field-notes.example/checkout")
    let previewCapture = Capture(
      note: "The checkout button is too close to the edge. Add a little breathing room.",
      imagePath: "preview", originalPath: "preview",
      annotations: [
        Annotation(kind: .rectangle, points: [MarkPoint(0.59, 0.865), MarkPoint(0.95, 0.985)],
          color: .red, lineWidth: 0.006),
        Annotation(kind: .arrow, points: [MarkPoint(0.48, 0.72), MarkPoint(0.62, 0.89)],
          color: .red, lineWidth: 0.006),
      ], context: previewContext)
    var previewDraft = Issue(
      projectID: model.snapshot.projects.first?.id, title: "Checkout button spacing",
      capture: previewCapture)
    previewDraft.status = .draft
    window.contentView = NSHostingView(
      rootView: ComposerView(
        model: model, image: exampleImage(), context: previewContext,
        existing: previewDraft, close: {}
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
