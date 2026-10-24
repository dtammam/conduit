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

  private func handle(_ method: String, _ args: [String: Any]) throws -> Any? {
    let speech = queue()
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
      try? AVAudioSession.sharedInstance().setActive(true)
      VoiceAudioRouteBridge.shared.restoreSpeakerIfNeeded(reason: "play")
      try speech.play()
    case "pause":
      try speech.pause()
    case "stop":
      try speech.stop()
    case "seek":
      guard let item = args["item"] as? Int else { return false }
      try speech.seek(toItem: item)
    case "setRate":
      speech.setRate(Float(args["rate"] as? Double ?? 1))
    case "setVoiceProcessing":
      try speech.setVoiceProcessing(args["on"] as? Bool ?? false)
    case "startCapture":
      let rate = args["sampleRate"] as? Double ?? 16000
      try speech.startCapture(sampleRate: rate) { [weak self] data in
        DispatchQueue.main.async {
          self?.capture.sink?(FlutterStandardTypedData(bytes: data))
        }
      }
    case "stopCapture":
      try speech.stopCapture()
    case "diagnostics":
      return speech.diagnostics(
        reset: args["reset"] as? Bool ?? false,
        extra: args["extra"] as? [String: Any] ?? [:]
      )
    case "log":
      speech.logNotice(args["message"] as? String ?? "")
    case "dispose":
      speech.shutDown()
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
    case .drained: payload = ["type": "drained"]
    }
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel?.invokeMethod("event", arguments: payload)
    }
  }
}
