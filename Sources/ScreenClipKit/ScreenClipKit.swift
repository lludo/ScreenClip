import Foundation

/// What opens the ScreenClip report sheet.
public enum ScreenClipTrigger: Hashable, Sendable {
  /// Shaking the device. The SDK chains to any existing shake handling, so other tools keep
  /// receiving the gesture. Leave this out if your app already uses shake for something else.
  case shake
  /// After a system screenshot, a small banner offers to report the screen.
  case screenshot
}

public struct ScreenClipOptions: Sendable {
  public var triggers: Set<ScreenClipTrigger>
  /// Also keep the last lines your app prints to stdout and stderr (`print`) and attach them to
  /// reports as `console.txt`. Output still reaches Xcode's console. Off by default because it
  /// redirects the process's standard output.
  public var captureConsoleOutput: Bool
  public init(triggers: Set<ScreenClipTrigger> = [.shake, .screenshot], captureConsoleOutput: Bool = false) {
    self.triggers = triggers
    self.captureConsoleOutput = captureConsoleOutput
  }
}

#if os(iOS) && DEBUG
  import UIKit

  /// ScreenClip for iOS: report what you see in your own app, straight into ScreenClip on your Mac.
  ///
  /// ```swift
  /// #if DEBUG
  /// ScreenClipKit.start()
  /// #endif
  /// ```
  /// The SDK compiles to an empty stub outside Debug builds.
  @MainActor public enum ScreenClipKit {
    /// Starts ScreenClip. Later calls update the triggers. Once enabled, console capture lasts for the process lifetime.
    public static func start(_ options: ScreenClipOptions = ScreenClipOptions()) {
      KitRuntime.shared.start(options)
    }
    public static func start(triggers: Set<ScreenClipTrigger>) {
      start(ScreenClipOptions(triggers: triggers))
    }
    /// Opens the report sheet now, for example from your own debug menu.
    public static func capture() { KitRuntime.shared.capture() }
    /// Opens ScreenClip settings: Mac pairing, saved reports, and triggers.
    public static func showSettings() { KitRuntime.shared.showSettings() }
    /// Adds your app's own files to every report: state, records, anything an agent would want
    /// to see next to the screenshot.
    ///
    /// ```swift
    /// ScreenClipKit.setAttachmentProvider("cart") { context in
    ///   let cart = await MainActor.run { CartStore.shared.snapshot }
    ///   return [try .json(cart, name: "cart", summary: "the cart's \(cart.items.count) items and promo codes")]
    /// }
    /// ```
    /// The provider starts when the report sheet opens and runs while the tester annotates, off
    /// the main actor. After the tester taps Send, ScreenClip waits up to `timeout` more (at most
    /// 30 seconds), then sends the report without whatever hasn't arrived. It is cancelled when
    /// the tester cancels or turns off **Attach logs and diagnostics**. Registering the same `id`
    /// again replaces the provider, so calling this more than once is safe.
    public static func setAttachmentProvider(
      _ id: String, timeout: Duration = .seconds(5), _ provider: @escaping ScreenClipAttachmentProvider
    ) {
      KitRuntime.shared.attachments.set(id, timeout: timeout, provider: provider)
    }
    /// Stops adding the files from the provider registered with `id`.
    public static func removeAttachmentProvider(_ id: String) { KitRuntime.shared.attachments.remove(id) }
    /// True in builds where the SDK is active.
    public static var isActive: Bool { true }
  }
#else
  /// Outside Debug builds ScreenClipKit does nothing and contains no capture or network code.
  @MainActor public enum ScreenClipKit {
    public static func start(_ options: ScreenClipOptions = ScreenClipOptions()) {}
    public static func start(triggers: Set<ScreenClipTrigger>) {}
    public static func capture() {}
    public static func showSettings() {}
    public static func setAttachmentProvider(
      _ id: String, timeout: Duration = .seconds(5), _ provider: @escaping ScreenClipAttachmentProvider
    ) {}
    public static func removeAttachmentProvider(_ id: String) {}
    public static var isActive: Bool { false }
  }
#endif
