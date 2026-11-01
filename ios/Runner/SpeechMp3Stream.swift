import AVFoundation
import AudioToolbox

/// Decodes one continuous MP3 body, fed in chunks of any size, to PCM as the
/// bytes arrive.
///
/// The speech relay answers a streamed request with a single MP3 (an ffmpeg
/// stream), sent progressively. [SpeechEngineQueue] used to wait for such a
/// body to end before it could cut it into pieces; this parses it with
/// AudioFileStream (packets as soon as a whole one is in), decodes the packets
/// with AVAudioConverter and hands back buffers in [outputFormat], the first
/// once [blockSeconds] of audio is decoded.
///
/// The encoder's delay and padding come from the Info/LAME header when the
/// stream has one (AudioFileStream's packet table info: priming frames at the
/// start, valid frames after them). A stream without that header (the relay's
/// ffmpeg pipe writes none) gets [defaultLeadingFrames] cut at the start
/// (libmp3lame's 576) and nothing at the end.
///
/// This file imports no UIKit and no engine type, so the macOS exactness test
/// compiles it as it is (ios/Runner/SpeechMp3Stream.swift, see
/// scripts/mp3-stream-exactness.sh).
final class Mp3StreamDecoder {
  struct DecodeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// libmp3lame's encoder delay. Core Audio's decoder already drops its own
  /// 529 frames of delay, so only this much of the lead-in is left to cut
  /// (measured 2026-11-01 against ffmpeg, which skips 1105 = 576 + 529).
  static let defaultLeadingFrames = 576

  let outputFormat: AVAudioFormat
  /// Frames a buffer holds (the first one too): about 0.1 s.
  let blockFrames: Int
  /// Decoded frames always kept back until the stream ends, so the last
  /// buffer is long enough to fade out.
  let holdbackFrames: Int

  /// The Info/LAME header's delay and padding, when the stream has one.
  private(set) var packetTable: AudioFilePacketTableInfo?
  /// The leading frames cut, known once decoding began.
  private(set) var leadingFramesCut = 0
  /// Frames decoded so far, before any cut.
  private(set) var decodedFrames = 0
  /// Frames handed back so far, in [outputFormat].
  private(set) var deliveredFrames = 0
  private(set) var bytesFed = 0

  private var streamID: AudioFileStreamID?
  private var compressedFormat: AVAudioFormat?
  private var pcmFormat: AVAudioFormat?
  private var decoder: AVAudioConverter?
  private var resampler: AVAudioConverter?
  private var skipRemaining = 0
  /// Decoded frames after which nothing is kept (the header's padding), in
  /// the decoder's output coordinates.
  private var endLimit: Int?
  /// The delay and padding came from the stream's own Info/Xing frame.
  private(set) var headerSource = "default"
  private var started = false
  private var failure: Error?
  private var pending: [[Float]]
  private var finished = false

  init(
    outputFormat: AVAudioFormat,
    blockSeconds: Double = 0.1,
    holdbackSeconds: Double = 0.01
  ) {
    self.outputFormat = outputFormat
    blockFrames = max(1, Int(outputFormat.sampleRate * blockSeconds))
    holdbackFrames = Int(outputFormat.sampleRate * holdbackSeconds)
    pending = Array(repeating: [], count: Int(outputFormat.channelCount))
  }

  deinit { close() }

  /// Parses [data] (any number of bytes, including none) and returns the
  /// buffers that are ready, in order. [last] says the body has ended: every
  /// decoded frame is returned, the final buffer being the clip's end.
  func feed(_ data: Data, last: Bool) throws -> [AVAudioPCMBuffer] {
    if finished { return [] }
    if let failure { throw failure }
    if streamID == nil {
      var id: AudioFileStreamID?
      let status = AudioFileStreamOpen(
        Unmanaged.passUnretained(self).toOpaque(),
        { client, _, property, _ in
          Unmanaged<Mp3StreamDecoder>.fromOpaque(client).takeUnretainedValue()
            .onProperty(property)
        },
        { client, bytes, packets, input, descriptions in
          Unmanaged<Mp3StreamDecoder>.fromOpaque(client).takeUnretainedValue()
            .onPackets(
              bytes: Int(bytes),
              packets: Int(packets),
              input: input,
              descriptions: descriptions
            )
        },
        kAudioFileMP3Type,
        &id
      )
      guard status == noErr, let id else {
        throw DecodeError(message: "cannot open the mp3 stream (\(status))")
      }
      streamID = id
    }
    var parse = Data()
    if let held = decideHead(data, last: last) { parse = held }
    // AudioFileStream loses packets when fed single bytes (measured
    // 2026-11-01: 47 of 144047 frames); it gets at least [minimumParse] at a
    // time, the rest waiting for the next bytes or the end.
    if !parse.isEmpty { carry.append(parse) }
    parse = Data()
    if carry.count >= Self.minimumParse || (last && !carry.isEmpty) {
      parse = carry
      carry = Data()
    }
    if !parse.isEmpty, let streamID {
      bytesFed += parse.count
      let status = parse.withUnsafeBytes { raw -> OSStatus in
        AudioFileStreamParseBytes(
          streamID,
          UInt32(raw.count),
          raw.baseAddress,
          []
        )
      }
      if let failure { throw failure }
      if status != noErr {
        throw DecodeError(message: "mp3 stream parse failed (\(status))")
      }
    }
    if last {
      finished = true
      try flushResampler()
      close()
    }
    return take(all: last)
  }

  private func close() {
    if let id = streamID {
      AudioFileStreamClose(id)
      streamID = nil
    }
  }

  // MARK: - AudioFileStream callbacks (synchronous, inside AudioFileStreamParseBytes)

  /// The delay, padding and frame count in the Info/Xing frame that opens
  /// [head] (an ID3 tag, then MPEG frames); nil when the first frame is
  /// audio. AudioFileStream swallows that frame without reporting its LAME
  /// fields (ffmpeg's Info frame, 2026-11-01), so it is read from the bytes.
  static func lameHeader(head: [UInt8]) -> (delay: Int?, padding: Int?, frames: Int?)? {
    var at = 0
    if head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
      let size = Int(head[6] & 0x7f) << 21 | Int(head[7] & 0x7f) << 14
        | Int(head[8] & 0x7f) << 7 | Int(head[9] & 0x7f)
      at = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
    }
    guard head.count >= at + 8, head[at] == 0xff, (head[at + 1] & 0xe0) == 0xe0
    else { return nil }
    let v1 = ((head[at + 1] >> 3) & 3) == 3
    let mono = ((head[at + 3] >> 6) & 3) == 3
    let crc = (head[at + 1] & 1) == 0 ? 2 : 0
    let side = v1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
    let tag = at + 4 + crc + side
    guard head.count >= tag + 8,
          String(decoding: head[tag..<tag + 4], as: UTF8.self) == "Xing"
            || String(decoding: head[tag..<tag + 4], as: UTF8.self) == "Info"
    else { return nil }
    func be32(_ i: Int) -> Int {
      Int(head[i]) << 24 | Int(head[i + 1]) << 16 | Int(head[i + 2]) << 8 | Int(head[i + 3])
    }
    let flags = be32(tag + 4)
    var i = tag + 8
    var frames: Int?
    if flags & 1 != 0 {
      guard head.count >= i + 4 else { return (nil, nil, nil) }
      frames = be32(i)
      i += 4
    }
    if flags & 2 != 0 { i += 4 }
    if flags & 4 != 0 { i += 100 }
    if flags & 8 != 0 { i += 4 }
    // encoder (9), revision (1), lowpass (1), replay gain (8), flags (1), abr (1)
    let enc = i + 21
    guard head.count >= enc + 3 else { return (nil, nil, frames) }
    let delay = Int(head[enc]) << 4 | Int(head[enc + 1]) >> 4
    let padding = (Int(head[enc + 1]) & 0xf) << 8 | Int(head[enc + 2])
    if delay == 0 && padding == 0 { return (nil, nil, frames) }
    return (delay, padding, frames)
  }

  /// Where the first MPEG frame of [head] is, after any ID3 tag.
  static func firstFrameRange(head: [UInt8]) -> Range<Int>? {
    var at = 0
    if head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
      let size = Int(head[6] & 0x7f) << 21 | Int(head[7] & 0x7f) << 14
        | Int(head[8] & 0x7f) << 7 | Int(head[9] & 0x7f)
      at = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
    }
    guard head.count >= at + 4, head[at] == 0xff, (head[at + 1] & 0xe0) == 0xe0
    else { return nil }
    let version = Int(head[at + 1] >> 3) & 3  // 3: MPEG 1, 2: MPEG 2, 0: 2.5
    let layer = Int(head[at + 1] >> 1) & 3  // 1: layer III
    let bitrateIndex = Int(head[at + 2] >> 4)
    let rateIndex = Int(head[at + 2] >> 2) & 3
    guard version != 1, layer == 1, bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3
    else { return nil }
    let v1 = version == 3
    let rates1 = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    let rates2 = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    let bitrate = (v1 ? rates1 : rates2)[bitrateIndex - 1] * 1000
    let sampleRate = [44100, 48000, 32000][rateIndex] / (v1 ? 1 : (version == 2 ? 2 : 4))
    let length = (v1 ? 144 : 72) * bitrate / sampleRate + (Int(head[at + 2] >> 1) & 1)
    guard head.count >= at + length else { return nil }
    return at..<(at + length)
  }

  /// Bytes held back until the stream's first frame can be told from an
  /// Info frame (the ID3 tag and about 200 bytes after it).
  private var head: [UInt8] = []
  private var headDecided = false
  private var carry = Data()
  /// The fewest bytes handed to AudioFileStream at once, short of the end.
  static let minimumParse = 64
  private var lame: (delay: Int?, padding: Int?, frames: Int?)?

  private func decideHead(_ data: Data, last: Bool) -> Data? {
    if headDecided { return data }
    head.append(contentsOf: data)
    var tagEnd = 0
    if head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
      tagEnd = 10 + (Int(head[6] & 0x7f) << 21 | Int(head[7] & 0x7f) << 14
        | Int(head[8] & 0x7f) << 7 | Int(head[9] & 0x7f))
    } else if head.count < 10 && !last {
      return nil
    }
    guard last || head.count >= tagEnd + 200 else { return nil }
    headDecided = true
    lame = Self.lameHeader(head: head)
    var all = head
    if lame != nil, let range = Self.firstFrameRange(head: head) {
      // AudioFileStream treats a split-up Info frame as audio (a silent
      // 576 frames, 2026-11-01), so it never sees that frame.
      all.removeSubrange(range)
    }
    head = []
    return Data(all)
  }

  private func onProperty(_ property: AudioFileStreamPropertyID) {
    guard let id = streamID, failure == nil else { return }
    switch property {
    case kAudioFileStreamProperty_PacketTableInfo:
      var info = AudioFilePacketTableInfo()
      var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
      if AudioFileStreamGetProperty(
        id, kAudioFileStreamProperty_PacketTableInfo, &size, &info
      ) == noErr {
        packetTable = info
      }
    case kAudioFileStreamProperty_ReadyToProducePackets:
      var asbd = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      guard AudioFileStreamGetProperty(
        id, kAudioFileStreamProperty_DataFormat, &size, &asbd
      ) == noErr,
        let source = AVAudioFormat(streamDescription: &asbd),
        let pcm = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: asbd.mSampleRate,
          channels: asbd.mChannelsPerFrame,
          interleaved: false
        ),
        let converter = AVAudioConverter(from: source, to: pcm)
      else {
        failure = DecodeError(message: "cannot decode this mp3 stream")
        return
      }
      var info = AudioFilePacketTableInfo()
      var infoSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
      if packetTable == nil, AudioFileStreamGetProperty(
        id, kAudioFileStreamProperty_PacketTableInfo, &infoSize, &info
      ) == noErr, info.mNumberValidFrames > 0 {
        packetTable = info
      }
      compressedFormat = source
      pcmFormat = pcm
      decoder = converter
      if pcm.sampleRate != outputFormat.sampleRate
        || pcm.channelCount != outputFormat.channelCount {
        resampler = AVAudioConverter(from: pcm, to: outputFormat)
        if resampler == nil {
          failure = DecodeError(message: "cannot convert \(pcm) to \(outputFormat)")
        }
      }
    default:
      break
    }
  }

  private func onPackets(
    bytes: Int,
    packets: Int,
    input: UnsafeRawPointer,
    descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
  ) {
    guard failure == nil, packets > 0,
          let compressedFormat, let pcmFormat, let decoder
    else { return }
    // The cut is fixed once, from the first packets.
    if !started {
      started = true
      let perPacket = Int(compressedFormat.streamDescription.pointee.mFramesPerPacket)
      if let lame {
        skipRemaining = lame.delay ?? Self.defaultLeadingFrames
        if let pad = lame.padding, let frames = lame.frames, frames > 0 {
          endLimit = frames * perPacket - pad
        }
        headerSource = "info-frame"
      } else if let table = packetTable {
        // Core Audio's own table counts the decoder's 529 frames of delay in
        // the priming; its decoder has already dropped them.
        let drop = table.mPrimingFrames >= 1105 ? 529 : 0
        skipRemaining = Int(max(0, Int(table.mPrimingFrames) - drop))
        if table.mNumberValidFrames > 0 {
          endLimit = Int(table.mPrimingFrames) - drop + Int(table.mNumberValidFrames)
        }
        headerSource = "packet-table"
      } else {
        skipRemaining = Self.defaultLeadingFrames
      }
      leadingFramesCut = skipRemaining
    }
    var largest = 0
    let uniform = bytes / packets
    if let descriptions {
      for i in 0..<packets { largest = max(largest, Int(descriptions[i].mDataByteSize)) }
    } else {
      largest = uniform
    }
    let compressed = AVAudioCompressedBuffer(
      format: compressedFormat,
      packetCapacity: AVAudioPacketCount(packets),
      maximumPacketSize: max(largest, 1)
    )
    guard let table = compressed.packetDescriptions else {
      failure = DecodeError(message: "no buffer for \(packets) mp3 packets")
      return
    }
    guard bytes <= compressed.byteCapacity else {
      failure = DecodeError(message: "mp3 packets larger than expected")
      return
    }
    compressed.data.copyMemory(from: input, byteCount: bytes)
    compressed.byteLength = UInt32(bytes)
    compressed.packetCount = AVAudioPacketCount(packets)
    for i in 0..<packets {
      if let descriptions {
        table[i] = descriptions[i]
      } else {
        table[i] = AudioStreamPacketDescription(
          mStartOffset: Int64(i * uniform),
          mVariableFramesInPacket: 0,
          mDataByteSize: UInt32(uniform)
        )
      }
    }

    let perPacket = max(1, Int(compressedFormat.streamDescription.pointee.mFramesPerPacket))
    guard let out = AVAudioPCMBuffer(
      pcmFormat: pcmFormat,
      frameCapacity: AVAudioFrameCount((packets + 2) * perPacket)
    ) else {
      failure = DecodeError(message: "no buffer for decoded audio")
      return
    }
    var supplied = false
    var error: NSError?
    let status = decoder.convert(to: out, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return compressed
    }
    if status == .error {
      failure = DecodeError(
        message: error?.localizedDescription ?? "mp3 decode failed"
      )
      return
    }
    accept(out)
  }

  // MARK: - Cutting, converting, collecting

  /// [decoded] with the delay and padding cut, converted to [outputFormat]
  /// and added to the pending frames.
  private func accept(_ decoded: AVAudioPCMBuffer) {
    let produced = Int(decoded.frameLength)
    var start = 0
    var end = produced
    if skipRemaining > 0 {
      start = min(skipRemaining, end)
      skipRemaining -= start
    }
    if let limit = endLimit {
      end = max(start, min(end, limit - decodedFrames))
    }
    decodedFrames += produced
    guard end > start else { return }
    guard let slice = Self.slice(decoded, from: start, to: end) else { return }
    if let resampler {
      guard let converted = convert(slice, with: resampler, last: false) else { return }
      append(converted)
    } else {
      append(slice)
    }
  }

  private func flushResampler() throws {
    if let failure { throw failure }
    guard let resampler, let pcmFormat,
          let empty = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1)
    else { return }
    if let tail = convert(empty, with: resampler, last: true) { append(tail) }
  }

  private func convert(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter,
    last: Bool
  ) -> AVAudioPCMBuffer? {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if supplied || (last && buffer.frameLength <= 1) {
        inputStatus.pointee = last ? .endOfStream : .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    if status == .error {
      failure = DecodeError(message: error?.localizedDescription ?? "conversion failed")
      return nil
    }
    return out.frameLength > 0 ? out : nil
  }

  private func append(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    for c in 0..<min(pending.count, Int(buffer.format.channelCount)) {
      pending[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n))
    }
  }

  /// Full blocks while more than a block plus the hold-back is pending; with
  /// [all], everything pending as one buffer.
  private func take(all: Bool) -> [AVAudioPCMBuffer] {
    var out: [AVAudioPCMBuffer] = []
    func cut(_ frames: Int) {
      guard frames > 0,
            let buffer = AVAudioPCMBuffer(
              pcmFormat: outputFormat,
              frameCapacity: AVAudioFrameCount(frames)
            ),
            let data = buffer.floatChannelData
      else { return }
      buffer.frameLength = AVAudioFrameCount(frames)
      for c in 0..<pending.count {
        pending[c].withUnsafeBufferPointer {
          data[c].update(from: $0.baseAddress!, count: frames)
        }
        pending[c].removeFirst(frames)
      }
      deliveredFrames += frames
      out.append(buffer)
    }
    while (pending.first?.count ?? 0) >= blockFrames + holdbackFrames {
      cut(blockFrames)
    }
    if all { cut(pending.first?.count ?? 0) }
    return out
  }

  /// Frames [from, to) of [buffer] as a buffer of their own.
  static func slice(_ buffer: AVAudioPCMBuffer, from: Int, to: Int) -> AVAudioPCMBuffer? {
    let n = to - from
    guard n > 0, let src = buffer.floatChannelData,
          let out = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: AVAudioFrameCount(n)
          ),
          let dst = out.floatChannelData
    else { return nil }
    out.frameLength = AVAudioFrameCount(n)
    for c in 0..<Int(buffer.format.channelCount) {
      dst[c].update(from: src[c].advanced(by: from), count: n)
    }
    return out
  }
}
