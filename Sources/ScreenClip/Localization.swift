import Foundation
import ScreenClipCore
import SwiftUI

enum AppLocalization {
  static var bundle: Bundle {
    #if SWIFT_PACKAGE
    return .module
    #else
    return .main
    #endif
  }
  static func bundle(for locale: Locale) -> Bundle {
    let preferred = Bundle.preferredLocalizations(
      from: bundle.localizations, forPreferences: [locale.identifier]).first
    guard let preferred, let path = bundle.path(forResource: preferred, ofType: "lproj"),
      let localized = Bundle(path: path) else { return bundle }
    return localized
  }
}

extension Text {
  init(chrome key: LocalizedStringKey, comment: StaticString) {
    self.init(key, bundle: AppLocalization.bundle, comment: comment)
  }
}

/// Localized chrome. User-entered report text, agent prose, project names, and commands stay as stored.
enum Chrome {
  static func text(
    _ key: String.LocalizationValue, locale: Locale = .current, comment: StaticString
  ) -> String {
    String(localized: key, bundle: AppLocalization.bundle(for: locale), locale: locale, comment: comment)
  }

  static func format(
    _ key: StaticString, _ defaultValue: String.LocalizationValue, locale: Locale = .current,
    comment: StaticString
  ) -> String {
    String(
      localized: key, defaultValue: defaultValue, bundle: AppLocalization.bundle(for: locale), locale: locale,
      comment: comment)
  }

  /// Translates an English sentence the app generated. Anything not in the catalog is returned unchanged.
  static func stored(_ english: String, locale: Locale) -> String {
    if let phrase = ProviderPhrase.localizedMatch(english, locale: locale) { return phrase }
    if let patterned = ActivityPatterns.translate(english, locale: locale) { return patterned }
    if AppChrome.exact.contains(english) {
      return String(
        localized: String.LocalizationValue(stringLiteral: english), bundle: AppLocalization.bundle(for: locale),
        locale: locale)
    }
    if let core = CoreChrome.display(english, locale: locale) { return core }
    if let prefixed = ActivityPatterns.prefixed(english, locale: locale) { return prefixed }
    return english
  }
}

enum AppChrome {
  static let exact: Set<String> = [
    "All open", "Needs you", "To retest", "Drafts", "History", "Archived",
    "Not connected", "Sign in to Codex in your browser",
    "Sign in to Codex with the one-time code", "Codex disconnected",
    "Codex disconnected. Check the connection to reconnect.",
    "Selected model is unavailable; choose another model",
    "Grok Bot is not configured", "Grok Bot is not connected.",
    "Grok Bot rejected that key (HTTP 401).", "Connected",
    "Couldn't reach Grok Bot. Check your connection, then try again.",
    "Screen capture has not been checked yet.",
    "This running copy of ScreenClip was rebuilt. Reopen it to refresh screen-capture access.",
    "Screen capture is ready.",
    "macOS has not made screen capture available to this copy of ScreenClip. If access is already enabled in System Settings, reopen the app and check again. A rebuilt development copy may need to be allowed again.",
    "Copied. Paste in Terminal to continue this issue's Claude Code session.",
    "That keyboard shortcut is already in use. Choose another in Settings.",
    "Save your capture as a draft before reopening ScreenClip.",
    "Finish or cancel active work before reopening ScreenClip.",
    "Save this capture as a draft or discard it before quitting ScreenClip.",
    "The webhook URL must be an http or https address.",
    "Paste the Authorization header value from the Grok Bot routine panel.",
    "The Authorization header cannot contain a line break. Paste the single-line value from the Grok Bot routine panel.",
    "GitHub sign-in is ready.",
    "Notifications are disabled. Enable ScreenClip in System Settings to receive alerts.",
    "Install Claude Code or choose its executable first.",
    "Report no longer exists.",
    "Cancel active work before archiving this report.",
    "Cancel or finish the active run before deleting its evidence.",
    "This project has recorded issues. Add a new project to use a different repository.",
    "Dispatch was not acknowledged. Use Reconcile chat before retrying.",
    "Enter the Claude Code session ID.",
    "Enter the thread ID from the Codex chat link.",
    "Codex did not return a sign-in attempt ID. Try checking the connection again.",
    "Codex returned an invalid sign-in address.",
    "Codex did not return a one-time code. Browser sign-in is still available.",
    "The sign-in page could not be opened. Check your default browser and try again.",
    "The browser sign-in did not complete. Check the connection or try another sign-in option.",
    "Sign-in did not finish. Check the connection if the browser showed an error, or try sign-in with a code.",
    "Using your existing Codex ChatGPT sign-in.",
    "Using the API key already configured in Codex.",
    "Using Codex's configured provider.",
    "Finish or cancel active Codex work before changing the Codex connection.",
    "Reconnect and reconcile the chat; the original request may no longer be pending.",
    "The conversation is in Grok Bot's chat. ScreenClip cannot open or reconcile it from here.",
    "Draft saved", "Capture submitted", "Draft updated", "Draft submitted", "Project assigned",
    "Context added", "Tester requested a follow-up", "Queued to continue",
    "Report archived; evidence retained", "Report restored from archive",
    "Tester verified the fix", "Preparing isolated workspace", "Reply sent to Codex",
    "Reply submitted", "Canceled; existing workspace and PR retained",
    "Running project validation", "Preparing evidence for Grok Bot",
    "New evidence arrived; continuing with the latest revision",
    "New evidence arrived during publication; continuing with the latest revision",
    "Session reconciled. Continue when ready.", "Chat reconciled. Continue when ready.",
    "Recovering completed fix", "Continuing in Codex",
    "Previous Claude Code session was not found; starting a new session",
    "ScreenClip restarted. Reconcile the existing chat before continuing.",
    "No Claude Code process survived the restart; continuing the same session",
    "Grok Bot has not opened a pull request yet. ScreenClip is still watching. Continue sends the report again, or cancel it.",
    "ScreenClip notices the sign-in within a minute. Click Detect agents to check now.",
    "Worker disconnected. Reconcile the chat before continuing.",
    "Base branch advanced; revalidating the updated fix",
    "Merged. Rebuild or deploy the app, then retest.",
    "Updated the pull request onto the current base branch. Waiting for checks.",
    "Waiting for checks on the pull request after updating it onto the base branch.",
    "The PR changed; run validation again before merging.",
    "Waiting for required review.", "Waiting for the PR to become mergeable.",
    "Checks passed. Automatic merge is disabled for this project.",
    "Checks passed. Processing is paused.", "Checks passed; preparing merge.",
    "Fix merged. Ready to rebuild and retest.",
    "Issue no longer exists.", "Choose a Git repository root containing .git.",
    "Give the project a name.", "Related captures must use the issue's existing project.",
    "Report or project no longer exists.",
    "Cancel active work before moving this report to another project.",
    "This report has no captures to move.", "Enter some context before saving.",
    "No display is available for capture.",
    "Cancel the active run before changing its session.",
    "Enter the Claude Code session ID (a UUID).",
    "This Claude Code session is still running.",
    "Codex did not return a chat ID.", "Codex did not acknowledge the turn.",
    "Cancel the active run before changing its chat binding.",
    "This report does not have a number yet.",
    "Could not write the approved screenshots for Grok Bot.",
    "The Grok Bot report has no evidence branch.", "Choose a project.",
    "Workspace preparation failed.", "Could not render the annotated image.",
    "Could not encode the screenshot.",
    "ScreenClip could not open its queue",
    "Could not save the report.",
    "Press shortcut…", "Include ⌘, ⌃ or ⌥",
    "Your note will be included after the chat is reconciled.",
    "Your note stays with this draft until you submit it.",
    "Choose a project in the report before work can begin.",
    "Your note will be included in follow-up work after the current work finishes.",
    "Your note will be included when work continues. Answer any pending questions in the report.",
    "Saving queues this report with your added context.",
    "Not checked yet",
    "Project selected by tester",
  ]
}

enum ActivityPatterns {
  static func translate(_ text: String, locale: Locale) -> String? {
    if let count = firstInt(#"^Added capture (\d+)$"#, text) {
      return Chrome.format(
        "activity.addedCapture", "Added capture \(count)", locale: locale,
        comment: "Activity log when another screenshot is added. %lld is the capture count.")
    }
    if let count = firstInt(#"^Investigating capture revision (\d+)$"#, text) {
      return Chrome.format(
        "activity.investigating", "Investigating capture revision \(count)", locale: locale,
        comment: "Activity log when Codex starts a turn. %lld is the revision.")
    }
    if let count = firstInt(#"^Investigating capture revision (\d+) with Claude Code$"#, text) {
      return Chrome.format(
        "activity.investigatingClaude", "Investigating capture revision \(count) with Claude Code",
        locale: locale,
        comment: "Activity log when Claude Code starts a turn. %lld is the revision.")
    }
    if let revision = firstInt(
      #"^Grok Bot hasn't picked up revision (\d+) yet \(run may have failed or hit a rate limit\)\. Continue resends it\.$"#,
      text)
    {
      return Chrome.format(
        "activity.grokPickup",
        "Grok Bot hasn't picked up revision \(revision) yet (run may have failed or hit a rate limit). Continue resends it.",
        locale: locale,
        comment: "Activity when Grok Bot has not acknowledged a revision. %lld is the revision. Keep Grok Bot.")
    }
    if let revision = firstInt(#"^Grok Bot acknowledged revision (\d+)$"#, text) {
      return Chrome.format(
        "activity.grokAcknowledged", "Grok Bot acknowledged revision \(revision)", locale: locale,
        comment: "Activity when a Grok Bot status has no description. %lld is the revision. Keep Grok Bot.")
    }
    if let status = firstInt(#"^Grok Bot rejected the report \(HTTP (\d+)\)\.$"#, text) {
      return Chrome.format(
        "activity.grokRejected", "Grok Bot rejected the report (HTTP \(status)).", locale: locale,
        comment: "Delivery error. %lld is the HTTP status. The response body is never included. Keep Grok Bot and HTTP.")
    }
    if let status = firstInt(#"^Grok Bot could not be asked to stop \(HTTP (\d+)\)\.$"#, text) {
      return Chrome.format(
        "activity.grokCancelHTTP", "Grok Bot could not be asked to stop (HTTP \(status)).",
        locale: locale,
        comment: "Best-effort cancel failed. %lld is the HTTP status. Keep Grok Bot and HTTP.")
    }
    if let description = remainder("Grok Bot: ", text) {
      return Chrome.format(
        "activity.grokStatus", "Grok Bot: \(description)", locale: locale,
        comment: "Activity from a Grok Bot commit status. %@ is the status text and stays unchanged. Keep Grok Bot.")
    }
    if let count = firstInt(#"^Sending report revision (\d+) to Grok Bot$"#, text) {
      return Chrome.format(
        "activity.sendingGrok", "Sending report revision \(count) to Grok Bot", locale: locale,
        comment: "Activity log when a report revision is posted to Grok Bot. %lld is the revision.")
    }
    if let groups = groups(#"^Checks failed; starting repair attempt (\d+) of (\d+)$"#, text),
      let attempt = Int(groups[0]), let total = Int(groups[1])
    {
      return Chrome.format(
        "activity.repair", "Checks failed; starting repair attempt \(attempt) of \(total)",
        locale: locale,
        comment: "Activity log for an automatic repair. First %lld is the attempt, second is the limit.")
    }
    if let url = remainder("Previous fix: ", text) {
      return Chrome.format(
        "activity.previousFix", "Previous fix: \(url)", locale: locale,
        comment: "Activity log. %@ is a pull request URL and stays unchanged.")
    }
    if let url = remainder("Pull request opened: ", text) {
      return Chrome.format(
        "activity.pullOpened", "Pull request opened: \(url)", locale: locale,
        comment: "Activity log. %@ is a pull request URL.")
    }
    if let url = remainder("PR opened: ", text) {
      return Chrome.format(
        "activity.prOpened", "PR opened: \(url)", locale: locale,
        comment: "Activity log. %@ is a pull request URL. Keep the PR abbreviation.")
    }
    if let name = remainder("Moved to ", text), !name.contains(";") && !name.contains(" as ") {
      return Chrome.format(
        "activity.movedTo", "Moved to \(name)", locale: locale,
        comment: "Activity log. %@ is the project name and is not translated.")
    }
    if let name = capture(#"^Moved to (.+); continuing in a new report$"#, text) {
      return Chrome.format(
        "activity.movedContinue", "Moved to \(name); continuing in a new report", locale: locale,
        comment: "Activity log. %@ is the project name and is not translated.")
    }
    if let groups = groups(#"^Moved to (.+) as (#\d+)$"#, text) {
      return Chrome.format(
        "activity.movedAs", "Moved to \(groups[0]) as \(groups[1])", locale: locale,
        comment: "Activity log. First %@ is the project name, second is the report number.")
    }
    if let groups = groups(#"^Moved from (.+?)( \(#\d+\))?$"#, text) {
      if groups.count > 1 && !groups[1].isEmpty {
        return Chrome.format(
          "activity.movedFromRef", "Moved from \(groups[0])\(groups[1])", locale: locale,
          comment: "Activity log. %@ is the previous project name plus an optional report reference.")
      }
      return Chrome.format(
        "activity.movedFrom", "Moved from \(groups[0])", locale: locale,
        comment: "Activity log. %@ is the previous project name and is not translated.")
    }
    if let usage = remainder("Claude Code turn finished · ", text) {
      return Chrome.format(
        "activity.claudeUsage", "Claude Code turn finished · \(usage)", locale: locale,
        comment: "Activity log. %@ is the usage summary from Claude Code and stays unchanged.")
    }
    if let url = capture(
      #"^GitHub checks failed\. Grok Bot can push another commit to (.+)\.$"#, text)
    {
      return Chrome.format(
        "activity.grokChecks",
        "GitHub checks failed. Grok Bot can push another commit to \(url).", locale: locale,
        comment: "Activity log. %@ is a pull request URL.")
    }
    if let agent = capture(#"^The base update needs attention in (.+)\.$"#, text) {
      return Chrome.format(
        "activity.baseAttention", "The base update needs attention in \(agent).", locale: locale,
        comment: "Activity log. %@ is the agent product name.")
    }
    if let agent = capture(
      #"^CI still fails after two repair attempts\. Review the PR checks in (.+)\.$"#, text)
    {
      return Chrome.format(
        "activity.ciStillFails",
        "CI still fails after two repair attempts. Review the PR checks in \(agent).",
        locale: locale, comment: "Activity log. %@ is the agent product name. Keep PR.")
    }
    if let pr = remainder(
      "Previous revision merged; continuing with newly submitted evidence. PR: ", text)
    {
      return Chrome.format(
        "activity.previousMerged",
        "Previous revision merged; continuing with newly submitted evidence. PR: \(pr)",
        locale: locale, comment: "Activity log. %@ is a pull request URL. Keep PR.")
    }
    if let agent = capture(#"^(.+) finished without a structured result\. Open the chat to review\.$"#, text),
      ["Codex", "Claude Code", "Grok Bot"].contains(agent)
    {
      return Chrome.format(
        "activity.noResult", "\(agent) finished without a structured result. Open the chat to review.",
        locale: locale, comment: "Activity log. %@ is the agent product name.")
    }
    if let status = capture(#"^HTTP (\d+)\. Grok Bot accepted the test request\.$"#, text),
      let code = Int(status)
    {
      return Chrome.format(
        "grok.httpAccepted", "HTTP \(code). Grok Bot accepted the test request.", locale: locale,
        comment: "Grok Bot test result. %lld is the HTTP status. Keep HTTP and Grok Bot.")
    }
    if let groups = groups(#"^HTTP (\d+)\. (.*)$"#, text), let code = Int(groups[0]) {
      return Chrome.format(
        "grok.httpBody", "HTTP \(code). \(groups[1])", locale: locale,
        comment: "Grok Bot test result. %lld is the status; %@ is the response body and stays unchanged.")
    }
    if let code = firstInt(#"^HTTP (\d+)\.$"#, text) {
      return Chrome.format(
        "grok.httpOnly", "HTTP \(code).", locale: locale,
        comment: "Grok Bot test result when the body is empty. %lld is the HTTP status.")
    }
    if let detail = remainder("GitHub needs setup: ", text) {
      return Chrome.format(
        "github.needsSetup", "GitHub needs setup: \(detail)", locale: locale,
        comment: "Settings status. %@ is the GitHub CLI's own message and stays unchanged.")
    }
    if let detail = remainder("Codex sign-in failed: ", text) {
      return Chrome.format(
        "codex.signInFailed", "Codex sign-in failed: \(detail)", locale: locale,
        comment: "Connection status. %@ is the underlying error and stays unchanged.")
    }
    if let status = firstInt(#"^Could not remove the Grok Bot connection from the Keychain \(error (\d+)\)\.$"#, text) {
      return Chrome.format(
        "keychain.removeFailed",
        "Could not remove the Grok Bot connection from the Keychain (error \(status)).",
        locale: locale, comment: "Keychain error. %lld is the OSStatus. Keep Keychain and Grok Bot.")
    }
    if let status = firstInt(#"^Could not save the Grok Bot connection in the Keychain \(error (\d+)\)\.$"#, text) {
      return Chrome.format(
        "keychain.saveFailed",
        "Could not save the Grok Bot connection in the Keychain (error \(status)).",
        locale: locale, comment: "Keychain error. %lld is the OSStatus.")
    }
    if let name = capture(#"^Choose the repository root for (.+)\.$"#, text) {
      return Chrome.format(
        "git.chooseRoot", "Choose the repository root for \(name).", locale: locale,
        comment: "Error. %@ is the project name and is not translated.")
    }
    if let detail = remainder("Could not reach Grok Bot. ", text) {
      return Chrome.format(
        "grok.unreachable", "Could not reach Grok Bot. \(detail)", locale: locale,
        comment: "Network error. %@ is the system error and stays unchanged.")
    }
    if let minutes = firstInt(
      #"^Codex did not finish within (\d+) minutes and was stopped\. Retry to continue in the same chat\.$"#,
      text)
    {
      return Chrome.format(
        "activity.codexTimeout",
        "Codex did not finish within \(minutes) minutes and was stopped. Retry to continue in the same chat.",
        locale: locale,
        comment: "Activity log. %lld is the time limit in minutes. Keep Codex.")
    }
    if let minutes = firstInt(
      #"^Claude Code did not finish within (\d+) minutes and was stopped\.$"#, text)
    {
      return Chrome.format(
        "activity.claudeTimeout",
        "Claude Code did not finish within \(minutes) minutes and was stopped.",
        locale: locale,
        comment: "Error when a Claude Code turn exceeds its time limit. %lld is minutes. Keep Claude Code.")
    }
    if let status = firstInt(
      #"^Grok Bot didn't accept the connection \(HTTP (\d+)\)\.$"#,
      text)
    {
      return Chrome.format(
        "grok.rejected",
        "Grok Bot didn't accept the connection (HTTP \(status)).",
        locale: locale,
        comment: "Grok Bot rejected the saved connection. %lld is the HTTP status. Keep Grok Bot.")
    }
    if text.hasPrefix("Could not save the report: ") {
      let detail = String(text.dropFirst("Could not save the report: ".count))
      return Chrome.format(
        "store.saveFailed", "Could not save the report: \(detail)", locale: locale,
        comment: "Database error. %@ is the SQLite message and stays unchanged.")
    }
    return nil
  }

  /// English sentences with a translated prefix and an unchanged remainder.
  static func prefixed(_ text: String, locale: Locale) -> String? {
    let prefixes = [
      "GitHub checks failed for ": "error.checksFailed",
    ]
    for (prefix, _) in prefixes where text.hasPrefix(prefix) {
      // The remainder is agent-directed diagnostic text. Translate only when the whole
      // sentence is a known template; otherwise leave the stored English.
      return nil
    }
    return nil
  }

  private static func remainder(_ prefix: String, _ text: String) -> String? {
    text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
  }
  private static func firstInt(_ pattern: String, _ text: String) -> Int? {
    capture(pattern, text).flatMap(Int.init)
  }
  private static func capture(_ pattern: String, _ text: String) -> String? {
    groups(pattern, text)?.first
  }
  private static func groups(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let found = match.range(at: index)
      guard found.location != NSNotFound, let slice = Range(found, in: text) else { return "" }
      return String(text[slice])
    }
  }
}

extension QueueFilter {
  func localizedTitle(locale: Locale) -> String { Chrome.stored(rawValue, locale: locale) }
}

extension MarkKind {
  func localizedTitle(locale: Locale) -> String {
    switch self {
    case .pen:
      return Chrome.text("Pen", locale: locale, comment: "Annotation tool name.")
    case .arrow:
      return Chrome.text("Arrow", locale: locale, comment: "Annotation tool name.")
    case .rectangle:
      return Chrome.text("Rectangle", locale: locale, comment: "Annotation tool name.")
    case .ellipse:
      return Chrome.text("Ellipse", locale: locale, comment: "Annotation tool name.")
    case .text:
      return Chrome.text("Text", locale: locale, comment: "Annotation tool that places a label.")
    case .redact:
      return Chrome.text("Redact", locale: locale, comment: "Annotation tool that blacks out pixels.")
    }
  }
}

extension MarkColor {
  func localizedTitle(locale: Locale) -> String {
    switch self {
    case .red: return Chrome.text("Red", locale: locale, comment: "Annotation color.")
    case .orange: return Chrome.text("Orange", locale: locale, comment: "Annotation color.")
    case .yellow: return Chrome.text("Yellow", locale: locale, comment: "Annotation color.")
    case .green: return Chrome.text("Green", locale: locale, comment: "Annotation color.")
    case .blue: return Chrome.text("Blue", locale: locale, comment: "Annotation color.")
    case .white: return Chrome.text("White", locale: locale, comment: "Annotation color.")
    case .black: return Chrome.text("Black", locale: locale, comment: "Annotation color.")
    }
  }
}

/// Wraps controls onto extra lines when a translation is wider than the row.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(proposal: proposal, subviews: subviews)
    for (subview, frame) in zip(subviews, result.frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (
    size: CGSize, frames: [CGRect]
  ) {
    let maxWidth = proposal.width ?? .greatestFiniteMagnitude
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maxWidth {
        x = 0
        y += rowHeight + lineSpacing
        rowHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
      usedWidth = max(usedWidth, x - spacing)
    }
    return (CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight), frames)
  }
}
