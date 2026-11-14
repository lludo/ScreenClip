import Foundation
import ScreenClipCore
import Security

enum ExternalAssistantKeychain {
  private static let service = "com.screenclip.app.external-assistant"
  private static let account = "connection"

  private struct Record: Codable {
    var webhookURL: String
    var authorization: String
    var testSucceeded: Bool
    /// Not secret. Missing on items saved before cancel support.
    var capabilities: [String]?
  }

  static func load() -> ExternalAssistantConfiguration {
    guard let data = read(), let record = try? JSONDecoder().decode(Record.self, from: data) else {
      return .empty
    }
    return ExternalAssistantConfiguration(
      webhookURL: record.webhookURL, authorization: record.authorization,
      testSucceeded: record.testSucceeded, capabilities: record.capabilities ?? [])
  }

  static func save(_ configuration: ExternalAssistantConfiguration) throws {
    // Clearing both fields removes the item instead of storing empty strings.
    if configuration.normalizedURL.isEmpty && configuration.normalizedAuthorization.isEmpty {
      let status = SecItemDelete(baseQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ScreenClipError.message(
          "Could not remove the Grok Bot connection from the Keychain (error \(status)).")
      }
      return
    }
    let current = load()
    if current.normalizedURL == configuration.normalizedURL
      && current.normalizedAuthorization == configuration.normalizedAuthorization
      && current.testSucceeded == (configuration.testSucceeded && configuration.isConfigured)
      && current.capabilities == configuration.capabilities
    {
      return  // Unchanged: avoid rewriting the item on every Settings save.
    }
    let data = try JSONEncoder().encode(
      Record(
        webhookURL: configuration.normalizedURL,
        authorization: configuration.normalizedAuthorization,
        testSucceeded: configuration.testSucceeded && configuration.isConfigured,
        capabilities: configuration.capabilities))
    let base = baseQuery
    let updated = SecItemUpdate(
      base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw ScreenClipError.message(
        "Could not save the Grok Bot connection in the Keychain (error \(updated)).")
    }
    var query = base
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw ScreenClipError.message(
        "Could not save the Grok Bot connection in the Keychain (error \(status)).")
    }
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func read() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data
  }
}
