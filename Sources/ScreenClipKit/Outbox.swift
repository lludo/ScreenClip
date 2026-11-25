#if os(iOS) && DEBUG
  import Foundation
  import Observation
  import ScreenClipWire

  /// Reports waiting for the Mac, one `.screenclipreport` file each, in Application Support
  /// (excluded from backups). A report is removed only after the Mac confirms it was saved.
  @MainActor @Observable final class Outbox {
    private(set) var reports: [ReportFile.Summary] = []
    let directory: URL

    init(base: URL = URL.applicationSupportDirectory) {
      directory = base.appendingPathComponent("ScreenClipKit/Outbox", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var url = directory
      try? url.setResourceValues(values)
      reload()
    }

    var count: Int { reports.count }

    func url(for id: UUID) -> URL {
      directory.appendingPathComponent("\(id.uuidString).\(ReportFile.pathExtension)")
    }

    func reload() {
      let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      reports = files.filter { $0.pathExtension == ReportFile.pathExtension }
        .compactMap { file in autoreleasepool { try? ReportFile.summary(from: file) } }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func add(_ report: WireReport) throws {
      try ReportFile.write(report, to: url(for: report.id))
      let summary = ReportFile.Summary(report)
      if let index = reports.firstIndex(where: { $0.id == report.id }) {
        reports[index] = summary
      } else {
        reports.append(summary)
      }
    }

    func remove(_ id: UUID) throws {
      do { try FileManager.default.removeItem(at: url(for: id)) }
      catch let error as CocoaError where error.code == .fileNoSuchFile { }
      reports.removeAll { $0.id == id }
    }
  }

  /// Reports already delivered, with where each stands on the Mac. Kept for 30 days, at most 50.
  @MainActor @Observable final class SentLog {
    struct Entry: Codable, Identifiable, Equatable {
      var id: UUID
      var note: String
      var createdAt: Date
      var sentAt: Date
      var macName: String
      var macID: UUID?
      var state: ReportState?
      var destination: ReportDestination { ReportDestination(macID: macID, name: macName) }
    }
    private(set) var entries: [Entry] = []
    private let url: URL

    init(base: URL = URL.applicationSupportDirectory) {
      url = base.appendingPathComponent("ScreenClipKit/sent.json")
      if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
        entries = saved
      }
      let before = entries.count
      prune()
      if entries.count != before { try? save() }
    }

    /// Ids the Mac should report on, most recent first.
    func trackedIDs(macID: UUID, name: String?) -> [UUID] {
      entries.filter { $0.destination.matches(macID: macID, name: name) }.map(\.id)
    }

    func record(_ report: ReportFile.Summary, macID: UUID, macName: String) throws {
      let previous = entries
      entries.removeAll { $0.id == report.id }
      entries.insert(
        Entry(id: report.id, note: report.note, createdAt: report.createdAt, sentAt: Date(), macName: macName, macID: macID), at: 0)
      prune()
      do {
        try save()
      } catch {
        entries = previous
        throw error
      }
    }

    func update(_ states: [ReportState], macID: UUID, name: String?) {
      var changed = false
      for state in states {
        guard let index = entries.firstIndex(where: { $0.id == state.id && $0.destination.matches(macID: macID, name: name) }),
          entries[index].state != state || entries[index].macID == nil else { continue }
        entries[index].macID = macID
        entries[index].state = state
        changed = true
      }
      if changed { try? save() }
    }

    func remove(_ id: UUID) {
      entries.removeAll { $0.id == id }
      try? save()
    }

    private func prune() {
      let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
      entries = Array(entries.filter { $0.sentAt > cutoff }.prefix(50))
    }

    private func save() throws {
      try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
  }

  /// Pairings with Macs, kept in the Keychain (this device only).
  struct Pairing: Codable, Equatable, Identifiable {
    var macID: UUID
    var macName: String
    var key: Data
    var pairedAt: Date
    var id: UUID { macID }
  }

#endif
