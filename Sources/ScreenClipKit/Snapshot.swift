#if os(iOS) && DEBUG
  import ScreenClipWire
  import SwiftUI
  import UIKit

  @MainActor struct Snapshot {
    let image: UIImage
    let cornerRadii: RectangleCornerRadii

    static func activeScene() -> UIWindowScene? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.first { $0.activationState == .foregroundActive }
        ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// The app's windows in the scene, composited bottom to top, without ScreenClip's own.
    static func capture(in scene: UIWindowScene, excluding: [UIWindow]) -> Snapshot? {
      let windows = scene.windows
        .filter { window in !window.isHidden && window.alpha > 0 && !excluding.contains(where: { $0 === window }) }
        .sorted { $0.windowLevel < $1.windowLevel }
      let bounds = scene.coordinateSpace.bounds
      guard !windows.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
      let format = UIGraphicsImageRendererFormat()
      format.scale = scene.screen.scale
      format.opaque = true
      let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
        UIColor.black.setFill()
        context.fill(bounds)
        for window in windows {
          // drawHierarchy can decline (it returns false, leaving nothing drawn), for example
          // right after accessibility settings change. Retry with a fresh frame, then fall
          // back to rendering the layer tree.
          if window.drawHierarchy(in: window.frame, afterScreenUpdates: false) { continue }
          kitLog.debug("drawHierarchy declined for \(String(describing: type(of: window)), privacy: .public); retrying")
          if window.drawHierarchy(in: window.frame, afterScreenUpdates: true) { continue }
          context.cgContext.saveGState()
          context.cgContext.translateBy(x: window.frame.minX, y: window.frame.minY)
          window.layer.render(in: context.cgContext)
          context.cgContext.restoreGState()
        }
      }
      return Snapshot(image: image, cornerRadii: sceneCornerRadii(in: scene))
    }

    private static func sceneCornerRadii(in scene: UIWindowScene) -> RectangleCornerRadii {
      #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
          // A hidden window fills this scene and resolves its container corners without
          // changing the host window or making another window key.
          let window = UIWindow(windowScene: scene)
          window.cornerConfiguration = .corners(radius: .containerConcentric())
          window.layoutIfNeeded()
          return RectangleCornerRadii(
            topLeading: window.effectiveRadius(corner: .topLeft),
            bottomLeading: window.effectiveRadius(corner: .bottomLeft),
            bottomTrailing: window.effectiveRadius(corner: .bottomRight),
            topTrailing: window.effectiveRadius(corner: .topRight))
        }
      #endif
      return RectangleCornerRadii()
    }

    /// The app's main window in the scene: the key window unless it is ScreenClip's own.
    static func appWindow(in scene: UIWindowScene, excluding ours: [UIWindow]) -> UIWindow? {
      let candidates = scene.windows.filter { window in !window.isHidden && !ours.contains(where: { $0 === window }) }
      return candidates.first(where: \.isKeyWindow) ?? candidates.first { $0.windowLevel == .normal }
    }

    /// True when an alert or another tool's overlay is on screen, so a shake does not stack a
    /// second sheet on top of it. Keyboard windows do not count.
    static func anotherOverlayIsShowing(in scene: UIWindowScene, ignoring ours: [UIWindow]) -> Bool {
      for window in scene.windows where !window.isHidden && !ours.contains(where: { $0 === window }) {
        let name = String(describing: type(of: window))
        if name.contains("Keyboard") || name.contains("TextEffects") { continue }
        if window.windowLevel > .normal, window.rootViewController != nil { return true }
        if topViewController(window.rootViewController) is UIAlertController { return true }
      }
      return false
    }

    static func topViewController(_ root: UIViewController?) -> UIViewController? {
      var current = root
      while let presented = current?.presentedViewController, !presented.isBeingDismissed {
        current = presented
      }
      return current
    }
  }

  @MainActor enum DeviceInfo {
    static func context(scene: UIWindowScene) -> DeviceContext {
      let info = Bundle.main.infoDictionary ?? [:]
      let device = UIDevice.current
      let bounds = scene.coordinateSpace.bounds
      let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        ?? scene.windows.first?.rootViewController
      let (path, title) = screenPath(from: root)
      return DeviceContext(
        platform: device.systemName, deviceModel: modelIdentifier(), deviceName: device.name,
        osVersion: device.systemVersion,
        appName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "",
        bundleID: Bundle.main.bundleIdentifier ?? "",
        appVersion: info["CFBundleShortVersionString"] as? String ?? "",
        build: info["CFBundleVersion"] as? String ?? "",
        gitSHA: info["ScreenClipGitSHA"] as? String, locale: Locale.current.identifier,
        screenWidth: bounds.width, screenHeight: bounds.height, screenScale: scene.screen.scale,
        orientation: orientationName(scene.interfaceOrientation), screenPath: path, screenTitle: title)
    }

    static func modelIdentifier() -> String {
      if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
        return "\(simulated) (Simulator)"
      }
      var system = utsname()
      uname(&system)
      return withUnsafeBytes(of: &system.machine) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
    }

    static func orientationName(_ orientation: UIInterfaceOrientation) -> String {
      switch orientation {
      case .portrait: return "portrait"
      case .portraitUpsideDown: return "portraitUpsideDown"
      case .landscapeLeft: return "landscapeLeft"
      case .landscapeRight: return "landscapeRight"
      default: return "unknown"
      }
    }

    /// The chain of visible view controllers, outermost first, and the innermost title.
    static func screenPath(from root: UIViewController?) -> ([String], String?) {
      var names: [String] = []
      var title: String?
      var current = root
      var depth = 0
      while let controller = current, depth < 24 {
        depth += 1
        names.append(typeName(controller))
        if let text = controller.navigationItem.title ?? controller.title, !text.isEmpty { title = text }
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
          current = presented
        } else if let navigation = controller as? UINavigationController {
          current = navigation.topViewController
        } else if let tabs = controller as? UITabBarController {
          current = tabs.selectedViewController
        } else if let split = controller as? UISplitViewController {
          current = split.viewControllers.last
        } else {
          current = controller.children.last { $0.isViewLoaded && $0.view.window != nil && !$0.view.isHidden }
        }
      }
      return (names, title)
    }

    /// `UIHostingController<ContentView>` stays readable; long generic SwiftUI types are cut.
    static func typeName(_ controller: UIViewController) -> String {
      let name = String(describing: type(of: controller))
      guard name.count > 60, let bracket = name.firstIndex(of: "<") else { return name }
      return String(name[..<bracket]) + "<…>"
    }
  }
#endif
