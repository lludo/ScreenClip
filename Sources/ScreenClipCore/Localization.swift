import Foundation

enum CoreLocalization {
  static func bundle(for locale: Locale) -> Bundle {
    let source = Bundle.module
    let preferred = Bundle.preferredLocalizations(
      from: source.localizations, forPreferences: [locale.identifier]).first
    guard let preferred, let path = source.path(forResource: preferred, ofType: "lproj"),
      let localized = Bundle(path: path) else { return source }
    return localized
  }
}

extension IssueStatus {
  /// English `title` stays stable for logs and tests. Views use this for display.
  public func localizedTitle(locale: Locale) -> String {
    String(
      localized: String.LocalizationValue(stringLiteral: title), bundle: CoreLocalization.bundle(for: locale), locale: locale)
  }
}

extension AgentDetection {
  public func localizedDetail(locale: Locale) -> String {
    if let match = ProviderPhrase.localizedMatch(detail, locale: locale) { return match }
    let at = "\(kind.title) at "
    let suffix = " did not respond."
    if detail.hasPrefix(at), detail.hasSuffix(suffix) {
      let path = String(detail.dropFirst(at.count).dropLast(suffix.count))
      return ProviderPhrase.noResponseLocalized(kind: kind, path: path, locale: locale)
    }
    return CoreChrome.display(detail, locale: locale) ?? detail
  }
}

extension ExternalAgentAvailability {
  public func localizedHint(locale: Locale) -> String? {
    guard let hint else { return nil }
    if let phrase = ProviderPhrase.localizedMatch(hint, locale: locale) { return phrase }
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
      localized: String.LocalizationValue(stringLiteral: english), bundle: CoreLocalization.bundle(for: locale), locale: locale)
  }

  static let exact: Set<String> = [
    "Not configured. Add the webhook URL and Authorization header in Settings → AI Agents → External assistant.",
    "Codex CLI not found.",
    "Claude Code CLI not found. Install it from claude.com/claude-code.",
    "Connected",
    "Choose a project that can share screenshots with Grok Bot.",
    "Enter the key from the ScreenClip reports routine.",
    "The Webhook URL has to start with https.",
    "The key can't contain a line break.",
    "Paste the Webhook URL on one line and the Authorization header on the next. Copy both from the ScreenClip reports routine in Grok Bot.",
    "Add the webhook URL too. Copy it from the ScreenClip reports routine and paste it with the Authorization header.",
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
    "Cancel requested. This is best-effort: Grok Bot may still finish work it already started.",
    "Could not reach Grok Bot to ask it to stop.",
    "Draft PR. Automatic merge waits until the pull request is marked ready.",
    "ScreenClip restarted while sending to Grok Bot. Retry delivers the same report and revision again.",
    "ScreenClip restarted. Watching for Grok Bot's pull request.",
    "Grok Bot is not configured. Add the webhook URL and Authorization header in Settings → AI Agents → External assistant.",
    "Choose a working Claude Code executable in Settings.",
    "Update Claude Code to start work. This version has no automatic permission review.",
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
