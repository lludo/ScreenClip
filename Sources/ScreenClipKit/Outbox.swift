#if os(iOS) && DEBUG
  import Foundation
  import Observation
  import ScreenClipWire
  import Security

  /// Reports waiting for the Mac, one `.screenclipreport` file each, in Application Support
  /// (excluded from backups). A report is removed only after the Mac confirms it was saved.
  @MainActor @Observable final class Outbox {
    private(set) var reports: [WireReport] = []
    let directory: URL

    init() {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        .compactMap { try? ReportFile.read(from: $0) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func add(_ report: WireReport) throws {
      try ReportFile.write(report, to: url(for: report.id))
      reports.append(report)
    }

    func remove(_ id: UUID) {
      try? FileManager.default.removeItem(at: url(for: id))
      reports.removeAll { $0.id == id }
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

  enum PairingStore {
    private static let service = "com.mirageteam.screenclip.kit"
    private static let account = "pairings"

    static func load() -> [Pairing] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account, kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
        return []
      }
      return (try? JSONDecoder().decode([Pairing].self, from: data)) ?? []
    }

    static func save(_ pairings: [Pairing]) {
      guard let data = try? JSONEncoder().encode(pairings) else { return }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      SecItemDelete(query as CFDictionary)
      guard !pairings.isEmpty else { return }
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }
#endif
