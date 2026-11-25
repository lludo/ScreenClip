#if !os(iOS) || DEBUG
import Foundation
import Security

/// Both endpoints keep their existing service, account, JSON format and accessibility.
public struct PairingKeychain<Record: Codable>: Sendable {
  private let service: String
  private let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  public func load() throws -> [Record] {
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &item)
    if status == errSecItemNotFound { return [] }
    try check(status)
    guard let data = item as? Data else { throw WireError.malformed }
    return try JSONDecoder().decode([Record].self, from: data)
  }

  public func save(_ records: [Record]) throws {
    if records.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      if status != errSecItemNotFound { try check(status) }
      return
    }
    let data = try JSONEncoder().encode(records)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard status == errSecItemNotFound else { return try check(status) }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    try check(SecItemAdd(add as CFDictionary, nil))
  }

  private func check(_ status: OSStatus) throws {
    if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
}
#endif
