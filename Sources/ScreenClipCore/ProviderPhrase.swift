import Foundation

/// One wording pattern for Codex, Claude Code, and Grok Bot.
/// English is built here so the three providers cannot drift. Display goes through
/// `localized`, which fills the same `%@` template in every language.
public enum ProviderPhrase: String, CaseIterable, Sendable {
  case ready
  case checking
  case notConnected
  case notFound
  case signInToStart
  case connect
  case disconnect
  case signIn
  case disconnected

  /// English sentence with the provider name in the `%@` slot of `template`.
  public func english(_ kind: AgentKind) -> String {
    template.replacingOccurrences(of: "%@", with: kind.title)
  }

  public var template: String {
    switch self {
    case .ready: return "%@ ready"
    case .checking: return "Checking %@…"
    case .notConnected: return "%@ is not connected"
    case .notFound: return "%@ not found"
    case .signInToStart: return "Sign in to %@ to start work"
    case .connect: return "Connect %@"
    case .disconnect: return "Disconnect %@"
    case .signIn: return "Sign in to %@"
    case .disconnected: return "%@ disconnected"
    }
  }

  public func localized(_ kind: AgentKind, locale: Locale) -> String {
    let name = kind.title
    switch self {
    case .ready:
      return String(
        localized: "provider.ready", defaultValue: "\(name) ready",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "A provider is ready to take reports. %@ is Codex, Claude Code, or Grok Bot.")
    case .checking:
      return String(
        localized: "provider.checking", defaultValue: "Checking \(name)…",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "A provider is being checked. %@ is Codex, Claude Code, or Grok Bot.")
    case .notConnected:
      return String(
        localized: "provider.notConnected", defaultValue: "\(name) is not connected",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "A provider has no saved connection. %@ is Codex, Claude Code, or Grok Bot.")
    case .notFound:
      return String(
        localized: "provider.notFound", defaultValue: "\(name) not found",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "A provider's executable was not found. %@ is Codex, Claude Code, or Grok Bot.")
    case .signInToStart:
      return String(
        localized: "provider.signInToStart", defaultValue: "Sign in to \(name) to start work",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "A provider is signed out. %@ is Codex, Claude Code, or Grok Bot.")
    case .connect:
      return String(
        localized: "provider.connect", defaultValue: "Connect \(name)",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "Button that connects a provider. %@ is Codex, Claude Code, or Grok Bot.")
    case .disconnect:
      return String(
        localized: "provider.disconnect", defaultValue: "Disconnect \(name)",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "Button that removes a provider connection. %@ is Codex, Claude Code, or Grok Bot.")
    case .signIn:
      return String(
        localized: "provider.signIn", defaultValue: "Sign in to \(name)",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "Button that starts provider sign-in. %@ is Codex, Claude Code, or Grok Bot.")
    case .disconnected:
      return String(
        localized: "provider.disconnected", defaultValue: "\(name) disconnected",
        bundle: CoreLocalization.bundle(for: locale), locale: locale,
        comment: "A provider connection dropped. %@ is Codex, Claude Code, or Grok Bot.")
    }
  }

  public static func readyDetail(kind: AgentKind, extra: String) -> String {
    "\(kind.title) ready · \(extra)"
  }

  public static func readyDetailLocalized(kind: AgentKind, extra: String, locale: Locale) -> String {
    String(
      localized: "provider.readyDetail", defaultValue: "\(kind.title) ready · \(extra)",
      bundle: CoreLocalization.bundle(for: locale), locale: locale,
      comment: "A provider is ready. %1$@ is the provider name. %2$@ is a version or webhook host.")
  }

  public static func noResponse(kind: AgentKind, path: String) -> String {
    "\(kind.title) at \(path) did not respond."
  }

  public static func noResponseLocalized(kind: AgentKind, path: String, locale: Locale) -> String {
    String(
      localized: "provider.noResponse", defaultValue: "\(kind.title) at \(path) did not respond.",
      bundle: CoreLocalization.bundle(for: locale), locale: locale,
      comment: "A provider executable did not respond. %1$@ is the provider name. %2$@ is the path.")
  }

  /// The phrase that produced this exact English sentence, if it is one of the shared patterns.
  public static func match(_ text: String) -> (ProviderPhrase, AgentKind)? {
    for phrase in allCases {
      for kind in AgentKind.allCases where phrase.english(kind) == text {
        return (phrase, kind)
      }
    }
    return nil
  }

  public static func localizedMatch(_ text: String, locale: Locale) -> String? {
    if let (phrase, kind) = match(text) { return phrase.localized(kind, locale: locale) }
    let marker = " ready · "
    for kind in AgentKind.allCases {
      let prefix = kind.title + marker
      if text.hasPrefix(prefix) {
        return readyDetailLocalized(
          kind: kind, extra: String(text.dropFirst(prefix.count)), locale: locale)
      }
    }
    return nil
  }
}

/// System default, then project default, then the capture's own choice.
public enum AgentSelection {
  /// Shown when Grok Bot is chosen and the project has not allowed screenshot sharing.
  public static let grokOptInNote =
    "Grok Bot is selected, but Allow sending screenshots to the external assistant is off. Turn it on before screenshots can be sent."

  public static func systemDefault(_ settings: AppSettings) -> AgentKind {
    settings.preferredAgent
  }

  /// A nil project agent follows the system default. An explicit agent stays put.
  public static func projectDefault(_ project: Project?, system: AgentKind) -> AgentKind {
    project?.defaultAgent ?? system
  }

  public static func capture(override: AgentKind?, project: Project?, system: AgentKind) -> AgentKind {
    override ?? projectDefault(project, system: system)
  }
}
