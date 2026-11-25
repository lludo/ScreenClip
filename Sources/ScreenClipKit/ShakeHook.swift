#if os(iOS) && DEBUG
  import ObjectiveC
  import UIKit

  /// Observes shake gestures without taking them over.
  ///
  /// The hook wraps whatever `-[UIWindow motionEnded:withEvent:]` currently does and calls it
  /// first, so the app's own handling, the system shake-to-undo, and other debugging tools that
  /// hook the same method keep working. Tools that install the same kind of hook later chain to
  /// this one. If a view in the app consumes the shake without calling `super`, the window never
  /// sees it; use `ScreenClipKit.capture()` or the screenshot trigger then.
  enum ShakeHook {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    nonisolated(unsafe) private static var installed = false

    static func install(_ action: @escaping () -> Void) {
      handler = action
      guard !installed else { return }
      installed = true
      let cls: AnyClass = UIWindow.self
      let selector = #selector(UIResponder.motionEnded(_:with:))
      guard let method = class_getInstanceMethod(cls, selector) else { return }
      typealias Implementation = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
      let previous = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
      let block: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = {
        receiver, motion, event in
        previous(receiver, selector, motion, event)
        guard motion == .motionShake else { return }
        DispatchQueue.main.async { handler?() }
      }
      let implementation = imp_implementationWithBlock(block)
      // UIWindow usually inherits the method from UIResponder: add an override that calls the
      // inherited one. If UIWindow (or an earlier hook) defines it, replace and chain instead.
      if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
        method_setImplementation(method, implementation)
      }
    }
  }
#endif
