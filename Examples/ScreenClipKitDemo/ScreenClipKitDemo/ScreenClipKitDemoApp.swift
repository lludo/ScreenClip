import SwiftUI

#if DEBUG
  import ScreenClipKit
#endif

@main
struct ScreenClipKitDemoApp: App {
  init() {
    #if DEBUG
      // `-captureConsole` also attaches recent print() output to reports.
      ScreenClipKit.start(
        ScreenClipOptions(captureConsoleOutput: ProcessInfo.processInfo.arguments.contains("-captureConsole")))
      Self.simulateShakeIfAsked()
      // Your own files on every report: here, a little app state as JSON.
      let launchedAt = ProcessInfo.processInfo.systemUptime
      ScreenClipKit.setAttachmentProvider("session") { context in
        struct Session: Encodable {
          var reportID: UUID
          var screen: String?
          var launchArguments: [String]
          var secondsSinceLaunch: Int
        }
        let session = Session(
          reportID: context.reportID, screen: context.screenTitle,
          launchArguments: Array(ProcessInfo.processInfo.arguments.dropFirst()),
          secondsSinceLaunch: Int(ProcessInfo.processInfo.systemUptime - launchedAt))
        return [try .json(session, name: "session", summary: "demo session state and launch arguments")]
      }
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
