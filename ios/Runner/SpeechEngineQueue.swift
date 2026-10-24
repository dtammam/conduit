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
/// before it is finished. Host-agnostic: no Flutter types.
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

  let engine: AVAudioEngine
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var connectedFormat: AVAudioFormat?
  private let queue = DispatchQueue(label: "app.cogwheel.conduit.speech-engine")

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
  private(set) var wantsPlayback = false

  /// Called on the engine's queue.
  var onEvent: ((Event) -> Void)?

  /// When a scheduled buffer counts as done. Played back on a device; offline
  /// rendering (tests) only reports buffers as rendered.
  private let completionType: AVAudioPlayerNodeCompletionCallbackType

  init(
    engine: AVAudioEngine = AVAudioEngine(),
    completionType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack
  ) {
    self.engine = engine
    self.completionType = completionType
    engine.attach(player)
    engine.attach(timePitch)
    timePitch.bypass = true
  }

  // MARK: - Queue

  /// Clears every item and stops playback.
  func reset() {
    queue.sync {
      generation += 1
      player.stop()
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
    let buffer = try Self.decode(data, trim: trim)
    queue.sync {
      ensureItem(index)
      if let buffer { items[index].buffers.append(buffer) }
      scheduleReady()
    }
  }

  /// Adds already decoded PCM to item [index] (tests, and hosts that decode
  /// elsewhere).
  func appendBuffer(item index: Int, buffer: AVAudioPCMBuffer) {
    queue.sync {
      ensureItem(index)
      items[index].buffers.append(buffer)
      scheduleReady()
    }
  }

  /// No more pieces will come for item [index].
  func finishItem(_ index: Int) {
    queue.sync {
      ensureItem(index)
      items[index].finished = true
      scheduleReady()
      reportIfIdle()
    }
  }

  /// Plays from the start of item [index] (a replay or a skip).
  func seek(toItem index: Int) {
    queue.sync {
      generation += 1
      player.stop()
      outstanding = 0
      scheduleItem = max(0, index)
      scheduledInItem = 0
      lastStartedItem = nil
      pendingStarts.removeAll()
      scheduleReady()
      if wantsPlayback { startPlayerIfNeeded() }
    }
  }

  // MARK: - Transport

  func play() throws {
    try startEngineIfNeeded()
    queue.sync {
      wantsPlayback = true
      startPlayerIfNeeded()
    }
  }

  func pause() {
    queue.sync {
      wantsPlayback = false
      player.pause()
    }
  }

  func stop() {
    queue.sync {
      wantsPlayback = false
      generation += 1
      player.stop()
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
  func recoverAfterConfigurationChange() {
    let (wants, resumeItem) = queue.sync {
      (wantsPlayback, lastStartedItem ?? scheduleItem)
    }
    guard wants else { return }
    try? startEngineIfNeeded()
    seek(toItem: resumeItem)
  }

  func shutDown() {
    stop()
    engine.stop()
  }

  // MARK: - Internals

  private func ensureItem(_ index: Int) {
    while items.count <= index { items.append(Item()) }
  }

  private func startEngineIfNeeded() throws {
    if !engine.isRunning {
      engine.prepare()
      try engine.start()
    }
  }

  private func startPlayerIfNeeded() {
    guard engine.isRunning, wantsPlayback, !player.isPlaying else { return }
    player.play()
  }

  /// Schedules every buffer that may play now, in order. On [queue].
  private func scheduleReady() {
    while scheduleItem < items.count {
      let item = items[scheduleItem]
      while scheduledInItem < item.buffers.count {
        schedule(item.buffers[scheduledInItem], item: scheduleItem,
                 first: scheduledInItem == 0)
        scheduledInItem += 1
      }
      guard item.finished else { return }
      scheduleItem += 1
      scheduledInItem = 0
    }
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, item: Int, first: Bool) {
    connect(format: buffer.format)
    let scheduledGeneration = generation
    outstanding += 1
    if first {
      // The item starts when everything scheduled before it has played; a
      // zero-length marker would be dropped, so the start is reported from
      // the previous buffer's completion, or now when nothing is ahead.
      if outstanding == 1 { reportStarted(item) } else {
        pendingStarts.append((item, outstanding - 1))
      }
    }
    player.scheduleBuffer(buffer, completionCallbackType: completionType) {
      [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard scheduledGeneration == self.generation else { return }
        self.outstanding -= 1
        self.advancePendingStarts()
        self.reportIfIdle()
      }
    }
    if wantsPlayback { startPlayerIfNeeded() }
  }

  /// Items waiting to be reported as started, with how many buffers must play
  /// back first.
  private var pendingStarts: [(item: Int, ahead: Int)] = []

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

  private func connect(format: AVAudioFormat) {
    if let connected = connectedFormat, connected == format { return }
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    connectedFormat = format
  }

  /// Decodes an encoded audio file in memory to PCM and cuts [trim] from its
  /// ends; nil when nothing is left.
  static func decode(_ data: Data, trim: PieceTrim) throws -> AVAudioPCMBuffer? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("speech-piece-\(UUID().uuidString).mp3")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let total = AVAudioFrameCount(file.length)
    guard total > 0,
          let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: total)
    else { return nil }
    try file.read(into: whole)
    let start = min(trim.leading, whole.frameLength)
    let end = whole.frameLength > trim.trailing + start
      ? whole.frameLength - trim.trailing : start
    let length = end - start
    guard length > 0,
          let out = AVAudioPCMBuffer(pcmFormat: whole.format, frameCapacity: length)
    else { return nil }
    out.frameLength = length
    let channels = Int(whole.format.channelCount)
    if let src = whole.floatChannelData, let dst = out.floatChannelData {
      for c in 0..<channels {
        dst[c].update(from: src[c].advanced(by: Int(start)), count: Int(length))
      }
    } else if let src = whole.int16ChannelData, let dst = out.int16ChannelData {
      for c in 0..<channels {
        dst[c].update(from: src[c].advanced(by: Int(start)), count: Int(length))
      }
    }
    return out
  }
}
