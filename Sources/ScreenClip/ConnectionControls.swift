import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct ScreenCapturePermissionControls: View {
  @ObservedObject var model: AppModel
  @ObservedObject var permission: ScreenCapturePermission
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        permission.message,
        systemImage: permission.state == .available ? "checkmark.circle" : "viewfinder"
      ).font(.caption).foregroundStyle(permission.state == .available ? .green : .secondary)
      HStack {
        Button("Check screen access") { Task { await model.recheckCapturePermission() } }.disabled(
          permission.state == .checking)
        if permission.state != .available {
          Button("Open System Settings") { model.openCaptureSettings() }
          Button("Reopen app") { model.relaunchAction?() }
        }
      }
    }
  }
}
struct CodexConnectionControls: View {
  @ObservedObject var model: AppModel
  @ObservedObject var authentication: CodexAuthentication
  let choose: () -> Void
  let check: () -> Void
  let signIn: (CodexAuthentication.Method) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button("Choose…", action: choose)
        Button("Check connection", action: check).disabled(authentication.state == .checking)
        Button("Sign in…") { signIn(.browser) }.disabled(
          authentication.state == .checking || authentication.state == .ready
            || authentication.loginID != nil)
        if authentication.state != .ready {
          Menu("Other sign-in options") {
            Button("Sign in with a code…") { signIn(.deviceCode) }
            Button("Try browser sign-in again…") { signIn(.browser) }
          }.disabled(authentication.state == .checking)
        }
        if authentication.state == .checking { ProgressView().controlSize(.small) }
      }
      Text(model.connection).font(.caption).foregroundStyle(statusColor).textSelection(.enabled)
      if let description = authentication.accountDescription {
        Text(description).font(.caption).foregroundStyle(.secondary)
      }
      if authentication.loginID != nil {
        if let code = authentication.userCode {
          HStack {
            Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
            Button("Copy code") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code, forType: .string)
            }
          }
          Text(
            "Enter this code on the sign-in page. Device-code login may need to be enabled in your ChatGPT security settings."
          ).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Open sign-in page") { authentication.reopenLoginPage() }
          Button("Cancel sign-in") { Task { await authentication.cancel() } }
        }
        Text(
          "If the browser shows an error, cancel and check the connection or choose another sign-in option."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var statusColor: Color {
    if authentication.state == .ready { return .green }
    if case .failed = authentication.state { return .orange }
    return .secondary
  }
}
struct AgentDetectionRow: View {
  let kind: AgentKind
  let detection: AgentDetection?
  var body: some View {
    let symbol: String
    let color: Color
    switch detection {
    case nil: (symbol, color) = ("ellipsis.circle", .secondary)
    case let found? where found.usable: (symbol, color) = ("checkmark.circle.fill", .green)
    case let found? where found.installed: (symbol, color) = ("exclamationmark.circle.fill", .orange)
    default: (symbol, color) = ("xmark.circle", .secondary)
    }
    return HStack(alignment: .firstTextBaseline) {
      Image(systemName: symbol).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.title)
        Text(detection?.detail ?? "Not checked yet").font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }
}
