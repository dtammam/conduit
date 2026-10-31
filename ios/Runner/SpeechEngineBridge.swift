import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers

private let conduitSpeechEngineChannelName = "app.cogwheel.conduit/speech_engine"
private let conduitSpeechEngineCaptureChannelName =
  "app.cogwheel.conduit/speech_engine_capture"

/// Carries microphone PCM from the engine's tap to Dart.
private final class CaptureStreamHandler: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

/// Dart's handle on [SpeechEngineQueue]: streamed speech played as one
/// continuous waveform. Calls arrive in order from one Dart queue; decoding
/// runs off the main thread.
final class SpeechEngineBridge: ConduitBridge {
  static let shared = SpeechEngineBridge()

  private var methodChannel: FlutterMethodChannel?
  private var speech: SpeechEngineQueue?
  private let work = DispatchQueue(label: "app.cogwheel.conduit.speech-engine-bridge")
  private var configurationObserver: NSObjectProtocol?
  private let capture = CaptureStreamHandler()
  private var captureChannel: FlutterEventChannel?
  /// The pending release of the device's audio after playback (on [work]).
  private var releaseItem: DispatchWorkItem?
  private var lastRate: Float = 1
  private weak var host: ConduitBridgeHost?

  /// How long the engine waits after the queue drains or playback stops before
  /// it gives the audio back: long enough for the next sentence or reply to
  /// start without the session going off and on.
  static let releaseAfterStop: TimeInterval = 1.5
  static let releaseAfterPause: TimeInterval = 30

  private init() {}

  func attach(to host: ConduitBridgeHost) {
    let channel = FlutterMethodChannel(
      name: conduitSpeechEngineChannelName,
      binaryMessenger: host.messenger
    )
    methodChannel = channel
    self.host = host
    let events = FlutterEventChannel(
      name: conduitSpeechEngineCaptureChannelName,
      binaryMessenger: host.messenger
    )
    events.setStreamHandler(capture)
    captureChannel = events
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      if call.method == "shareAudioFile" {
        self.shareAudioFile(args, result: result)
        return
      }
      self.work.async {
        let reply: Any?
        do {
          reply = try self.handle(call.method, args)
        } catch {
          reply = FlutterError(
            code: "speech_engine",
            message: error.localizedDescription,
            details: nil
          )
        }
        DispatchQueue.main.async { result(reply) }
      }
    }
  }

  /// Shares a rendered reply (Share as MP3) as a real file: an item provider
  /// with the file's own type (public.mp3) and name. share_plus hands share
  /// extensions a lazily resolved file URL, and Discord's extension got no
  /// attachment from it (2026-10-31); Messages, Mail, Files and AirDrop take
  /// the provider as well. Answers when the sheet closes: true when shared.
  private func shareAudioFile(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "share", message: "The file is missing", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    DispatchQueue.main.async {
      guard let root = self.topController(from: self.host?.presentingViewController) else {
        result(FlutterError(code: "share", message: "Nothing to present from", details: nil))
        return
      }
      let provider = NSItemProvider()
      let type = UTType(filenameExtension: url.pathExtension) ?? .mp3
      provider.registerFileRepresentation(
        forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
      ) { completion in
        completion(url, false, nil)
        return nil
      }
      provider.suggestedName = url.deletingPathExtension().lastPathComponent
      let sheet = UIActivityViewController(activityItems: [provider], applicationActivities: nil)
      if let title = args["title"] as? String, !title.isEmpty {
        sheet.title = title
      }
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = root.view
        let x = args["x"] as? Double, y = args["y"] as? Double
        let w = args["w"] as? Double, h = args["h"] as? Double
        if let x, let y, let w, let h {
          popover.sourceRect = CGRect(x: x, y: y, width: w, height: h)
        } else {
          popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
        }
      }
      var answered = false
      sheet.completionWithItemsHandler = { _, completed, _, _ in
        guard !answered else { return }
        answered = true
        result(completed)
      }
      root.present(sheet, animated: true)
    }
  }

  private func topController(from root: UIViewController?) -> UIViewController? {
    if let navigation = root as? UINavigationController {
      return topController(from: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topController(from: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController, !presented.isBeingDismissed {
      return topController(from: presented)
    }
    return root
  }

  private func queue() -> SpeechEngineQueue {
    if let speech { return speech }
    let created = SpeechEngineQueue()
    created.onEvent = { [weak self] event in self?.send(event) }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: created.engine,
      queue: nil
    ) { [weak self] _ in
      created.noteConfigurationChange()
      // A route or format change stops the engine; carry on where it was.
      self?.work.async {
        do {
          try created.recoverAfterConfigurationChange()
        } catch {
          self?.sendFailure(error)
        }
      }
    }
    speech = created
    return created
  }

  /// A voice call owns the audio session (the call coordinator configures it);
  /// read-aloud must then neither change its category nor release it.
  ///
  /// A play-and-record session counts as a call whatever its mode: the call's
  /// speaking phase can be playAndRecord with spokenAudio (when CallKit owns the
  /// session), and read-aloud used to switch that to playback mid-call, so the
  /// next listening turn found no microphone (crash at a call start,
  /// 2026-10-31). Read-aloud outside a call configures playback first itself.
  private func callActive(_ speech: SpeechEngineQueue?) -> Bool {
    if speech?.inCall == true { return true }
    if VoiceBackgroundAudioManager.shared.isSessionActive { return true }
    let session = AVAudioSession.sharedInstance()
    return session.mode == .voiceChat || session.category == .playAndRecord
  }

  /// Before a call touches the microphone: no release may be pending, and the
  /// session must allow input and be active, or AVAudioEngine's input node
  /// reports 0 Hz and 0 channels. A session left on read-aloud's playback is
  /// put on play-and-record (voice chat, Bluetooth, loudspeaker); one the call
  /// coordinator already configured is left as it is.
  private func prepareCallSession() throws {
    cancelRelease()
    let session = AVAudioSession.sharedInstance()
    if session.category != .playAndRecord {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .defaultToSpeaker]
      )
    }
    try session.setActive(true)
    guard session.isInputAvailable else {
      throw SpeechEngineQueue.EngineError(message: "The microphone isn't available right now")
    }
  }

  /// Read-aloud outside a call: plain playback that lowers other apps' audio
  /// instead of pausing it, and no microphone (2026-10-31: Dean's YouTube paused
  /// and other apps' dictation failed while this engine sat on playAndRecord).
  private func usePlaybackSession() {
    let session = AVAudioSession.sharedInstance()
    guard session.category != .playback || session.mode != .spokenAudio
            || !session.categoryOptions.contains(.duckOthers) else { return }
    try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
  }

  private func scheduleRelease(after seconds: TimeInterval) {
    work.async { [weak self] in
      guard let self else { return }
      self.releaseItem?.cancel()
      let item = DispatchWorkItem { [weak self] in self?.releaseNow() }
      self.releaseItem = item
      self.work.asyncAfter(deadline: .now() + seconds, execute: item)
    }
  }

  private func cancelRelease() {
    releaseItem?.cancel()
    releaseItem = nil
  }

  /// Stops the idle engine and gives the device's audio back to other apps
  /// (they may resume: notifyOthersOnDeactivation). On [work].
  private func releaseNow() {
    releaseItem = nil
    guard let speech, !callActive(speech) else { return }
    guard speech.releaseIfIdle() else { return }
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  /// Drops the engine; the next call makes a fresh one. After a call the
  /// engine's input stays in its graph, so it would open the microphone for
  /// every read-aloud.
  private func discardQueue() {
    speech?.shutDown()
    if let observer = configurationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    configurationObserver = nil
    speech = nil
  }

  private func handle(_ method: String, _ args: [String: Any]) throws -> Any? {
    switch method {
    case "pause", "stop", "diagnostics", "log", "dispose": break
    default: cancelRelease()
    }
    if method == "reset", let old = speech, old.inputUsed, !callActive(old) {
      discardQueue()
    }
    let fresh = speech == nil
    let speech = queue()
    if fresh, lastRate != 1 { speech.setRate(lastRate) }
    switch method {
    case "reset":
      try speech.reset()
    case "appendPiece":
      guard let item = args["item"] as? Int,
            let bytes = args["bytes"] as? FlutterStandardTypedData
      else { return false }
      let trim = (args["trim"] as? Bool ?? false)
        ? SpeechEngineQueue.PieceTrim.streamedMp3
        : SpeechEngineQueue.PieceTrim.none
      try speech.appendPiece(item: item, data: bytes.data, trim: trim)
    case "finishItem":
      guard let item = args["item"] as? Int else { return false }
      try speech.finishItem(item)
    case "play":
      if !callActive(speech) { usePlaybackSession() }
      try? AVAudioSession.sharedInstance().setActive(true)
      VoiceAudioRouteBridge.shared.restoreSpeakerIfNeeded(reason: "play")
      try speech.play()
    case "pause":
      try speech.pause()
      scheduleRelease(after: Self.releaseAfterPause)
    case "stop":
      try speech.stop()
      scheduleRelease(after: Self.releaseAfterStop)
    case "seek":
      guard let item = args["item"] as? Int else { return false }
      try speech.seek(toItem: item)
    case "setRate":
      lastRate = Float(args["rate"] as? Double ?? 1)
      speech.setRate(lastRate)
    case "setVoiceProcessing":
      let on = args["on"] as? Bool ?? false
      if on { try prepareCallSession() }
      try speech.setVoiceProcessing(on)
      if !on { scheduleRelease(after: Self.releaseAfterStop) }
    case "startCapture":
      let rate = args["sampleRate"] as? Double ?? 16000
      try prepareCallSession()
      try speech.startCapture(sampleRate: rate) { [weak self] data in
        DispatchQueue.main.async {
          self?.capture.sink?(FlutterStandardTypedData(bytes: data))
        }
      }
    case "stopCapture":
      try speech.stopCapture()
      scheduleRelease(after: Self.releaseAfterStop)
    case "diagnostics":
      return speech.diagnostics(
        reset: args["reset"] as? Bool ?? false,
        extra: args["extra"] as? [String: Any] ?? [:]
      )
    case "log":
      speech.logNotice(args["message"] as? String ?? "")
    case "dispose":
      cancelRelease()
      let call = callActive(speech)
      speech.shutDown()
      if !call {
        try? AVAudioSession.sharedInstance().setActive(
          false,
          options: .notifyOthersOnDeactivation
        )
      }
    default:
      return FlutterMethodNotImplemented
    }
    return true
  }

  /// The engine failed outside a call (a route change); Dart falls back.
  private func sendFailure(_ error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel?.invokeMethod(
        "event",
        arguments: ["type": "failed", "message": error.localizedDescription]
      )
    }
  }

  private func send(_ event: SpeechEngineQueue.Event) {
    let payload: [String: Any]
    switch event {
    case .itemStarted(let item): payload = ["type": "started", "item": item]
    case .starved: payload = ["type": "starved"]
    case .drained:
      payload = ["type": "drained"]
      scheduleRelease(after: Self.releaseAfterStop)
    }
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel?.invokeMethod("event", arguments: payload)
    }
  }
}
