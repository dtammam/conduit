import AVFoundation
import Foundation

// Exactness test for Mp3StreamDecoder (ios/Runner/SpeechMp3Stream.swift, compiled as is).
// usage: exact <file.mp3> <ffmpeg-ref.f32le> [rate] [seeds]
// Feeds the file in random 1..4096 byte chunks and compares the samples with ffmpeg's
// whole-file decode (-f f32le -ac 1): equal counts, max abs diff, and bit-identical to a whole feed.
// Run through scripts/mp3-stream-exactness.sh.
let args = CommandLine.arguments
let mp3 = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
let refData = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
let rate = args.count > 3 ? Double(args[3])! : 24000
let seeds = args.count > 4 ? Int(args[4])! : 20
let ref: [Float] = refData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

struct Gen { var s: UInt64
  mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }

func run(chunker: (inout Gen) -> Int, seed: UInt64) -> (samples: [Float], firstAt: Int?, table: AudioFilePacketTableInfo?, cut: Int, bufs: Int, src: String) {
  let dec = Mp3StreamDecoder(outputFormat: fmt)
  var g = Gen(s: seed)
  var lastN = 0; var out: [Float] = []; var pos = 0; var firstAt: Int? = nil; var bufs = 0
  func take(_ b: [AVAudioPCMBuffer]) { for x in b { bufs += 1; out += UnsafeBufferPointer(start: x.floatChannelData![0], count: Int(x.frameLength)) } ; if firstAt == nil && !b.isEmpty { firstAt = pos + lastN } }
  while pos < mp3.count {
    let n = min(chunker(&g), mp3.count - pos); lastN = n
    take(try! dec.feed(mp3.subdata(in: pos..<pos+n), last: false)); pos += n
  }
  take(try! dec.feed(Data(), last: true))
  return (out, firstAt, dec.packetTable, dec.leadingFramesCut, bufs, dec.headerSource)
}

var worst: Float = 0; var allEqual = true; var firstBytes: [Int] = []
let base = run(chunker: { _ in 1 << 30 }, seed: 1)
// ffmpeg skips encoder delay + decoder delay (1105) only when there is no Info header it honors itself
let skip = base.src == "info-frame" ? 0 : 1105
let expected = Array(ref.dropFirst(skip))
print("header source:", base.src, "header table:", base.table.map { "prime=\($0.mPrimingFrames) valid=\($0.mNumberValidFrames) rem=\($0.mRemainderFrames)" } ?? "none", "cut=\(base.cut)")
print("ref frames:", ref.count, "expected after cut:", expected.count, "decoded:", base.samples.count)
func diff(_ a: [Float], _ b: [Float]) -> Float { var m: Float = 0; for i in 0..<min(a.count, b.count) { m = max(m, abs(a[i]-b[i])) }; return m }
print("whole-feed vs ffmpeg max abs diff:", diff(base.samples, expected))
for seed in 0..<seeds {
  let r = run(chunker: { g in Int(g.next() % 4096) + 1 }, seed: UInt64(seed) + 7)
  let d = diff(r.samples, expected)
  worst = max(worst, d)
  let same = r.samples.count == expected.count
  let ident = r.samples == base.samples
  if !same || !ident { allEqual = false }
  firstBytes.append(r.firstAt ?? -1)
}
let tiny = run(chunker: { _ in 1 }, seed: 3)
print("1-byte chunks: count", tiny.samples.count, "identical to whole-feed:", tiny.samples == base.samples, "maxdiff", diff(tiny.samples, expected))
print("random 1..4096 B chunks x\(seeds): counts equal & bit-identical to whole-feed:", allEqual, "worst maxdiff vs ffmpeg:", worst)
print("bytes fed before first buffer (whole file \(mp3.count) B):", firstBytes.min()!, "...", firstBytes.max()!, "first-block at 0.1 s = 2400 frames")
// AVAudioFile whole-file decode
let url = URL(fileURLWithPath: args[1])
if let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) {
  print("AVAudioFile length:", f.length)
}
