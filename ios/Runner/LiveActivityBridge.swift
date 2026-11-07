// Registers the next-event Live Activity tokens with the relay. The relay
// starts and updates the activity (push-to-start); the app only hands over the
// tokens and forgets them when an activity ends. Native end to end: it reads
// the relay address and bearer that PushBridge keeps in the keychain ("relay"),
// the same ones the snooze action uses, so no Dart is involved.
// See docs/MUSEY-LIVE-ACTIVITY.md.

import ActivityKit
import UIKit

final class LiveActivityBridge {
  static let shared = LiveActivityBridge()

  private var started = false
  /// Last tokens, resent when the app becomes active (the relay address may
  /// arrive from Dart after launch). The relay treats a repeat as a no-op.
  private var startToken: String?
  private var updateTokens: [String: String] = [:]
  private var observed = Set<String>()
  private let queue = DispatchQueue(label: "am.tamm.conduit.liveactivity")

  private init() {}

  /// Idempotent. Call once at launch.
  func start() {
    guard !started else { return }
    started = true
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.resend() }
    guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    if #available(iOS 17.2, *) {
      Task { [weak self] in
        for await data in Activity<NextEventAttributes>.pushToStartTokenUpdates {
          self?.gotStartToken(Self.hex(data))
        }
      }
    }
    Task { [weak self] in
      for await activity in Activity<NextEventAttributes>.activityUpdates {
        self?.observe(activity)
      }
    }
    // Activities that outlived a launch (started by the relay while the app
    // was not running) are not replayed to activityUpdates.
    for activity in Activity<NextEventAttributes>.activities { observe(activity) }
  }

  // MARK: - Observing

  @available(iOS 16.2, *)
  private func observe(_ activity: Activity<NextEventAttributes>) {
    let id = activity.id
    let fresh: Bool = queue.sync { observed.insert(id).inserted }
    guard fresh else { return }
    Task { [weak self] in
      for await data in activity.pushTokenUpdates {
        self?.gotUpdateToken(Self.hex(data), activityId: id)
      }
    }
    Task { [weak self] in
      for await state in activity.activityStateUpdates {
        if state == .ended || state == .dismissed {
          self?.activityEnded(id)
          break
        }
      }
    }
  }

  private func gotStartToken(_ token: String) {
    queue.sync { startToken = token }
    post("/push/live-activity/start-token", ["token": token])
  }

  private func gotUpdateToken(_ token: String, activityId: String) {
    queue.sync { updateTokens[activityId] = token }
    post("/push/live-activity/update-token", ["token": token, "activityId": Self.safeId(activityId)])
  }

  private func activityEnded(_ id: String) {
    let token: String? = queue.sync {
      observed.remove(id)
      return updateTokens.removeValue(forKey: id)
    }
    if let token { post("/push/live-activity/remove", ["token": token]) }
  }

  private func resend() {
    let (start, updates): (String?, [String: String]) = queue.sync { (startToken, updateTokens) }
    if let start { post("/push/live-activity/start-token", ["token": start]) }
    for (id, token) in updates {
      post("/push/live-activity/update-token", ["token": token, "activityId": Self.safeId(id)])
    }
  }

  // MARK: - Relay

  /// Letters, digits and dashes, up to 64 (the relay's rule).
  static func safeId(_ id: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    return String(id.filter { allowed.contains($0) }.prefix(64))
  }

  static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private func post(_ path: String, _ fields: [String: String]) {
    guard let data = PushKeychain.read("relay"),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let base = config["url"], let bearer = config["token"],
      let url = URL(string: base + path)
    else { return }
    var body = fields
    if path != "/push/live-activity/remove" {
      body["env"] = PushBridge.apsEnvironment()
      body["bundle"] = Bundle.main.bundleIdentifier ?? ""
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
  }
}
