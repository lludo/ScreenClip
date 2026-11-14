import Foundation

extension IssueStatus {
  /// English `title` stays stable for logs and tests. Views use this for display.
  public func localizedTitle(locale: Locale) -> String {
    String(
      localized: String.LocalizationValue(stringLiteral: title), bundle: .module, locale: locale)
  }
}

extension AgentDetection {
  /// Product names stay untranslated. The surrounding status words are localized.
  public func localizedLabel(locale: Locale) -> String {
    switch kind {
    case .external:
      return usable
        ? kind.title
        : String(
          localized: "Grok Bot — not configured", bundle: .module, locale: locale,
          comment: "Agent menu label when the Grok Bot webhook is missing.")
    case .codex:
      guard installed else {
        return String(
          localized: "Codex — not found", bundle: .module, locale: locale,
          comment: "Agent menu label when the Codex CLI is missing.")
      }
      return kind.title
    case .claude:
      guard installed else {
        return String(
          localized: "Claude Code — not found", bundle: .module, locale: locale,
          comment: "Agent menu label when the Claude Code CLI is missing.")
      }
      if signedIn == false {
        return String(
          localized: "Claude Code — signed out", bundle: .module, locale: locale,
          comment: "Agent menu label when Claude Code is installed but signed out.")
      }
      return kind.title
    }
  }

  public func localizedDetail(locale: Locale) -> String {
    switch kind {
    case .external:
      guard usable else {
        if detail.contains("must be an http") {
          return String(
            localized:
              "Not configured. The webhook URL must be an http or https address, and the Authorization header value is required. Edit them in Settings → Connections → External assistant.",
            bundle: .module, locale: locale,
            comment: "Grok Bot detection detail when one of the two saved values is unusable.")
        }
        return String(
          localized:
            "Not configured. Add the webhook URL and Authorization header in Settings → Connections → External assistant.",
          bundle: .module, locale: locale,
          comment: "Grok Bot detection detail when the connection has not been saved.")
      }
      var text = String(
        localized: "Detected. Webhook and Authorization header are saved in the Keychain.",
        bundle: .module, locale: locale,
        comment: "Grok Bot detection detail when both connection values are saved.")
      if detail.contains("Send test succeeded") {
        text +=
          " "
          + String(
            localized: "Send test succeeded.", bundle: .module, locale: locale,
            comment: "Appended to the Grok Bot detection detail after a successful test POST.")
      }
      return text
    case .codex:
      guard let version else {
        return path.isEmpty
          ? String(
            localized: "Codex CLI not found.", bundle: .module, locale: locale,
            comment: "Codex detection detail when no executable was found.")
          : String(
            localized: "codex.noResponse",
            defaultValue: "Codex at \(path) did not respond.", bundle: .module, locale: locale,
            comment: "Codex detection detail. %@ is the executable path.")
      }
      return String(
        localized: "codex.version", defaultValue: "Codex \(version)", bundle: .module,
        locale: locale, comment: "Codex detection detail. %@ is the version.")
    case .claude:
      guard let version else {
        return path.isEmpty
          ? String(
            localized: "Claude Code CLI not found. Install it from claude.com/claude-code.",
            bundle: .module, locale: locale,
            comment: "Claude Code detection detail when no executable was found.")
          : String(
            localized: "claude.noResponse",
            defaultValue: "Claude Code at \(path) did not respond.", bundle: .module,
            locale: locale, comment: "Claude Code detection detail. %@ is the executable path.")
      }
      switch signedIn {
      case true?:
        if let method = signedInMethod {
          return String(
            localized: "claude.signedInMethod",
            defaultValue: "Claude Code \(version), signed in (\(method))", bundle: .module,
            locale: locale,
            comment: "Claude Code detection detail. First %@ is the version, second is the auth method.")
        }
        return String(
          localized: "claude.signedIn", defaultValue: "Claude Code \(version), signed in",
          bundle: .module, locale: locale,
          comment: "Claude Code detection detail. %@ is the version.")
      case false?:
        return String(
          localized: "claude.signedOut",
          defaultValue: "Claude Code \(version) is signed out. Use Sign in to Claude.",
          bundle: .module, locale: locale,
          comment: "Claude Code detection detail. %@ is the version.")
      case nil:
        return String(
          localized: "claude.signInUnknown",
          defaultValue: "Claude Code \(version); sign-in status unavailable.", bundle: .module,
          locale: locale, comment: "Claude Code detection detail. %@ is the version.")
      }
    }
  }

  /// Auth method parsed back out of the English detail, so localization does not depend on it.
  private var signedInMethod: String? {
    guard signedIn == true, let open = detail.lastIndex(of: "("), let close = detail.lastIndex(of: ")"),
      open < close
    else { return nil }
    let method = detail[detail.index(after: open)..<close]
    return method.isEmpty ? nil : String(method)
  }
}

extension ExternalAgentAvailability {
  public func localizedHint(locale: Locale) -> String? {
    guard let hint else { return nil }
    return CoreChrome.display(hint, locale: locale) ?? hint
  }
}

extension ExternalAssistant {
  public static func localizedConversationNote(locale: Locale) -> String {
    CoreChrome.display(conversationNote, locale: locale) ?? conversationNote
  }
}

/// User-facing sentences produced in ScreenClipCore. Stored and agent-bound text stays English;
/// call this only when displaying.
public enum CoreChrome {
  public static func display(_ english: String, locale: Locale) -> String? {
    guard exact.contains(english) else { return nil }
    return String(
      localized: String.LocalizationValue(stringLiteral: english), bundle: .module, locale: locale)
  }

  static let exact: Set<String> = [
    "Not configured. The webhook URL must be an http or https address, and the Authorization header value is required. Edit them in Settings → Connections → External assistant.",
    "Not configured. Add the webhook URL and Authorization header in Settings → Connections → External assistant.",
    "Detected. Webhook and Authorization header are saved in the Keychain.",
    "Send test succeeded.",
    "Codex CLI not found.",
    "Claude Code CLI not found. Install it from claude.com/claude-code.",
    "Grok Bot — not configured",
    "Codex — not found",
    "Claude Code — not found",
    "Claude Code — signed out",
    "Draft",
    "Needs project",
    "Queued",
    "Working",
    "Needs you",
    "PR open",
    "Merged",
    "Verified",
    "Failed",
    "Canceled",
    "The conversation is in Grok Bot's chat.",
    "Sent to external assistant",
    "This pull request still contains .screenclip/ files. Automatic merge is waiting until Grok Bot removes them.",
    "Canceled locally. Grok Bot cannot be stopped from ScreenClip; it may still finish and open a pull request.",
    "ScreenClip restarted while sending to Grok Bot. Retry delivers the same report and revision again.",
    "ScreenClip restarted. Watching for Grok Bot's pull request.",
    "Grok Bot is not configured. Add the webhook URL and Authorization header in Settings → Connections → External assistant.",
    "Choose a project that allows sending screenshots to Grok Bot.",
    "Turn on Allow sending screenshots to the external assistant for this project before choosing Grok Bot. Approved screenshots are pushed to a screenclip/ branch in the project's repository.",
    "This project's GitHub repository is public. Turn on Allow sending screenshots to the external assistant in the project settings before sending captures to Grok Bot. Approved screenshots would otherwise be pushed to a public branch.",
    "Turn on Allow sending screenshots to the external assistant in this project's settings before sending captures to Grok Bot.",
    "Choose a working Claude Code executable in Settings.",
    "This Claude Code session already has a running turn.",
    "Choose a working Codex executable in Settings.",
    "Codex returned a repeated project-list cursor.",
    "Multiple Codex projects use this repository.",
    "Codex is disconnected.",
    "Codex disconnected.",
    "Could not reach Grok Bot.",
    "Grok Bot did not return an HTTP response.",
    "No issue worktree exists.",
    "No source paths to publish.",
    "The source or issue changed before push. Publication stopped.",
    "The existing PR targets a different base branch.",
    "Invalid GitHub PR URL.",
    "Could not open the local queue database.",
    "Cannot read the queue.",
    "This queue connection is read-only.",
    "Cannot prepare queue save.",
    "This queue was created by a newer ScreenClip. Update the app before opening it.",
    "ScreenClip is already using this queue. Open the running instance from the menu bar.",
    "The issue worktree has an unexpected branch. Inspect it before retrying.",
  ]
}
