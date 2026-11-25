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
  var donationWindow: NSWindow?
  private var donationOptOutOnClose = false
  var observation: Any?
  var timer: Timer?
  var integrationTimer: Timer?
  var previewMode = false
  var screenshotMode = false
  var screenshotLocale = Locale.current
  private var deferredOpenURLs: [URL] = []
  /// Windows taken off screen for a capture; they come back when the capture flow ends.
  private var hiddenForCapture: [NSWindow] = []
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Child processes (agents, git, validation) can exit before reading what ScreenClip writes.
    ProcessEnvironment.ignoreBrokenPipes()
    NSApp.setActivationPolicy(.accessory)
    do {
      let arguments = ProcessInfo.processInfo.arguments
      let integration =
        arguments.contains("--integration-run") || arguments.contains("--integration-project-link")
      previewMode = integration || arguments.contains("--preview") || arguments.contains("--render-preview")
      screenshotMode = arguments.contains("--screenshot-fixture")
      if let localeFlag = arguments.firstIndex(of: "--locale"), arguments.indices.contains(localeFlag + 1) {
        screenshotLocale = Locale(identifier: arguments[localeFlag + 1])
      }
      let override = arguments.firstIndex(of: "--data-dir").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      guard !integration || override != nil else {
        throw ScreenClipError.message("Integration checks require an explicit fresh --data-dir.")
      }
      let root: URL
      if screenshotMode {
        root = try ScreenshotFixture.materialize()
      } else {
        root =
          override.map { URL(fileURLWithPath: $0) }
          ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("ScreenClip")
      }
      guard !integration || !FileManager.default.fileExists(atPath: root.path) else {
        throw ScreenClipError.message("Choose a new --data-dir for the integration check.")
      }
      model = try AppModel(root: root, recoverInterruptedWork: !screenshotMode)
      if !screenshotMode && !previewMode {
        // Agents launch the copy in the data folder; keep it in step with this build.
        AgentMCPSetup.refreshInstalledServer(
          from: Bundle.main.url(forResource: "server", withExtension: "py"), dataFolder: root)
      }
      if screenshotMode { ScreenshotFixture.configure(model) }
      capture = CaptureCoordinator(model: model)
      capture.onAbandon = { [weak self] in self?.restoreHiddenWindows() }
      shortcut = GlobalShortcut()
      model.captureAction = { [weak self] in self?.startCapture() }
      model.textCaptureAction = { [weak self] in self?.startCapture(textOnly: true) }
      model.queueAction = { [weak self] in self?.showQueue() }
      model.settingsAction = { [weak self] in self?.showSettings() }
      model.relaunchAction = { [weak self] in self?.relaunch() }
      model.supportAction = { [weak self] in self?.showDonationPrompt() }
      model.composerAction = { [weak self] image, context, existing in
        self?.showComposer(image: image, context: context, existing: existing)
      }
      shortcut.action = { [weak self] in self?.startCapture() }
      if !previewMode && !screenshotMode { registerShortcut() }
      UNUserNotificationCenter.current().delegate = self
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      statusItem.button?.target = self
      statusItem.button?.action = #selector(togglePopover)
      popover.contentViewController = NSHostingController(rootView: rooted(MenuPopover(model: model)))
      popover.behavior = .transient
      popover.contentSize = NSSize(width: 460, height: 480)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshBadge() }
      }
      observation = NotificationCenter.default.addObserver(
        forName: .screenClipSettingsChanged, object: nil, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.registerShortcut() } }
      refreshBadge()
      if integration {
        try runIntegration(arguments: arguments, root: root)
        return
      }
      if arguments.contains("--render-preview") {
        try PreviewSupport.render(model: model, root: root)
        NSApp.terminate(nil)
        return
      }
      if screenshotMode {
        showQueue()
        if arguments.contains("--show-popover") {
          // Keep the real popover visible when the screenshot tool takes focus.
          popover.behavior = .applicationDefined
          // The status item gets its window after the application finishes launching.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.togglePopover() }
        }
        return
      }
      if previewMode { try PreviewSupport.seed(model: model) } else {
        model.worker.start()
        Updater.shared.start()
        model.startSleepGuard()
        model.startIOSServerIfEnabled()
      }
      if arguments.contains("--recover-reports") {
        Task { @MainActor [self] in
          let reports = model.snapshot.issues.filter {
            [.needsYou, .failed].contains($0.status) && !$0.archived
          }
          for report in reports {
            await model.worker.reconcile(report.id)
            if let current = model.issue(report.id), current.status == .needsYou,
              !current.dispatchUncertain, current.questions.allSatisfy({ $0.reply != nil }),
              current.lastError == nil, model.banner == nil
            {
              model.retry(report.id)
            }
          }
        }
      }
      if model.snapshot.projects.isEmpty || previewMode || arguments.contains("--show-queue") {
        showQueue()
      }
      if !previewMode {
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          self.presentDonationPromptIfNeeded()
        }
      }
      if !deferredOpenURLs.isEmpty {
        let pending = deferredOpenURLs
        deferredOpenURLs.removeAll()
        openLinkedURLs(pending)
      }
    } catch {
      let alert = NSAlert()
      alert.messageText = Chrome.text(
        "ScreenClip could not open its queue", comment: "Alert when the local queue cannot be opened.")
      alert.informativeText = Chrome.stored(error.localizedDescription, locale: .current)
      alert.addButton(withTitle: Chrome.text("Quit", locale: .current, comment: "Quits after a startup failure."))
      alert.runModal()
      NSApp.terminate(nil)
    }
  }
  func registerShortcut() {
    let settings = model.snapshot.settings
    if shortcut.register(key: settings.shortcutKey, modifiers: settings.shortcutModifiers) {
      workingShortcut = (settings.shortcutKey, settings.shortcutModifiers, settings.shortcutDescription)
      return
    }
    // The previous shortcut is still registered. Put it back in Settings, so the shortcut shown
    // is the one that works and the next launch does not start without one.
    if let working = workingShortcut,
      (working.key, working.modifiers) != (settings.shortcutKey, settings.shortcutModifiers)
    {
      var restored = settings
      restored.shortcutKey = working.key
      restored.shortcutModifiers = working.modifiers
      restored.shortcutDescription = working.description
      model.saveSettings(restored)
    }
    model.banner = "That keyboard shortcut is already in use. Choose another in Settings."
  }
  private var workingShortcut: (key: UInt32, modifiers: UInt32, description: String)?
  func relaunch() {
    guard composerWindow == nil else {
      // A banner alone is invisible when the queue window is closed.
      model.banner = "Save your capture as a draft before reopening ScreenClip."
      composerBlocks(Chrome.text(
        "Save your capture as a draft before reopening ScreenClip.",
        comment: "Alert when reopening the app is refused because a capture is open. Keep ScreenClip."))
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
    guard model != nil else {
      deferredOpenURLs.append(contentsOf: urls)
      return
    }
    openLinkedURLs(urls)
  }
  func openLinkedURLs(_ urls: [URL]) {
    // Report files exported or AirDropped from ScreenClipKit on iOS.
    let reportFiles = urls.filter { $0.isFileURL && $0.pathExtension == ReportFile.pathExtension }
    if !reportFiles.isEmpty, model.importIOSReportFiles(reportFiles) > 0 { showQueue() }
    for url in urls where !url.isFileURL {
      switch ScreenClipURL.route(url) {
      case .issue(let id):
        guard model.issue(id) != nil else { continue }
        model.selectedIssueID = id
        showQueue()
      case .issueAction(let id, let action, let token):
        // Report ids are public in pull requests; only a link made on this Mac carries the token.
        guard let expected = try? ScreenClipURL.linkToken(dataFolder: model.store.root),
          token == expected
        else { continue }
        Task { await model.runLinkedAction(action, on: id) }
      case .connect(let code):
        model.grokConnectRequest = GrokConnectRequest(code: code)
        showSettings()
      case nil:
        continue
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
    let projectLinkOnly = arguments.contains("--integration-project-link")
    guard
      projectLinkOnly
        || URL(fileURLWithPath: repo).lastPathComponent.hasPrefix("screenclip-integration-")
    else {
      throw ScreenClipError.message("Use a dedicated screenclip-integration-* fixture.")
    }
    guard model.snapshot.issues.isEmpty && model.snapshot.projects.isEmpty else {
      throw ScreenClipError.message("Use a fresh data directory for the integration run.")
    }
    let project = Project(
      name: projectLinkOnly
        ? URL(fileURLWithPath: repo).lastPathComponent : "ScreenClip integration fixture",
      path: repo, validationCommand: projectLinkOnly ? "" : "python3 -m unittest",
      autoMerge: !projectLinkOnly)
    try model.saveProject(project)
    try model.commit { $0.settings.paused = false }
    let context = CaptureContext(
      appName: "Synthetic test screenshot", sessionName: "Native end-to-end test",
      testedVersion: "Fixture initial commit")
    try model.submit(
      imageData: Data(contentsOf: URL(fileURLWithPath: imagePath)), originalData: nil,
      annotations: [],
      note:
        projectLinkOnly
        ? "Synthetic project-link verification. There is no bug or code change requested. Ask whether this test observation can be closed. Do not modify repository files."
        : "Synthetic integration bug: the Complete purchase button in style.css is clipped at 80px. Change the purchase-button width to 240px so the label fits. Preserve the existing padding. The regression in test_layout.py defines the desired behavior.",
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
    // The same rules as the queue sidebar and the popover, so the badge never disagrees with them.
    let active = model.snapshot.issues.filter { QueueFilter.active.includes($0) }.count
    let attention = model.snapshot.issues.filter { QueueFilter.attention.includes($0) }.count
    statusItem.button?.image = NSImage(
      systemSymbolName: "viewfinder", accessibilityDescription: "ScreenClip")
    let count = active.formatted(.number)
    statusItem.button?.title = active > 0 ? " \(count)\(attention > 0 ? " •" : "")" : ""
    let open = Chrome.format(
      "tooltip.open", "\(active) open", comment: "Menu bar tooltip. %lld is the open count.")
    let needs = Chrome.format(
      "tooltip.attention", "\(attention) need attention",
      comment: "Menu bar tooltip. %lld is how many reports need attention.")
    statusItem.button?.toolTip = "ScreenClip: \(open), \(needs)"
  }
  @objc func togglePopover() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = statusItem.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }
  func startCapture(textOnly: Bool = false) {
    if let composerWindow {
      composerWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let hideScreenClip = model.snapshot.settings.shouldHideScreenClipDuringCapture
    let sourceOverride = !hideScreenClip && popover.isShown ? NSRunningApplication.current : nil
    if textOnly {
      popover.performClose(nil)
      // A text note has nothing to capture; credit the app the tester was in, not ScreenClip.
      capture.beginText(sourceOverride: nil)
      return
    }
    if hideScreenClip {
      popover.performClose(nil)
      for window in [queueWindow, settingsWindow, donationWindow].compactMap({ $0 })
      where window.isVisible {
        window.orderOut(nil)
        hiddenForCapture.append(window)
      }
    }
    capture.begin(sourceOverride: sourceOverride)
  }
  /// Brings back what `startCapture` hid, without taking focus from the app being tested.
  func restoreHiddenWindows() {
    let windows = hiddenForCapture
    hiddenForCapture = []
    windows.forEach { $0.orderFront(nil) }
  }
  private func shownByUser(_ window: NSWindow?) {
    hiddenForCapture.removeAll { $0 === window }
  }
  private func composerBlocks(_ message: String) {
    guard let composerWindow else { return }
    composerWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = message
    alert.beginSheetModal(for: composerWindow)
  }
  func showQueue() {
    popover.performClose(nil)
    if queueWindow == nil {
      let window = makeWindow(
        title: previewMode
          ? Chrome.text("ScreenClip · Preview", comment: "Window title for the seeded preview queue.")
          : "ScreenClip", view: rooted(QueueView(model: model)),
        size: NSSize(width: 1180, height: 760))
      window.setFrameAutosaveName("ScreenClipQueue")
      queueWindow = window
    }
    shownByUser(queueWindow)
    queueWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showSettings() {
    popover.performClose(nil)
    // Reopening starts from the saved settings rather than a stale or abandoned form. A window
    // that was only hidden for a capture keeps its unsaved edits.
    if let window = settingsWindow, !window.isVisible,
      !hiddenForCapture.contains(where: { $0 === window })
    {
      window.contentViewController = NSHostingController(
        rootView: rooted(SettingsView(model: model) { [weak self] in self?.settingsWindow?.close() }))
    }
    if settingsWindow == nil {
      settingsWindow = makeWindow(
        title: Chrome.text("Settings", comment: "Settings window title."),
        view: rooted(SettingsView(model: model) { [weak self] in
          self?.settingsWindow?.close()
        }),
        size: NSSize(width: 780, height: 720))
      settingsWindow?.toolbarStyle = .unified
    }
    shownByUser(settingsWindow)
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func presentDonationPromptIfNeeded() {
    #if !SCREENCLIP_APP_STORE
    guard !previewMode, model.shouldShowDonationPrompt() else { return }
    showDonationPrompt()
    #endif
  }
  func showDonationPrompt() {
    #if !SCREENCLIP_APP_STORE
    if donationWindow == nil {
      let view = DonationPromptView(
        notNow: { [weak self] in self?.donationWindow?.close() },
        dontAskAgain: { [weak self] in
          self?.donationOptOutOnClose = true
          self?.model.optOutOfDonationPrompt()
          self?.donationWindow?.close()
        })
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: NSSize(width: 440, height: 280)),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = Chrome.text("Support ScreenClip", comment: "Tip window title. Keep ScreenClip.")
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentViewController = NSHostingController(rootView: rooted(view))
      window.center()
      donationWindow = window
    }
    donationOptOutOnClose = false
    shownByUser(donationWindow)
    donationWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    #endif
  }
  func showComposer(image: NSImage?, context: CaptureContext, existing: Issue?) {
    if let composerWindow {
      composerWindow.makeKeyAndOrderFront(nil)
      return
    }
    let view = ComposerView(model: model, image: image, context: context, existing: existing) {
      [weak self] in
      guard let self else { return }
      self.composerWindow?.orderOut(nil)
      self.composerWindow = nil
      self.restoreHiddenWindows()
      if !context.bundleID.isEmpty {
        NSRunningApplication.runningApplications(withBundleIdentifier: context.bundleID).first?
          .activate(options: [])
      }
    }
    composerWindow = makeWindow(
      title: Chrome.text("New observation", comment: "Capture composer window title."),
      view: rooted(view), size: NSSize(width: 860, height: image == nil ? 380 : 720))
    composerWindow?.level = .floating
    composerWindow?.delegate = self
    composerWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === donationWindow else { return }
    donationWindow = nil
    if donationOptOutOnClose {
      donationOptOutOnClose = false
      return
    }
    model.snoozeDonationPrompt()
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === composerWindow else { return true }
    let alert = NSAlert()
    alert.messageText = Chrome.text("Keep this capture?", comment: "Asked when closing an unsaved capture.")
    alert.informativeText = Chrome.text(
      "Use Save draft in the capture window to keep your work.",
      comment: "Explains how to keep an unsaved capture.")
    alert.addButton(withTitle: Chrome.text("Keep editing", comment: "Returns to the capture."))
    alert.addButton(withTitle: Chrome.text("Discard", comment: "Closes the capture without saving."))
    if alert.runModal() == .alertSecondButtonReturn {
      composerWindow = nil
      restoreHiddenWindows()
      return true
    }
    return false
  }
  func rooted<V: View>(_ view: V) -> some View {
    view.environment(\.locale, screenshotMode ? screenshotLocale : .current)
      .environment(\.timeZone, screenshotMode ? ScreenshotFixture.timeZone : .current)
  }
  func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = title
    window.toolbarStyle = .unifiedCompact
    window.titlebarAppearsTransparent = false
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
    if composerWindow != nil {
      // A banner alone is invisible when the queue window is closed.
      model.banner = "Save this capture as a draft or discard it before quitting ScreenClip."
      composerBlocks(Chrome.text(
        "Save this capture as a draft or discard it before quitting ScreenClip.",
        comment: "Alert when quitting is refused because a capture is open. Keep ScreenClip."))
      return .terminateCancel
    }
    if model?.snapshot.issues.contains(where: { $0.status == .working }) == true {
      let alert = NSAlert()
      alert.messageText = Chrome.text(
        "Quit while work is running?", comment: "Asked when quitting during agent work.")
      alert.informativeText = Chrome.text(
        "The local worker will stop. Your captures are saved. Claude Code work continues when you reopen ScreenClip; reconcile Codex chats then.",
        comment: "Explains that quitting stops local work. Keep Claude Code and Codex.")
      alert.addButton(withTitle: Chrome.text("Keep running", comment: "Cancels quitting."))
      alert.addButton(withTitle: Chrome.text("Quit", comment: "Quits even though work is running."))
      if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
    }
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    // Agent progress is saved within a second; save the last of it before quitting.
    model?.flushPendingSave()
    if !previewMode { ClaudeCodeClient.terminateAllForQuit() }
  }
}
