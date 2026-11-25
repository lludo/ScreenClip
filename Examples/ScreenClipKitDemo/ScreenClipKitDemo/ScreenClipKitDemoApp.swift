import SwiftUI

#if DEBUG
  import ScreenClipKit
#endif

@main
struct ScreenClipKitDemoApp: App {
  init() {
    #if DEBUG
      ScreenClipKit.start()
      Self.simulateShakeIfAsked()
    #endif
  }

  #if DEBUG
    /// `-simulateShakeAfter 6` sends a shake to the key window after 6 seconds, the same event a
    /// real shake delivers, for testing in a headless simulator.
    static func simulateShakeIfAsked() {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-simulateShakeAfter"), index + 1 < arguments.count,
        let seconds = Double(arguments[index + 1])
      else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .flatMap(\.windows).first(where: \.isKeyWindow)
        window?.motionEnded(.motionShake, with: nil)
      }
    }
  #endif

  var body: some Scene {
    WindowGroup { ContentView() }
  }
}
