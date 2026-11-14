import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import ScreenClipCore

@MainActor final class CaptureCoordinator {
  unowned let model: AppModel
  private var windows: [NSWindow] = []
  private var lastExternalApp: NSRunningApplication?
  private var activationObserver: NSObjectProtocol?
  private var permissionObservers: [NSObjectProtocol] = []
  private var recheckOnReturn = false
  init(model: AppModel) {
    self.model = model
    lastExternalApp = NSWorkspace.shared.frontmostApplication
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier != Bundle.main.bundleIdentifier
      else { return }
      Task { @MainActor in self?.lastExternalApp = app }
    }
    permissionObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.recheckOnReturn = self.model.capturePermission.state == .blocked
        }
      })
    permissionObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.recheckOnReturn else { return }
          self.recheckOnReturn = false
          await self.model.recheckCapturePermission()
        }
      })
  }
  func begin(sourceOverride: NSRunningApplication? = nil) {
    guard !model.captureBusy else { return }
    model.captureBusy = true
    model.captureDiagnostics.record("capture.shortcut")
    let hideScreenClip = model.snapshot.settings.shouldHideScreenClipDuringCapture
    let source =
      sourceOverride
      ?? NSWorkspace.shared.frontmostApplication.flatMap {
        $0.bundleIdentifier == Bundle.main.bundleIdentifier && hideScreenClip ? lastExternalApp : $0
      }
    var context = CaptureContext(
      appName: source?.localizedName ?? "", bundleID: source?.bundleIdentifier ?? "",
      sessionName: model.snapshot.settings.sessionName,
      testedVersion: model.snapshot.settings.testedVersion)
    if model.snapshot.settings.browserContext {
      context.browserURL = Self.browserURL(bundleID: context.bundleID)
    }
    Task { [self] in
      do {
        let content = try await model.capturePermission.obtain {
          try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        context.windowTitle =
          content.windows.first {
            $0.owningApplication?.processID == source?.processIdentifier && $0.windowLayer == 0
          }?.title
        let ownWindows =
          hideScreenClip
          ? content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
          } : []
        model.captureDiagnostics.record(
          "capture.visibility", ["hideScreenClip": String(hideScreenClip)])
        var backdrops: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
          guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
              as? NSNumber,
            let display = content.displays.first(where: { $0.displayID == number.uint32Value })
          else { continue }
          let config = SCStreamConfiguration()
          config.width = Int(screen.frame.width * screen.backingScaleFactor)
          config.height = Int(screen.frame.height * screen.backingScaleFactor)
          config.showsCursor = false
          config.captureResolution = .best
          let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: ownWindows),
            configuration: config)
          backdrops.append((screen, image))
        }
        guard !backdrops.isEmpty else {
          throw ScreenClipError.message("No display is available for capture.")
        }
        let decision = ProjectRouter.infer(context, projects: model.snapshot.projects)
        context.routingReason = decision.reason
        if model.capturePermissionIssue {
          model.banner = nil
          model.capturePermissionIssue = false
        }
        model.captureDiagnostics.record(
          "capture.overlay.presenting", ["displays": String(backdrops.count)])
        for (screen, image) in backdrops {
          let window = SelectionWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false,
            screen: screen)
          window.level = .screenSaver
          window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
          window.isReleasedWhenClosed = false
          let view = SelectionView(image: image, screen: screen)
          view.onCancel = { [weak self] in
            self?.model.captureDiagnostics.record("capture.cancelled")
            self?.end()
            source?.activate(options: [])
          }
          view.onSelect = { [weak self] rect in
            guard let self else { return }
            let sx = Double(image.width) / screen.frame.width
            let sy = Double(image.height) / screen.frame.height
            let cropRect = CGRect(
              x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy
            ).integral
            guard let crop = image.cropping(to: cropRect) else {
              self.model.captureDiagnostics.record("capture.crop.failed")
              self.end()
              return
            }
            var captured = context
            captured.scale = sx
            captured.selection = [
              screen.frame.minX + rect.minX, screen.frame.maxY - rect.maxY, rect.width, rect.height,
            ]
            self.end()
            self.model.captureDiagnostics.record(
              "capture.selected", ["width": String(crop.width), "height": String(crop.height)])
            self.model.composerAction?(
              NSImage(cgImage: crop, size: NSSize(width: rect.width, height: rect.height)),
              captured, nil)
          }
          window.contentView = view
          windows.append(window)
          window.makeKeyAndOrderFront(nil)
          window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
      } catch {
        end()
        model.banner = model.capturePermission.report(error)
        model.capturePermissionIssue = [.blocked, .needsRestart].contains(
          model.capturePermission.state)
        model.captureDiagnostics.record("capture.aborted", ["message": model.banner ?? "unknown"])
        model.queueAction?()
      }
    }
  }
  private func end() {
    windows.forEach {
      $0.orderOut(nil)
      $0.close()
    }
    windows = []
    model.captureBusy = false
  }
  private static func browserURL(bundleID: String) -> String? {
    let line: String
    switch bundleID {
    case "com.apple.Safari":
      line = "tell application id \"com.apple.Safari\" to get URL of front document"
    case "com.google.Chrome":
      line = "tell application id \"com.google.Chrome\" to get URL of active tab of front window"
    default: return nil
    }
    var error: NSDictionary?
    let result = NSAppleScript(source: "with timeout of 2 seconds\n\(line)\nend timeout")?
      .executeAndReturnError(&error).stringValue
    guard error == nil, let result, ["http", "https"].contains(URL(string: result)?.scheme ?? "")
    else { return nil }
    return result
  }
}
private final class SelectionWindow: NSWindow { override var canBecomeKey: Bool { true } }
private final class SelectionView: NSView {
  let image: CGImage
  let display: NSScreen
  var start: CGPoint?
  var selected = CGRect.zero
  var onSelect: ((CGRect) -> Void)?
  var onCancel: (() -> Void)?
  init(image: CGImage, screen: NSScreen) {
    self.image = image
    display = screen
    super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
  override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }
  override func mouseDown(with event: NSEvent) {
    start = convert(event.locationInWindow, from: nil)
    selected = .zero
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start else { return }
    let end = convert(event.locationInWindow, from: nil)
    selected = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    ).intersection(bounds)
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    if selected.width > 3 && selected.height > 3 { onSelect?(selected) }
  }
  override func draw(_ dirtyRect: NSRect) {
    let picture = NSImage(cgImage: image, size: bounds.size)
    picture.draw(
      in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    NSColor.black.withAlphaComponent(0.40).setFill()
    bounds.fill()
    if !selected.isEmpty {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: selected).addClip()
      picture.draw(
        in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
      NSColor.white.setStroke()
      let border = NSBezierPath(rect: selected)
      border.lineWidth = 1
      border.stroke()
      let label = "\(Int(selected.width)) × \(Int(selected.height))"
      label.draw(
        at: CGPoint(x: selected.minX + 5, y: max(5, selected.minY - 23)),
        withAttributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
          .foregroundColor: NSColor.white,
        ])
    } else {
      let text = "Drag to capture a region   ·   Esc to cancel"
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white,
      ]
      let size = text.size(withAttributes: attrs)
      text.draw(
        at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2), withAttributes: attrs
      )
    }
  }
}

@MainActor final class GlobalShortcut {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  var action: (() -> Void)?
  init() {
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, data in
        guard let data else { return OSStatus(eventNotHandledErr) }
        let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue()
        Task { @MainActor in shortcut.action?() }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
  func register(key: UInt32, modifiers: UInt32) -> Bool {
    if let reference { UnregisterEventHotKey(reference) }
    return RegisterEventHotKey(
      key, modifiers, EventHotKeyID(signature: 0x5343_4C50, id: 1), GetApplicationEventTarget(), 0,
      &reference) == noErr
  }
  deinit {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
  }
}
