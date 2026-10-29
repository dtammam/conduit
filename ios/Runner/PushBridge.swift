// FLUTTER HOST ONLY. Apple push for routine notifications, without Firebase.
// The Flutter app delegate forwards the token callbacks and the notification
// center's delegate calls to it, and it talks to Dart over one method channel.

import CryptoKit
import Flutter
import UIKit
import UserNotifications

/// Registers this phone for Apple push, keeps the key that seals each push's
/// text (the Notification Service Extension opens it), answers the routine
/// notification actions and hands taps and typed replies to Dart.
///
/// Apple only ever carries a placeholder; see `NotificationService`.
final class PushBridge: NSObject {
  static let shared = PushBridge()

  private static let channelName = "am.tamm.conduit/push"
  static let routineCategory = "ROUTINE"
  static let messageCategory = "MESSAGE"
  static let replyAction = "ROUTINE_REPLY"
  static let snoozeAction = "ROUTINE_SNOOZE"
  static let doneAction = "ROUTINE_DONE"
  private static let tokenDefaultsKey = "push.apns.token"
  private static let snoozeMinutes = 60

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var pending: [[String: Any]] = []

  private override init() {
    super.init()
  }

  func configure(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      authorization { result($0) }
    case "requestAuthorization":
      registerCategories()
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { [weak self] granted, _ in
        DispatchQueue.main.async {
          if granted { UIApplication.shared.registerForRemoteNotifications() }
          self?.authorization { result($0) }
        }
      }
    case "registerIfAuthorized":
      registerCategories()
      authorization { status in
        let state = status["authorization"] as? String
        if state == "authorized" || state == "provisional" || state == "ephemeral" {
          DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
        result(status)
      }
    case "registration":
      result(registration())
    case "configureRelay":
      guard let args = call.arguments as? [String: Any],
        let url = args["url"] as? String, let token = args["token"] as? String,
        let data = try? JSONSerialization.data(withJSONObject: ["url": url, "token": token])
      else {
        result(false)
        return
      }
      result(PushKeychain.write("relay", data: data))
    case "unregister":
      UserDefaults.standard.removeObject(forKey: Self.tokenDefaultsKey)
      DispatchQueue.main.async {
        UIApplication.shared.unregisterForRemoteNotifications()
        result(nil)
      }
    case "drainEvents":
      dartReady = true
      let events = pending
      pending = []
      result(events)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authorization(_ done: @escaping ([String: Any]) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let state: String
      switch settings.authorizationStatus {
      case .authorized: state = "authorized"
      case .denied: state = "denied"
      case .provisional: state = "provisional"
      case .ephemeral: state = "ephemeral"
      default: state = "notDetermined"
      }
      let registered = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey) != nil
      DispatchQueue.main.async {
        done([
          "authorization": state,
          "registered": registered,
          "env": Self.apsEnvironment(),
        ])
      }
    }
  }

  /// What the server needs to register this phone, or nil values until Apple
  /// has handed out a token.
  private func registration() -> [String: Any] {
    var out: [String: Any] = [
      "env": Self.apsEnvironment(),
      "bundle": Bundle.main.bundleIdentifier ?? "",
      "name": UIDevice.current.name,
    ]
    if let token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey) {
      out["token"] = token
    }
    if let key = sealingKey() { out["key"] = key.base64EncodedString() }
    return out
  }

  /// The 32 random bytes that seal this phone's pushes: made once, kept in
  /// the keychain group the extension reads.
  private func sealingKey() -> Data? {
    if let existing = PushKeychain.read("e2e-key"), existing.count == 32 {
      return existing
    }
    let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    return PushKeychain.write("e2e-key", data: fresh) ? fresh : nil
  }

  /// "sandbox" or "production", read from the provisioning profile this
  /// build was signed with: a development profile (every Xcode and
  /// devicectl install, Release configuration included) is issued sandbox
  /// tokens; a build with no embedded profile came through TestFlight or the
  /// App Store.
  static func apsEnvironment() -> String {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .isoLatin1),
      let range = text.range(of: "<key>aps-environment</key>")
    else { return "production" }
    let tail = text[range.upperBound...].prefix(120)
    return tail.contains("<string>development</string>") ? "sandbox" : "production"
  }

  // MARK: - App delegate callbacks

  func didRegister(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(hex, forKey: Self.tokenDefaultsKey)
    emit(["kind": "token", "token": hex])
  }

  func didFailToRegister(_ error: Error) {
    emit(["kind": "registrationFailed"])
  }

  /// Declares the routine actions. Merged with the categories other code
  /// (a plugin) already set, so neither replaces the other.
  func registerCategories() {
    let reply = UNTextInputNotificationAction(
      identifier: Self.replyAction,
      title: NSLocalizedString("push.action.reply", value: "Reply", comment: ""),
      options: [.foreground],
      textInputButtonTitle: NSLocalizedString("push.action.send", value: "Send", comment: ""),
      textInputPlaceholder: NSLocalizedString("push.action.reply", value: "Reply", comment: "")
    )
    let snooze = UNNotificationAction(
      identifier: Self.snoozeAction,
      title: NSLocalizedString("push.action.snooze", value: "Snooze 1 hour", comment: ""),
      options: []
    )
    let done = UNNotificationAction(
      identifier: Self.doneAction,
      title: NSLocalizedString("push.action.done", value: "Done", comment: ""),
      options: []
    )
    let routine = UNNotificationCategory(
      identifier: Self.routineCategory,
      actions: [reply, snooze, done],
      intentIdentifiers: [],
      options: []
    )
    let message = UNNotificationCategory(
      identifier: Self.messageCategory,
      actions: [reply, done],
      intentIdentifiers: [],
      options: []
    )
    let center = UNUserNotificationCenter.current()
    center.getNotificationCategories { existing in
      let ours: Set<String> = [Self.routineCategory, Self.messageCategory]
      var merged = existing.filter { !ours.contains($0.identifier) }
      merged.insert(routine)
      merged.insert(message)
      center.setNotificationCategories(merged)
    }
  }

  /// Whether a notification came from the routines server.
  static func isRoutinePush(_ notification: UNNotification) -> Bool {
    let content = notification.request.content
    return content.categoryIdentifier == routineCategory
      || content.categoryIdentifier == messageCategory
  }

  /// Handles a tap or an action on a routine notification. Returns false for
  /// any other notification so the plugins get it.
  func handle(
    response: UNNotificationResponse,
    completion: @escaping () -> Void
  ) -> Bool {
    guard Self.isRoutinePush(response.notification) else { return false }
    let info = response.notification.request.content.userInfo
    var base: [String: Any] = [:]
    for key in ["id", "chat_id", "message_id", "slug"] {
      if let value = info[key] as? String { base[key] = value }
    }
    switch response.actionIdentifier {
    case Self.snoozeAction:
      snooze(id: base["id"] as? String, completion: completion)
    case Self.replyAction:
      if let typed = response as? UNTextInputNotificationResponse {
        let text = typed.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          emit(base.merging(["kind": "reply", "text": text]) { $1 })
        }
      }
      completion()
    case UNNotificationDefaultActionIdentifier:
      emit(base.merging(["kind": "open"]) { $1 })
      completion()
    default:
      // Done, and a swipe away: nothing to do.
      completion()
    }
    return true
  }

  /// POSTs the snooze to the routines server with the stored address and
  /// token, with the app running only for as long as the request takes.
  private func snooze(id: String?, completion: @escaping () -> Void) {
    guard let id = id, !id.isEmpty,
      let data = PushKeychain.read("relay"),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let base = config["url"], let token = config["token"],
      let url = URL(string: base + "/push/snooze")
    else {
      completion()
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "id": id, "minutes": Self.snoozeMinutes,
    ])
    var task = UIBackgroundTaskIdentifier.invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "routine-snooze") {
      UIApplication.shared.endBackgroundTask(task)
      task = .invalid
    }
    URLSession.shared.dataTask(with: request) { _, _, _ in
      DispatchQueue.main.async {
        completion()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
      }
    }.resume()
  }

  // MARK: - To Dart

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [self] in
      if dartReady, let channel = channel {
        channel.invokeMethod("event", arguments: event)
      } else {
        pending.append(event)
      }
    }
  }
}
