// Shared by the Runner app and the NotificationService extension (the file is
// compiled into both targets). The sealed-push key and the relay address live
// in a keychain access group both can read; nothing here is ever logged.

import Foundation
import Security

enum PushKeychain {
  private static let service = "conduit.push"

  /// The keychain access group, `<team prefix>.am.tamm.conduit.push`, built
  /// into each target's Info.plist so no team id is written in code.
  private static var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "PushKeychainGroup") as? String
  }

  private static func query(_ account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let group = accessGroup, !group.isEmpty, !group.contains("$(") {
      query[kSecAttrAccessGroup as String] = group
    }
    return query
  }

  static func read(_ account: String) -> Data? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else {
      return nil
    }
    return item as? Data
  }

  @discardableResult
  static func write(_ account: String, data: Data) -> Bool {
    let match = query(account)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var add = match
    add[kSecValueData as String] = data
    // Readable while the phone is locked, so the extension can open a push
    // that arrives overnight.
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func delete(_ account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }
}
