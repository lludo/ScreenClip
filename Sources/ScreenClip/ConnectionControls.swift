import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

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
          Text(chrome: "Sign in…", comment: "Starts Codex browser sign-in.")
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
struct GrokBotConnectionFields: View {
  @Binding var webhookURL: String
  @Binding var authorization: String
  var sendingTest: Bool
  var testResult: String?
  var sendTest: () -> Void
  @Environment(\.locale) private var locale
  var body: some View {
    TextField(
      text: $webhookURL,
      prompt: Text(verbatim: "https://")
    ) {
      Text(chrome: "Webhook URL", comment: "Grok Bot webhook URL field. Keep URL.")
        .fixedSize(horizontal: false, vertical: true)
    }
    SecureField(text: $authorization) {
      Text(chrome: "Authorization header", comment: "Grok Bot Authorization header field. Keep Authorization.")
        .fixedSize(horizontal: false, vertical: true)
    }
    Text(
      chrome:
        "Paste the Webhook URL and the Authorization header from the Grok Bot routine panel. ScreenClip sends that header value as the HTTP Authorization header and does not add a prefix. Both are stored in the Keychain, not in the queue database.",
      comment: "Explains the Grok Bot connection fields. Keep HTTP, Authorization, and Keychain."
    ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    HStack {
      Button(action: sendTest) {
        if sendingTest {
          Text(chrome: "Sending…", comment: "Grok Bot test request is in flight.")
        } else {
          Text(chrome: "Send test", comment: "Posts a test webhook to Grok Bot.")
        }
      }.disabled(
        sendingTest || webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      if sendingTest { ProgressView().controlSize(.small) }
    }
    if let testResult {
      Text(verbatim: Chrome.stored(testResult, locale: locale)).font(.caption)
        .foregroundStyle(.secondary).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    Text(
      chrome:
        "Send test posts {\"schema\":\"screenclip.external.v1.test\"} and shows the HTTP result. Grok Bot is listed as Detected once both values are saved; a successful test is optional.",
      comment: "Explains the test payload. Keep the schema identifier and HTTP."
    ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}

/// The Grok Bot connection form, framed the way Settings presents it and how screenshots show the sheet.
struct ConnectGrokBotSheet: View {
  @Binding var webhookURL: String
  @Binding var authorization: String
  var sendingTest: Bool = false
  var testResult: String?
  var sendTest: () -> Void = {}
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(chrome: "Connect Grok Bot", comment: "Title of the Grok Bot connection form.")
        .font(.title2.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Form {
        GrokBotConnectionFields(
          webhookURL: $webhookURL, authorization: $authorization, sendingTest: sendingTest,
          testResult: testResult, sendTest: sendTest)
      }
    }
    .padding(24)
    .frame(minWidth: 560, idealWidth: 680)
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
        Text(verbatim: kind.title)
        Text(
          verbatim: detection?.localizedDetail(locale: locale)
            ?? Chrome.text("Not checked yet", locale: locale, comment: "Agent has not been detected yet.")
        ).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
