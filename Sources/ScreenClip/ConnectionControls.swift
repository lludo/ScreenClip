import ScreenClipCore
import SwiftUI

struct ScreenCapturePermissionControls: View {
  @ObservedObject var model: AppModel
  @ObservedObject var permission: ScreenCapturePermission
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(verbatim: Chrome.stored(permission.message, locale: locale))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: permission.state == .available ? "checkmark.circle" : "viewfinder")
      }.font(.caption).foregroundStyle(permission.state == .available ? .green : .secondary)
      FlowLayout {
        Button {
          Task { await model.recheckCapturePermission() }
        } label: {
          Text(chrome: "Check screen access", comment: "Rechecks Screen Recording permission.")
        }.disabled(permission.state == .checking)
        if permission.state != .available {
          Button {
            model.openCaptureSettings()
          } label: {
            Text(chrome: "Open System Settings", comment: "Opens the Screen Recording privacy pane.")
          }
          Button {
            model.relaunchAction?()
          } label: {
            Text(chrome: "Reopen app", comment: "Relaunches ScreenClip after a permission change.")
          }
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
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      FlowLayout {
        Button(action: choose) {
          Text(chrome: "Choose…", comment: "Picks a Codex executable.")
        }
        Button(action: check) {
          Text(chrome: "Check connection", comment: "Checks whether Codex is signed in.")
        }.disabled(authentication.state == .checking)
        Button {
          signIn(.browser)
        } label: {
          Text(verbatim: ProviderPhrase.signIn.localized(.codex, locale: locale))
        }.disabled(
          authentication.state == .checking || authentication.state == .ready
            || authentication.loginID != nil)
        if authentication.state != .ready {
          Menu {
            Button { signIn(.deviceCode) } label: {
              Text(chrome: "Sign in with a code…", comment: "Starts Codex device-code sign-in.")
            }
            Button { signIn(.browser) } label: {
              Text(chrome: "Try browser sign-in again…", comment: "Retries Codex browser sign-in.")
            }
          } label: {
            Text(chrome: "Other sign-in options", comment: "Menu of alternate Codex sign-in methods.")
          }.disabled(authentication.state == .checking)
        }
        if authentication.state == .checking { ProgressView().controlSize(.small) }
      }
      Text(verbatim: Chrome.stored(model.connection, locale: locale)).font(.caption)
        .foregroundStyle(statusColor).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if let description = authentication.accountDescription {
        Text(verbatim: Chrome.stored(description, locale: locale)).font(.caption)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if authentication.loginID != nil {
        if let code = authentication.userCode {
          HStack {
            Text(verbatim: code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code, forType: .string)
            } label: {
              Text(chrome: "Copy code", comment: "Copies the Codex device-login code.")
            }
          }
          Text(
            chrome:
              "Enter this code on the sign-in page. Device-code login may need to be enabled in your ChatGPT security settings.",
            comment: "Explains the Codex device code. ChatGPT stays untranslated."
          ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout {
          Button {
            authentication.reopenLoginPage()
          } label: {
            Text(chrome: "Open sign-in page", comment: "Reopens the Codex sign-in page.")
          }
          Button {
            Task { await authentication.cancel() }
          } label: {
            Text(chrome: "Cancel sign-in", comment: "Cancels the in-progress Codex sign-in.")
          }
        }
        Text(
          chrome:
            "If the browser shows an error, cancel and check the connection or choose another sign-in option.",
          comment: "Shown while Codex sign-in is waiting on the browser."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
  @Environment(\.locale) private var locale
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
        AgentLabel(kind: kind)
        Text(
          verbatim: detection?.localizedDetail(locale: locale)
            ?? Chrome.text("Not checked yet", locale: locale, comment: "Agent has not been detected yet.")
        ).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
