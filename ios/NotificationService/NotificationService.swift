import CryptoKit
import Foundation
import UserNotifications

/// Opens the sealed text of a routine push. The relay sends Apple only a
/// placeholder plus `e`, the real title, body and ids sealed with a key that
/// never leaves this phone (AES-256-GCM, CryptoKit's combined layout:
/// nonce, ciphertext, tag). Any failure leaves the placeholder as it came.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent
    else {
      contentHandler(request.content)
      return
    }
    bestAttempt = content
    if let sealed = Self.open(content.userInfo) {
      Self.apply(sealed, to: content)
    }
    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }

  /// The sealed JSON in `userInfo["e"]`, or nil when it is absent, the key is
  /// missing or anything does not verify.
  static func open(_ userInfo: [AnyHashable: Any]) -> [String: Any]? {
    guard let encoded = userInfo["e"] as? String,
      let combined = decodeBase64(encoded),
      let keyData = PushKeychain.read("e2e-key"), keyData.count == 32,
      let box = try? AES.GCM.SealedBox(combined: combined),
      let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
      let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    else { return nil }
    return object
  }

  static func decodeBase64(_ text: String) -> Data? {
    if let data = Data(base64Encoded: text) { return data }
    var url = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while url.count % 4 != 0 { url += "=" }
    return Data(base64Encoded: url)
  }

  static func apply(_ sealed: [String: Any], to content: UNMutableNotificationContent) {
    if let title = sealed["title"] as? String, !title.isEmpty { content.title = title }
    if let body = sealed["body"] as? String, !body.isEmpty { content.body = body }
    var userInfo = content.userInfo
    for key in ["id", "chat_id", "message_id", "slug"] {
      if let value = sealed[key] as? String, !value.isEmpty { userInfo[key] = value }
    }
    // The ciphertext has done its job; the app does not need it.
    userInfo.removeValue(forKey: "e")
    content.userInfo = userInfo
    if let slug = sealed["slug"] as? String, !slug.isEmpty {
      content.threadIdentifier = slug
    }
  }
}
