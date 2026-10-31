import AVFoundation
import Flutter

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
  private func callActive(_ speech: SpeechEngineQueue?) -> Bool {
    if speech?.inCall == true { return true }
    if VoiceBackgroundAudioManager.shared.isSessionActive { return true }
    return AVAudioSession.sharedInstance().mode == .voiceChat
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
      try speech.setVoiceProcessing(on)
      if !on { scheduleRelease(after: Self.releaseAfterStop) }
    case "startCapture":
      let rate = args["sampleRate"] as? Double ?? 16000
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
