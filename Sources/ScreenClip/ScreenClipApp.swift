import AppKit
import ScreenClipCore
import SwiftUI
import UserNotifications

@main struct ScreenClipApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  var body: some Scene { Settings { EmptyView() } }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate,
  NSWindowDelegate
{
  var model: AppModel!
  var capture: CaptureCoordinator!
  var shortcut: GlobalShortcut!
  var statusItem: NSStatusItem!
  let popover = NSPopover()
  var queueWindow: NSWindow?
  var settingsWindow: NSWindow?
  var composerWindow: NSWindow?
  var observation: Any?
  var timer: Timer?
  var integrationTimer: Timer?
  var previewMode = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    do {
      let arguments = ProcessInfo.processInfo.arguments
      previewMode =
        arguments.contains("--preview") || arguments.contains("--render-preview")
        || arguments.contains("--integration-run")
      let override = arguments.firstIndex(of: "--data-dir").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      let root =
        override.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenClip")
      model = try AppModel(root: root)
      capture = CaptureCoordinator(model: model)
      shortcut = GlobalShortcut()
      model.captureAction = { [weak self] in self?.startCapture() }
      model.queueAction = { [weak self] in self?.showQueue() }
      model.settingsAction = { [weak self] in self?.showSettings() }
      model.relaunchAction = { [weak self] in self?.relaunch() }
      model.composerAction = { [weak self] image, context, existing in
        self?.showComposer(image: image, context: context, existing: existing)
      }
      shortcut.action = { [weak self] in self?.startCapture() }
      registerShortcut()
      UNUserNotificationCenter.current().delegate = self
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      statusItem.button?.target = self
      statusItem.button?.action = #selector(togglePopover)
      popover.contentViewController = NSHostingController(rootView: MenuPopover(model: model))
      popover.behavior = .transient
      popover.contentSize = NSSize(width: 370, height: 440)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshBadge() }
      }
      observation = NotificationCenter.default.addObserver(
        forName: .screenClipSettingsChanged, object: nil, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.registerShortcut() } }
      refreshBadge()
      if arguments.contains("--integration-run") {
        try runIntegration(arguments: arguments, root: root)
        return
      }
      if arguments.contains("--render-preview") {
        try PreviewSupport.render(model: model, root: root)
        NSApp.terminate(nil)
        return
      }
      if previewMode { try PreviewSupport.seed(model: model) } else { model.worker.start() }
      if model.snapshot.projects.isEmpty || previewMode || arguments.contains("--show-queue") {
        showQueue()
      }
    } catch {
      let alert = NSAlert()
      alert.messageText = "ScreenClip could not open its queue"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "Quit")
      alert.runModal()
      NSApp.terminate(nil)
    }
  }
  func registerShortcut() {
    if !shortcut.register(
      key: model.snapshot.settings.shortcutKey, modifiers: model.snapshot.settings.shortcutModifiers
    ) {
      model.banner = "That keyboard shortcut is already in use. Choose another in Settings."
    }
  }
  func relaunch() {
    guard composerWindow == nil else {
      model.banner = "Save your capture as a draft before reopening ScreenClip."
      return
    }
    guard !model.snapshot.issues.contains(where: { $0.status == .working }) else {
      model.banner = "Finish or cancel active work before reopening ScreenClip."
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\" --args --data-dir \"$3\" --show-queue",
      "screenclip-relaunch", String(ProcessInfo.processInfo.processIdentifier),
      Bundle.main.bundleURL.path, model.store.root.path,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      NSApp.terminate(nil)
    } catch { model.banner = error.localizedDescription }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == "screenclip" && url.host == "issues" {
      if let id = UUID(uuidString: url.lastPathComponent), model?.issue(id) != nil {
        model.selectedIssueID = id
        showQueue()
      }
    }
  }
  func runIntegration(arguments: [String], root: URL) throws {
    func option(_ flag: String) throws -> String {
      guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else {
        throw ScreenClipError.message("Missing integration option: " + flag)
      }
      return arguments[i + 1]
    }
    let repo = try option("--integration-repo")
    let imagePath = try option("--integration-image")
    guard URL(fileURLWithPath: repo).lastPathComponent.hasPrefix("screenclip-integration-") else {
      throw ScreenClipError.message("Use a dedicated screenclip-integration-* fixture.")
    }
    guard model.snapshot.issues.isEmpty else {
      throw ScreenClipError.message("Use a fresh data directory for the integration run.")
    }
    let project = Project(
      name: "ScreenClip integration fixture", path: repo, validationCommand: "python3 -m unittest",
      autoMerge: true)
    try model.saveProject(project)
    try model.commit { $0.settings.paused = false }
    let context = CaptureContext(
      appName: "Synthetic test screenshot", sessionName: "Native end-to-end test",
      testedVersion: "Fixture initial commit")
    try model.submit(
      imageData: Data(contentsOf: URL(fileURLWithPath: imagePath)), originalData: nil,
      annotations: [],
      note:
        "Synthetic integration bug: the Complete purchase button in style.css is clipped at 80px. Change the purchase-button width to 240px so the label fits. Preserve the existing padding. The regression in test_layout.py defines the desired behavior.",
      context: context, projectID: project.id, existingID: nil, draft: false)
    model.worker.start()
    var previous = ""
    let deadline = Date().addingTimeInterval(600)
    integrationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let issue = self.model.snapshot.issues.first else { return }
        if issue.status.rawValue != previous {
          previous = issue.status.rawValue
          print("Integration: \(issue.status.title)")
          fflush(stdout)
        }
        if [.merged, .failed, .needsYou].contains(issue.status) || Date() > deadline {
          try? JSONEncoder().encode(issue).write(
            to: root.appendingPathComponent("integration-result.json"), options: .atomic)
          if let url = issue.prURL { print("PR: \(url)") }
          if let error = issue.lastError { print("Details: \(error)") }
          print("Thread: \(issue.threadID ?? "none")")
          fflush(stdout)
          self.integrationTimer?.invalidate()
          NSApp.terminate(nil)
        }
      }
    }
  }
  func refreshBadge() {
    statusItem.button?.image = NSImage(
      systemSymbolName: "viewfinder", accessibilityDescription: "ScreenClip")
    statusItem.button?.title =
      model.snapshot.activeCount > 0
      ? " \(model.snapshot.activeCount)\(model.snapshot.attentionCount > 0 ? " •" : "")" : ""
    statusItem.button?.toolTip =
      "ScreenClip: \(model.snapshot.activeCount) open, \(model.snapshot.attentionCount) need attention"
  }
  @objc func togglePopover() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = statusItem.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }
  func startCapture() {
    if let composerWindow {
      composerWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    popover.performClose(nil)
    queueWindow?.orderOut(nil)
    settingsWindow?.orderOut(nil)
    capture.begin()
  }
  func showQueue() {
    popover.performClose(nil)
    if queueWindow == nil {
      let window = makeWindow(
        title: previewMode ? "ScreenClip · Preview" : "ScreenClip", view: QueueView(model: model),
        size: NSSize(width: 1180, height: 760))
      window.setFrameAutosaveName("ScreenClipQueue")
      queueWindow = window
    }
    queueWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showSettings() {
    popover.performClose(nil)
    if settingsWindow == nil {
      settingsWindow = makeWindow(
        title: "ScreenClip Settings", view: SettingsView(model: model),
        size: NSSize(width: 700, height: 590))
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showComposer(image: NSImage, context: CaptureContext, existing: Issue?) {
    if let composerWindow {
      composerWindow.makeKeyAndOrderFront(nil)
      return
    }
    let view = ComposerView(model: model, image: image, context: context, existing: existing) {
      [weak self] in
      guard let self else { return }
      self.composerWindow?.orderOut(nil)
      self.composerWindow = nil
      if !context.bundleID.isEmpty {
        NSRunningApplication.runningApplications(withBundleIdentifier: context.bundleID).first?
          .activate(options: [])
      }
    }
    composerWindow = makeWindow(
      title: "New observation", view: view, size: NSSize(width: 780, height: 690))
    composerWindow?.level = .floating
    composerWindow?.delegate = self
    composerWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === composerWindow else { return true }
    let alert = NSAlert()
    alert.messageText = "Keep this capture?"
    alert.informativeText = "Use Save draft in the capture window to keep your work."
    alert.addButton(withTitle: "Keep editing")
    alert.addButton(withTitle: "Discard")
    if alert.runModal() == .alertSecondButtonReturn {
      composerWindow = nil
      return true
    }
    return false
  }
  func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = title
    window.isReleasedWhenClosed = false
    window.center()
    window.contentViewController = NSHostingController(rootView: view)
    return window
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = (response.notification.request.content.userInfo["issueID"] as? String).flatMap(
      UUID.init(uuidString:))
    Task { @MainActor in
      if let id { self.model.selectedIssueID = id }
      self.showQueue()
      completionHandler()
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if previewMode { return .terminateNow }
    if model?.snapshot.issues.contains(where: { $0.status == .working }) == true {
      let alert = NSAlert()
      alert.messageText = "Quit while work is running?"
      alert.informativeText =
        "The local worker will stop. Your captures are saved; reconcile the existing chats when you reopen ScreenClip."
      alert.addButton(withTitle: "Keep running")
      alert.addButton(withTitle: "Quit")
      if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
    }
    return .terminateNow
  }
}
struct MenuPopover: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("ScreenClip", systemImage: "viewfinder").font(.headline)
        Spacer()
        if model.snapshot.settings.paused {
          Text("Paused").font(.caption).foregroundStyle(.secondary)
        }
        Button {
          model.settingsAction?()
        } label: {
          Image(systemName: "gearshape")
        }.buttonStyle(.plain)
      }
      HStack(spacing: 25) {
        metric("Open", model.snapshot.activeCount)
        metric("Needs you", model.snapshot.attentionCount)
        metric(
          "To retest", model.snapshot.issues.filter { $0.status == .merged && !$0.archived }.count)
      }
      Button {
        model.captureAction?()
      } label: {
        HStack {
          Label("New capture", systemImage: "plus")
          Spacer()
          Text(model.snapshot.settings.shortcutDescription).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
      }.buttonStyle(.borderedProminent).tint(.orange)
      Divider()
      if model.snapshot.issues.isEmpty {
        Text("Your observations will appear here.").font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 110)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(Array(model.snapshot.issues.filter { !$0.archived }.suffix(5).reversed())) {
              issue in
              Button {
                model.selectedIssueID = issue.id
                model.queueAction?()
              } label: {
                IssueRow(issue: issue, project: model.project(issue.projectID))
              }.buttonStyle(.plain)
              Divider()
            }
          }
        }.frame(maxHeight: 245)
      }
      HStack {
        Button("Open queue") { model.queueAction?() }
        Spacer()
        Button(model.snapshot.settings.paused ? "Resume" : "Pause") {
          model.perform { try model.commit { $0.settings.paused.toggle() } }
          model.worker.pump()
        }
        Menu {
          Button("Quit ScreenClip") { NSApp.terminate(nil) }
        } label: {
          Image(systemName: "ellipsis")
        }.menuStyle(.borderlessButton).frame(width: 22)
      }
    }.padding(20).frame(width: 370)
  }
  func metric(_ title: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
  }
}
