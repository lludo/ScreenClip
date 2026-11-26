import Foundation

/// A file your app adds to a report, next to ScreenClip's own logs and diagnostics.
///
/// Agents see each attachment's name and summary in the prompt and open the file only when the
/// screenshot and note aren't enough, so write the summary for them: say what is inside.
public struct ScreenClipAttachment: Equatable, Sendable {
  public enum Format: String, Sendable {
    case text = "txt"
    case json
  }

  /// A short name such as `cart` or `feature-flags`. ScreenClip lowercases it, replaces anything
  /// other than letters, digits, and `-`, and adds the extension for the format.
  public var name: String
  /// One line for the agent, such as "the cart's 3 items and applied promo codes".
  public var summary: String
  public var format: Format
  public var data: Data

  public init(name: String, summary: String, format: Format, data: Data) {
    self.name = name
    self.summary = summary
    self.format = format
    self.data = data
  }

  /// Plain text, attached as `name.txt`.
  public static func text(_ text: String, name: String, summary: String) -> ScreenClipAttachment {
    ScreenClipAttachment(name: name, summary: summary, format: .text, data: Data(text.utf8))
  }

  /// JSON you already encoded, attached as `name.json`.
  public static func json(_ data: Data, name: String, summary: String) -> ScreenClipAttachment {
    ScreenClipAttachment(name: name, summary: summary, format: .json, data: data)
  }

  /// Any `Encodable` value, encoded as pretty-printed JSON with sorted keys and attached as `name.json`.
  public static func json<Value: Encodable>(_ value: Value, name: String, summary: String) throws -> ScreenClipAttachment {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try .json(encoder.encode(value), name: name, summary: summary)
  }

  /// The largest attachment ScreenClip sends. Larger ones are left out of the report.
  public static let maximumBytes = 1024 * 1024
  /// The most attachments ScreenClip sends with one report, across all providers. Later ones are left out.
  public static let maximumCount = 16
}

/// What a provider knows about the report it is attaching to.
public struct ScreenClipReportContext: Sendable {
  /// The report's id. Log it next to your own records (a backend request id, a session id) to tie them together.
  public var reportID: UUID
  /// When the screenshot was taken.
  public var capturedAt: Date
  /// The innermost visible screen title, if the app sets one.
  public var screenTitle: String?
  /// The visible view-controller chain, outermost first.
  public var screenPath: [String]

  public init(reportID: UUID = UUID(), capturedAt: Date = Date(), screenTitle: String? = nil, screenPath: [String] = []) {
    self.reportID = reportID
    self.capturedAt = capturedAt
    self.screenTitle = screenTitle
    self.screenPath = screenPath
  }
}

/// Collects your app's own attachments for a report. It runs off the main actor; read main-actor
/// state with `await MainActor.run { … }`. Throwing leaves this provider's files out of the report.
public typealias ScreenClipAttachmentProvider = @Sendable (ScreenClipReportContext) async throws -> [ScreenClipAttachment]

#if os(iOS) && DEBUG
  import ScreenClipWire

  /// The providers the app registered, in registration order, and the work of running them for one report.
  @MainActor final class AttachmentProviders {
    struct Registration {
      var id: String
      var timeout: Duration
      var provider: ScreenClipAttachmentProvider
    }

    static let maximumTimeout: Duration = .seconds(30)
    private(set) var registrations: [Registration] = []

    func set(_ id: String, timeout: Duration = .seconds(5), provider: @escaping ScreenClipAttachmentProvider) {
      let timeout = min(max(timeout, .zero), Self.maximumTimeout)
      let registration = Registration(id: id, timeout: timeout, provider: provider)
      if let index = registrations.firstIndex(where: { $0.id == id }) {
        registrations[index] = registration
      } else {
        registrations.append(registration)
      }
    }

    func remove(_ id: String) { registrations.removeAll { $0.id == id } }

    /// Providers started for one report. They run while the tester annotates.
    struct Run: Sendable {
      struct Started: Sendable {
        var id: String
        var timeout: Duration
        var task: Task<[ScreenClipAttachment]?, Never>
      }
      var started: [Started]

      /// Waits for each provider up to its timeout, counted from now, and returns their files in
      /// registration order with safe, unique names.
      func files(avoiding taken: Set<String>) async -> [DiagnosticFile] {
        let results = await withTaskGroup(of: (Int, [ScreenClipAttachment]?).self) { group in
          for (index, provider) in started.enumerated() {
            group.addTask {
              let clock = ContinuousClock()
              let started = clock.now
              let value = await KitRuntime.value(of: provider.task, timeout: provider.timeout.seconds)
              // A provider that threw has logged its own error, and one the tester cancelled says
              // nothing; both return before the timeout has passed.
              if value == nil, clock.now - started >= provider.timeout {
                kitLog.error("Attachment provider \(provider.id, privacy: .public) returned nothing in time")
              }
              return (index, value)
            }
          }
          var results = [[ScreenClipAttachment]?](repeating: nil, count: started.count)
          for await (index, value) in group { results[index] = value }
          return results
        }
        var names = taken
        var files: [DiagnosticFile] = []
        for (provider, attachments) in zip(started, results) {
          for attachment in attachments ?? [] {
            guard files.count < ScreenClipAttachment.maximumCount else {
              kitLog.error(
                "Left out \(attachment.name, privacy: .public) from \(provider.id, privacy: .public): a report takes up to \(ScreenClipAttachment.maximumCount) attachments"
              )
              continue
            }
            guard attachment.data.count <= ScreenClipAttachment.maximumBytes else {
              kitLog.error(
                "Left out \(attachment.name, privacy: .public) from \(provider.id, privacy: .public): \(attachment.data.count) bytes is over the 1 MB limit"
              )
              continue
            }
            let name = AttachmentProviders.fileName(for: attachment, avoiding: names)
            names.insert(name)
            let summary = attachment.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            files.append(
              DiagnosticFile(
                name: name, summary: String((summary.isEmpty ? "attached by the app" : summary).prefix(200)),
                data: attachment.data))
          }
        }
        return files
      }

      func cancel() { started.forEach { $0.task.cancel() } }
    }

    func start(_ context: ScreenClipReportContext) -> Run {
      Run(
        started: registrations.map { registration in
          let provider = registration.provider, id = registration.id
          // The tester is waiting on Send, so these run at user-initiated priority; utility work can
          // be held back for seconds on a busy device.
          let task = Task.detached(priority: .userInitiated) { () -> [ScreenClipAttachment]? in
            do {
              return try await provider(context)
            } catch {
              if !Task.isCancelled {
                kitLog.error("Attachment provider \(id, privacy: .public) failed: \(error.localizedDescription)")
              }
              return nil
            }
          }
          return Run.Started(id: id, timeout: registration.timeout, task: task)
        })
    }

    /// A name the Mac accepts (`[a-z0-9-]{1,40}.txt|json`) that no other file in the report uses.
    nonisolated static func fileName(for attachment: ScreenClipAttachment, avoiding taken: Set<String>) -> String {
      var stem = ""
      for character in attachment.name.lowercased() {
        let allowed = character.isASCII && (character.isLetter || character.isNumber)
        if allowed {
          stem.append(character)
        } else if !stem.isEmpty, stem.last != "-" {
          stem.append("-")
        }
      }
      stem = String(stem.prefix(32))
      while stem.last == "-" { stem.removeLast() }
      if stem.isEmpty { stem = "attachment" }
      let ext = attachment.format.rawValue
      var candidate = "\(stem).\(ext)"
      var number = 2
      while taken.contains(candidate) {
        candidate = "\(stem)-\(number).\(ext)"
        number += 1
      }
      return candidate
    }
  }

  extension Duration {
    var seconds: TimeInterval {
      let parts = components
      return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
  }
#endif
