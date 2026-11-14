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
  }

  static func load() -> ExternalAssistantConfiguration {
    guard let data = read(), let record = try? JSONDecoder().decode(Record.self, from: data) else {
      return .empty
    }
    return ExternalAssistantConfiguration(
      webhookURL: record.webhookURL, authorization: record.authorization,
      testSucceeded: record.testSucceeded)
  }

  static func save(_ configuration: ExternalAssistantConfiguration) throws {
    let data = try JSONEncoder().encode(
      Record(
        webhookURL: configuration.normalizedURL,
        authorization: configuration.normalizedAuthorization,
        testSucceeded: configuration.testSucceeded && configuration.isConfigured))
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    var query = base
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw ScreenClipError.message(
        "Could not save the Grok Bot connection in the Keychain (error \(status)).")
    }
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
