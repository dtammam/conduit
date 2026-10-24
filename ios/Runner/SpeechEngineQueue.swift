import AVFoundation

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
  func appendPiece(item index: Int, data: Data, trim: PieceTrim) throws {
    let buffer = try Self.decode(data, trim: trim, to: format)
    try queue.sync {
      ensureItem(index)
      if let buffer { items[index].buffers.append(buffer) }
      try scheduleReady()
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
    guard wants else { return }
    try queue.sync { try startEngineIfNeeded() }
    try seek(toItem: resumeItem)
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
