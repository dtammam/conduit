import AVFoundation
import os

/// Plays spoken clips that arrive as small MP3 pieces as one continuous
/// waveform on an AVAudioEngine.
///
/// A streaming speech server encodes each half second of a sentence as an MP3
/// file of its own. Each piece decodes with the encoder's lead-in at the start
/// (576 samples) and a flush frame at the end (576 samples); played back to
/// back as files, every join has about 48 ms of near-silence inside a word,
/// which is heard as scratches. Here each piece is decoded to PCM, those
/// samples are cut ([PieceTrim]), and the rest is scheduled on one player node
/// so the joins are sample-continuous (measured 2026-10-24 on the speech
/// relay's stream: joins as smooth as a normal sample step).
///
/// Items are the caller's clips (sentences) in queue order. Pieces of an item
/// are scheduled as they come; the next item's pieces wait until the item
/// before it is finished.
///
/// The graph (player, time-pitch, main mixer) is wired once, in [format], and
/// every decoded buffer is converted to that format, so nothing is connected
/// while audio runs. AVAudioEngine reports misuse by raising Objective-C
/// exceptions, which would end the app; every engine call goes through
/// [ConduitObjCTry] and surfaces as a thrown [EngineError] instead, so the
/// caller can fall back to another player. (2026-10-24: `play` before the
/// first piece prepared an engine with no output connected, "required
/// condition is false: inputNode != nullptr || outputNode != nullptr", and
/// the app crashed.)
final class SpeechEngineQueue {
  struct PieceTrim {
    var leading: AVAudioFrameCount
    var trailing: AVAudioFrameCount
    static let none = PieceTrim(leading: 0, trailing: 0)
    /// The streaming relay's pieces (libmp3lame, decoded by Core Audio).
    static let streamedMp3 = PieceTrim(leading: 576, trailing: 576)
  }

  enum Event {
    /// Item [index] began playing.
    case itemStarted(Int)
    /// Everything scheduled has played and more is still expected.
    case starved
    /// Every item is finished and has played.
    case drained
  }

  struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// The format the graph runs in; decoded audio is converted to it.
  let format: AVAudioFormat
  let engine: AVAudioEngine
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var wired = false
  private let queue = DispatchQueue(label: "app.cogwheel.conduit.speech-engine")

  /// When a scheduled buffer counts as done. Played back on a device; offline
  /// rendering (tests) only reports buffers as rendered.
  private let completionType: AVAudioPlayerNodeCompletionCallbackType

  private struct Item {
    var buffers: [AVAudioPCMBuffer] = []
    var finished = false
  }

  private var items: [Item] = []
  /// The item whose buffers are being scheduled now.
  private var scheduleItem = 0
  /// How many buffers of [scheduleItem] are scheduled.
  private var scheduledInItem = 0
  /// Scheduled buffers not yet played back.
  private var outstanding = 0
  private var generation = 0
  private var lastStartedItem: Int?
  /// Items waiting to be reported as started, with how many buffers must play
  /// back first.
  private var pendingStarts: [(item: Int, ahead: Int)] = []
  private(set) var wantsPlayback = false

  /// Called on the engine's queue.
  var onEvent: ((Event) -> Void)?

  init(
    engine: AVAudioEngine = AVAudioEngine(),
    format: AVAudioFormat = AVAudioFormat(
      standardFormatWithSampleRate: 24000,
      channels: 1
    )!,
    completionType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack
  ) {
    self.engine = engine
    self.format = format
    self.completionType = completionType
    engine.attach(player)
    engine.attach(timePitch)
    timePitch.bypass = true
  }

  // MARK: - Queue

  /// Clears every item and stops playback.
  func reset() throws {
    try queue.sync {
      generation += 1
      try Self.objc { self.player.stop() }
      items.removeAll()
      scheduleItem = 0
      scheduledInItem = 0
      outstanding = 0
      lastStartedItem = nil
      pendingStarts.removeAll()
    }
  }

  /// Decodes [data] (an encoded audio file) and adds it to item [index].
  ///
  /// The first piece of an item fades in over [fadeIn]; a piece shorter than
  /// a full streamed piece is the clip's last, and fades out over [fadeOut],
  /// so a clip never starts or stops on a full-scale sample step.
  func appendPiece(item index: Int, data: Data, trim: PieceTrim) throws {
    let decoded = try Self.decode(data, trim: trim, to: format)
    try queue.sync {
      ensureItem(index)
      if let buffer = decoded {
        if items[index].buffers.isEmpty {
          Self.fade(buffer, in: true, seconds: Self.fadeIn)
        }
        if trim.leading > 0, buffer.frameLength < Self.fullPieceFrames(format) {
          Self.fade(buffer, in: false, seconds: Self.fadeOut)
        }
        items[index].buffers.append(buffer)
      }
      try scheduleReady()
    }
  }

  static let fadeIn = 0.005
  static let fadeOut = 0.010

  /// Speech frames in a full streamed piece (0.48 s), in [format]'s rate.
  static func fullPieceFrames(_ format: AVAudioFormat) -> AVAudioFrameCount {
    AVAudioFrameCount(format.sampleRate * 0.48)
  }

  /// Ramps the first (or last) [seconds] of [buffer] from (or to) silence.
  static func fade(_ buffer: AVAudioPCMBuffer, in fadeIn: Bool, seconds: Double) {
    guard let data = buffer.floatChannelData else { return }
    let total = Int(buffer.frameLength)
    let n = min(total, Int(buffer.format.sampleRate * seconds))
    guard n > 1 else { return }
    for c in 0..<Int(buffer.format.channelCount) {
      for i in 0..<n {
        let gain = Float(i) / Float(n - 1)
        let index = fadeIn ? i : total - 1 - i
        data[c][index] *= gain
      }
    }
  }

  /// Adds PCM to item [index]; converted to [format] when it differs.
  func appendBuffer(item index: Int, buffer: AVAudioPCMBuffer) throws {
    let converted = try Self.convert(buffer, to: format)
    try queue.sync {
      ensureItem(index)
      if let converted { items[index].buffers.append(converted) }
      try scheduleReady()
    }
  }

  /// No more pieces will come for item [index].
  func finishItem(_ index: Int) throws {
    try queue.sync {
      ensureItem(index)
      items[index].finished = true
      try scheduleReady()
      reportIfIdle()
    }
  }

  /// Plays from the start of item [index] (a replay or a skip).
  func seek(toItem index: Int) throws {
    try queue.sync {
      generation += 1
      try Self.objc { self.player.stop() }
      outstanding = 0
      scheduleItem = max(0, index)
      scheduledInItem = 0
      lastStartedItem = nil
      pendingStarts.removeAll()
      try scheduleReady()
      if wantsPlayback { try startPlayerIfNeeded() }
    }
  }

  // MARK: - Transport

  func play() throws {
    try queue.sync {
      try wireIfNeeded()
      try startEngineIfNeeded()
      wantsPlayback = true
      try startPlayerIfNeeded()
    }
  }

  func pause() throws {
    try queue.sync {
      wantsPlayback = false
      try Self.objc { self.player.pause() }
    }
  }

  func stop() throws {
    try queue.sync {
      wantsPlayback = false
      generation += 1
      try Self.objc { self.player.stop() }
      outstanding = 0
      scheduledInItem = 0
      lastStartedItem = nil
      pendingStarts.removeAll()
    }
  }

  func setRate(_ rate: Float) {
    timePitch.rate = max(1.0 / 32, min(32, rate))
    // At normal speed the time stretcher is left out of the signal entirely.
    timePitch.bypass = rate == 1
  }

  /// After the engine stopped for a route or format change: start it again
  /// and replay the current item from its start (the player's schedule does
  /// not survive the stop).
  func recoverAfterConfigurationChange() throws {
    let (wants, resumeItem) = queue.sync {
      (wantsPlayback, lastStartedItem ?? scheduleItem)
    }
    countDiag { recoveries += 1 }
    Self.log.notice("recover after configuration change, wants=\(wants, privacy: .public)")
    guard wants else { return }
    try queue.sync { try startEngineIfNeeded() }
    try seek(toItem: resumeItem)
  }

  // MARK: - Voice capture (one engine for the call's playback and microphone)

  /// Whether the engine's input runs through the platform's voice processing
  /// (echo cancellation with this engine's output as the reference, noise
  /// suppression, gain control).
  private(set) var voiceProcessing = false
  private var captureConverter: AVAudioConverter?
  private var captureFormat: AVAudioFormat?
  private var capturing = false

  /// Turns voice processing on or off. The engine restarts for it; a clip
  /// that was playing goes on from its start.
  func setVoiceProcessing(_ on: Bool) throws {
    guard on != voiceProcessing else { return }
    let (wasRunning, resumeItem) = queue.sync {
      (engine.isRunning, lastStartedItem ?? scheduleItem)
    }
    if capturing { try stopCapture() }
    countDiag {
      voiceProcessingToggles += 1
      togglingVoiceProcessing = true
    }
    Self.log.notice("setVoiceProcessing \(on, privacy: .public)")
    defer { countDiag { togglingVoiceProcessing = false } }
    try Self.objc {
      if self.engine.isRunning { self.engine.stop() }
      try self.engine.inputNode.setVoiceProcessingEnabled(on)
    }
    voiceProcessing = on
    if wasRunning || wantsPlayback {
      try queue.sync { try startEngineIfNeeded() }
      if wantsPlayback { try seek(toItem: resumeItem) }
    }
  }

  /// Taps the microphone and hands [onData] 16-bit little-endian mono PCM at
  /// [sampleRate], the format the call's voice detection reads.
  func startCapture(sampleRate: Double, onData: @escaping (Data) -> Void) throws {
    if capturing { try stopCapture() }
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
      throw EngineError(message: "no microphone input")
    }
    guard let target = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: true
    ), let converter = AVAudioConverter(from: inputFormat, to: target)
    else { throw EngineError(message: "cannot convert microphone audio") }
    captureConverter = converter
    captureFormat = target
    try Self.objc {
      input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
        [weak self] buffer, _ in
        guard let self,
              let data = Self.convertCapture(buffer, with: converter, to: target)
        else { return }
        onData(data)
      }
    }
    capturing = true
    try queue.sync { try startEngineIfNeeded() }
  }

  func stopCapture() throws {
    guard capturing else { return }
    capturing = false
    try Self.objc { self.engine.inputNode.removeTap(onBus: 0) }
    captureConverter = nil
  }

  /// One tap buffer as 16-bit mono PCM bytes in [format], through a
  /// converter that keeps its state across buffers (no edge at each one).
  static func convertCapture(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter,
    to format: AVAudioFormat
  ) -> Data? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
    else { return nil }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0,
          let samples = out.int16ChannelData
    else { return nil }
    return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
  }

  // MARK: - Diagnostics (voice-call crackle hunt)

  private static let log = Logger(
    subsystem: "app.cogwheel.conduit",
    category: "voice-engine"
  )
  private let diagLock = NSLock()
  private var configChanges = 0
  private var configChangesDuringToggle = 0
  private var recoveries = 0
  private var voiceProcessingToggles = 0
  private var togglingVoiceProcessing = false

  /// The engine posted a configuration change. Cheap; any thread.
  func noteConfigurationChange() {
    diagLock.lock()
    configChanges += 1
    if togglingVoiceProcessing { configChangesDuringToggle += 1 }
    let n = configChanges
    diagLock.unlock()
    Self.log.notice("configuration change #\(n, privacy: .public)")
  }

  private func countDiag(_ body: () -> Void) {
    diagLock.lock()
    body()
    diagLock.unlock()
  }

  /// Counters since the last reset, with the audio session and the engine's
  /// formats as they are now. Off the render thread (called from Dart).
  func diagnostics(reset: Bool) -> [String: Any] {
    diagLock.lock()
    var out: [String: Any] = [
      "configChanges": configChanges,
      "configChangesDuringToggle": configChangesDuringToggle,
      "recoveries": recoveries,
      "voiceProcessingToggles": voiceProcessingToggles,
      "voiceProcessing": voiceProcessing,
    ]
    if reset {
      configChanges = 0
      configChangesDuringToggle = 0
      recoveries = 0
      voiceProcessingToggles = 0
    }
    diagLock.unlock()
    let session = AVAudioSession.sharedInstance()
    out["hwSampleRate"] = session.sampleRate
    out["preferredSampleRate"] = session.preferredSampleRate
    out["ioBufferMs"] = (session.ioBufferDuration * 1000 * 10).rounded() / 10
    out["outputLatencyMs"] = (session.outputLatency * 1000 * 10).rounded() / 10
    out["category"] = session.category.rawValue
    out["mode"] = session.mode.rawValue
    out["route"] = session.currentRoute.outputs
      .map { "\($0.portType.rawValue)" }.joined(separator: ",")
    out["input"] = session.currentRoute.inputs
      .map { "\($0.portType.rawValue)" }.joined(separator: ",")
    func describe(_ f: AVAudioFormat) -> String {
      "\(Int(f.sampleRate))Hz/\(f.channelCount)ch"
    }
    out["playerFormat"] = describe(format)
    if let formats = try? Self.objc({ () -> [String] in
      [
        describe(self.engine.mainMixerNode.outputFormat(forBus: 0)),
        describe(self.engine.outputNode.outputFormat(forBus: 0)),
        describe(self.engine.inputNode.inputFormat(forBus: 0)),
      ]
    }) {
      out["mixerOut"] = formats[0]
      out["engineOutput"] = formats[1]
      out["engineInput"] = formats[2]
    }
    let text = out.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    Self.log.notice("\(text, privacy: .public)")
    return out
  }

  func shutDown() {
    try? stop()
    _ = try? Self.objc { self.engine.stop() }
  }

  // MARK: - Internals

  /// Runs [body], turning an Objective-C exception into [EngineError].
  @discardableResult
  static func objc<T>(_ body: () throws -> T) throws -> T {
    var value: T?
    var thrown: Error?
    var objcError: NSError?
    let ok = ConduitObjCTry({
      do { value = try body() } catch { thrown = error }
    }, &objcError)
    if !ok {
      throw EngineError(message: objcError?.localizedDescription ?? "audio engine error")
    }
    if let thrown { throw thrown }
    return value!
  }

  private func ensureItem(_ index: Int) {
    while items.count <= index { items.append(Item()) }
  }

  private func wireIfNeeded() throws {
    guard !wired else { return }
    try Self.objc {
      self.engine.connect(self.player, to: self.timePitch, format: self.format)
      self.engine.connect(
        self.timePitch,
        to: self.engine.mainMixerNode,
        format: self.format
      )
    }
    wired = true
  }

  private func startEngineIfNeeded() throws {
    try wireIfNeeded()
    if engine.isRunning { return }
    try Self.objc {
      self.engine.prepare()
      try self.engine.start()
    }
    // 10 ms of silence first, so the hardware starts on zeros.
    if outstanding == 0,
       let lead = AVAudioPCMBuffer(
         pcmFormat: format,
         frameCapacity: AVAudioFrameCount(format.sampleRate * 0.01)
       ) {
      lead.frameLength = lead.frameCapacity
      if let data = lead.floatChannelData {
        for c in 0..<Int(format.channelCount) {
          data[c].update(repeating: 0, count: Int(lead.frameLength))
        }
      }
      try Self.objc { self.player.scheduleBuffer(lead, completionHandler: nil) }
    }
  }

  private func startPlayerIfNeeded() throws {
    guard engine.isRunning, wantsPlayback, !player.isPlaying else { return }
    try Self.objc { self.player.play() }
  }

  /// Schedules every buffer that may play now, in order. On [queue].
  private func scheduleReady() throws {
    try wireIfNeeded()
    while scheduleItem < items.count {
      let item = items[scheduleItem]
      while scheduledInItem < item.buffers.count {
        try schedule(
          item.buffers[scheduledInItem],
          item: scheduleItem,
          first: scheduledInItem == 0
        )
        scheduledInItem += 1
      }
      guard item.finished else { return }
      scheduleItem += 1
      scheduledInItem = 0
    }
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, item: Int, first: Bool) throws {
    let scheduledGeneration = generation
    try Self.objc {
      self.player.scheduleBuffer(
        buffer,
        completionCallbackType: self.completionType
      ) { [weak self] _ in
        guard let self else { return }
        self.queue.async {
          guard scheduledGeneration == self.generation else { return }
          self.outstanding -= 1
          self.advancePendingStarts()
          self.reportIfIdle()
        }
      }
    }
    outstanding += 1
    if first {
      // The item starts when everything scheduled before it has played.
      if outstanding == 1 {
        reportStarted(item)
      } else {
        pendingStarts.append((item, outstanding - 1))
      }
    }
    if wantsPlayback { try startPlayerIfNeeded() }
  }

  private func advancePendingStarts() {
    pendingStarts = pendingStarts.compactMap { entry in
      let ahead = entry.ahead - 1
      if ahead <= 0 {
        reportStarted(entry.item)
        return nil
      }
      return (entry.item, ahead)
    }
  }

  private func reportStarted(_ item: Int) {
    guard lastStartedItem != item else { return }
    lastStartedItem = item
    onEvent?(.itemStarted(item))
  }

  private func reportIfIdle() {
    guard outstanding == 0, lastStartedItem != nil || scheduleItem > 0 else {
      return
    }
    let allDone = scheduleItem >= items.count
    onEvent?(allDone ? .drained : .starved)
  }

  /// Decodes an encoded audio file in memory to PCM in [format], cutting
  /// [trim] from its ends; nil when nothing is left (a piece shorter than
  /// the trim).
  static func decode(
    _ data: Data,
    trim: PieceTrim,
    to format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("speech-piece-\(UUID().uuidString).mp3")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let whole: AVAudioPCMBuffer = try objc {
      let file = try AVAudioFile(forReading: url)
      let total = AVAudioFrameCount(max(0, file.length))
      guard total > 0,
            let buffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat,
              frameCapacity: total
            )
      else { throw EngineError(message: "empty audio") }
      try file.read(into: buffer)
      return buffer
    }
    guard let trimmed = cut(whole, trim: trim) else { return nil }
    return try convert(trimmed, to: format)
  }

  /// [buffer] without [trim]'s frames at either end; nil when nothing is left.
  static func cut(_ buffer: AVAudioPCMBuffer, trim: PieceTrim) -> AVAudioPCMBuffer? {
    let total = buffer.frameLength
    guard total > trim.leading + trim.trailing else { return nil }
    let start = trim.leading
    let length = total - trim.leading - trim.trailing
    guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length)
    else { return nil }
    out.frameLength = length
    let channels = Int(buffer.format.channelCount)
    if let src = buffer.floatChannelData, let dst = out.floatChannelData {
      for c in 0..<channels {
        dst[c].update(from: src[c].advanced(by: Int(start)), count: Int(length))
      }
    } else if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
      for c in 0..<channels {
        dst[c].update(from: src[c].advanced(by: Int(start)), count: Int(length))
      }
    } else {
      return nil
    }
    return out
  }

  /// [buffer] in [format] (sample rate, channels, sample type); itself when
  /// it already is.
  static func convert(
    _ buffer: AVAudioPCMBuffer,
    to format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer? {
    if buffer.format == format { return buffer }
    guard buffer.frameLength > 0 else { return nil }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
      throw EngineError(message: "cannot convert \(buffer.format) to \(format)")
    }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }
    var fed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if fed {
        outStatus.pointee = .endOfStream
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return buffer
    }
    if status == .error {
      throw EngineError(message: error?.localizedDescription ?? "conversion failed")
    }
    return out.frameLength > 0 ? out : nil
  }
}
