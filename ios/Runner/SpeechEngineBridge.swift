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
      if call.method == "exportM4a" {
        self.exportM4a(args, result: result)
        return
      }
      if call.method == "saveAudioFile" {
        self.saveAudioFile(args, result: result)
        return
      }
      if call.method == "excludeFromBackup" {
        // Saved reply audio stays on the phone: out of iCloud and backups.
        var url = URL(fileURLWithPath: args["path"] as? String ?? "")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
          try url.setResourceValues(values)
          result(true)
        } catch {
          result(false)
        }
        return
      }
      if call.method == "makeReplyVideo" {
        ReplyVideoMaker.make(args) { reply in DispatchQueue.main.async { result(reply) } }
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

  /// Shares a file (the reply's .m4a, or the video) as a plain file URL and
  /// nothing else: Discord's extension attaches that. Answers when the sheet
  /// closes with {completed, activityType}.
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
      // Only the file, as a plain file URL: no text, title or subject. With an
      // item provider, Discord's extension took a text item and showed no
      // attachment (2026-10-31).
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
      sheet.completionWithItemsHandler = { activity, completed, _, _ in
        guard !answered else { return }
        answered = true
        result(["completed": completed, "activityType": activity?.rawValue ?? ""] as [String: Any])
      }
      root.present(sheet, animated: true)
    }
  }

  /// Converts a rendered reply to an AAC .m4a in NSTemporaryDirectory()/share/
  /// (AVAssetExportPresetAppleM4A). Discord's share extension attaches this as
  /// a plain file URL and does not attach an MP3 (Dean's tests, 2026-11-01);
  /// Messages, Mail, Files and AirDrop take m4a too. Answers the new path.
  private func exportM4a(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "share", message: "The file is missing", details: nil))
      return
    }
    let source = URL(fileURLWithPath: path)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("share", isDirectory: true)
    let out = dir.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent).m4a")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: out)
    } catch {
      result(FlutterError(code: "share", message: error.localizedDescription, details: nil))
      return
    }
    guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
      result(FlutterError(code: "share", message: "cannot export m4a", details: nil))
      return
    }
    export.outputURL = out
    export.outputFileType = .m4a
    export.exportAsynchronously {
      DispatchQueue.main.async {
        if export.status == .completed {
          result(out.path)
        } else {
          result(FlutterError(code: "share", message: export.error?.localizedDescription ?? "the m4a export failed", details: nil))
        }
      }
    }
  }

  /// Save to Files: the system's export picker with a copy of the file.
  /// Answers true when a place was picked.
  private func saveAudioFile(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, FileManager.default.isReadableFile(atPath: path) else {
      result(FlutterError(code: "save", message: "The file is missing", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    DispatchQueue.main.async {
      guard let root = self.topController(from: self.host?.presentingViewController) else {
        result(FlutterError(code: "save", message: "Nothing to present from", details: nil))
        return
      }
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      let delegate = AudioSavePickerDelegate { picked in result(picked) }
      picker.delegate = delegate
      objc_setAssociatedObject(picker, &AudioSavePickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
      root.present(picker, animated: true)
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
    case "pause", "stop", "diagnostics", "log", "dispose", "setGain", "playbackPosition": break
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
    case "appendStreamBytes":
      guard let item = args["item"] as? Int,
            let bytes = args["bytes"] as? FlutterStandardTypedData
      else { return false }
      try speech.appendStreamBytes(
        item: item,
        data: bytes.data,
        isLast: args["isLast"] as? Bool ?? false
      )
    case "appendPcm16":
      guard let item = args["item"] as? Int,
            let bytes = args["bytes"] as? FlutterStandardTypedData
      else { return false }
      try speech.appendPcm16(
        item: item,
        data: bytes.data,
        sampleRate: args["sampleRate"] as? Double ?? 24000,
        isLast: args["isLast"] as? Bool ?? false
      )
    case "playbackPosition":
      guard let pos = speech.playbackPosition() else { return nil }
      return ["item": pos.item, "posMs": pos.posMs]
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
    case "setGain":
      speech.setGain(
        Float(args["gain"] as? Double ?? 1),
        ramp: Double(args["rampMs"] as? Int ?? 0) / 1000
      )
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
    case .itemStarted(let item, let gapMs):
      var started: [String: Any] = ["type": "started", "item": item]
      if let gapMs { started["gapMs"] = gapMs }
      payload = started
    case .itemEnded(let item): payload = ["type": "ended", "item": item]
    case .streamScheduled(let item):
      payload = ["type": "streamScheduled", "item": item]
    case .starved: payload = ["type": "starved"]
    case .drained:
      payload = ["type": "drained"]
      scheduleRelease(after: Self.releaseAfterStop)
    case .note(let name, let fields):
      payload = ["type": "native", "name": name, "fields": fields]
    }
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel?.invokeMethod("event", arguments: payload)
    }
  }
}

/// Answers the Save to Files picker once.
private final class AudioSavePickerDelegate: NSObject, UIDocumentPickerDelegate {
  static var key = 0
  private var done: ((Bool) -> Void)?

  init(_ done: @escaping (Bool) -> Void) { self.done = done }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    done?(true)
    done = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    done?(false)
    done = nil
  }
}

/// "Share as video" (2026-10-31: Discord's share extension drops audio files):
/// the reply's MP3 as the sound of an .mp4 (H.264 and AAC) whose picture is the
/// persona's clip looped to the audio's length, or a still image held for it.
/// Composing reads files and writes one; it never touches the audio session,
/// so other apps keep playing.
enum ReplyVideoMaker {
  private static let work = DispatchQueue(label: "app.cogwheel.conduit.reply-video", qos: .userInitiated)

  static func make(_ args: [String: Any], done: @escaping (Any?) -> Void) {
    work.async {
      do {
        guard let audioPath = args["audio"] as? String, let outPath = args["out"] as? String else {
          throw ReplyVideoError("missing paths")
        }
        let out = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: out)
        let audio = AVURLAsset(url: URL(fileURLWithPath: audioPath))
        let audioDuration = audio.duration
        guard audioDuration.seconds > 0, let audioTrack = audio.tracks(withMediaType: .audio).first else {
          throw ReplyVideoError("the MP3 has no audio")
        }
        var clipURL: URL?
        if let clip = args["clip"] as? String, !clip.isEmpty {
          if args["clipIsAsset"] as? Bool == true {
            let key = FlutterDartProject.lookupKey(forAsset: clip)
            if let path = Bundle.main.path(forResource: key, ofType: nil) { clipURL = URL(fileURLWithPath: path) }
          } else {
            clipURL = URL(fileURLWithPath: clip)
          }
        }
        var tempStill: URL?
        if clipURL == nil, let image = args["image"] as? String, let picture = UIImage(contentsOfFile: image) {
          let still = out.deletingLastPathComponent().appendingPathComponent("still.mp4")
          try stillVideo(picture, seconds: audioDuration.seconds, to: still)
          clipURL = still
          tempStill = still
        }
        guard let clipURL else { throw ReplyVideoError("no persona clip or picture") }
        let clip = AVURLAsset(url: clipURL)
        guard let clipTrack = clip.tracks(withMediaType: .video).first, clip.duration.seconds > 0 else {
          throw ReplyVideoError("the persona clip has no video")
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ReplyVideoError("cannot compose") }
        var at = CMTime.zero
        let clipRange = clipTrack.timeRange
        while at < audioDuration {
          let left = CMTimeSubtract(audioDuration, at)
          let length = CMTimeMinimum(clipRange.duration, left)
          try video.insertTimeRange(CMTimeRange(start: clipRange.start, duration: length), of: clipTrack, at: at)
          at = CMTimeAdd(at, length)
        }
        video.preferredTransform = clipTrack.preferredTransform
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720) else {
          throw ReplyVideoError("cannot export")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
          if let tempStill { try? FileManager.default.removeItem(at: tempStill) }
          if export.status == .completed {
            done(out.path)
          } else {
            done(FlutterError(code: "video", message: export.error?.localizedDescription ?? "the video export failed", details: nil))
          }
        }
      } catch {
        done(FlutterError(code: "video", message: error.localizedDescription, details: nil))
      }
    }
  }

  /// A silent H.264 video of [image] held for [seconds] (one frame a second).
  private static func stillVideo(_ image: UIImage, seconds: Double, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    guard let cg = image.cgImage else { throw ReplyVideoError("unreadable picture") }
    let side = 720
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
    ])
    guard writer.canAdd(input) else { throw ReplyVideoError("cannot write the still") }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32ARGB, nil, &buffer)
    guard let buffer else { throw ReplyVideoError("cannot draw the still") }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) {
      context.setFillColor(UIColor.black.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      let scale = min(Double(side) / Double(cg.width), Double(side) / Double(cg.height))
      let w = Double(cg.width) * scale, h = Double(cg.height) * scale
      context.draw(cg, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frames = max(2, Int(seconds.rounded(.up)) + 1)
    for i in 0..<frames {
      while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
      adaptor.append(buffer, withPresentationTime: CMTime(seconds: min(Double(i), seconds), preferredTimescale: 600))
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
    writer.finishWriting { finished.signal() }
    finished.wait()
    if writer.status != .completed { throw ReplyVideoError(writer.error?.localizedDescription ?? "the still failed") }
  }
}

private struct ReplyVideoError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
