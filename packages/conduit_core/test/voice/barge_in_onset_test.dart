import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/voice/barge_in_onset.dart';
import 'package:conduit_core/voice/voice_events.dart';
import 'package:test/test.dart';

const _frame = Duration(milliseconds: 32);

VoiceCaptureLevel _level(double dbfs) =>
    VoiceCaptureLevel(dbfs: dbfs, duration: _frame);

/// Feeds [frames] frames at [dbfs] and returns the first onset reported.
Duration? _feed(BargeInOnsetDetector detector, double dbfs, int frames) {
  Duration? onset;
  for (var i = 0; i < frames; i++) {
    onset ??= detector.add(_level(dbfs));
  }
  return onset;
}

void main() {
  group('BargeInOnsetDetector', () {
    test('never fires before playback arms it', () {
      final detector = BargeInOnsetDetector();
      _feed(detector, -60, 10);
      check(_feed(detector, -20, 40)).isNull();
    });

    test('fires on sustained speech above the floor, with pre-roll', () {
      final detector = BargeInOnsetDetector()..arm();
      check(_feed(detector, -60, 20)).isNull();
      check(_feed(detector, -25, 7)).isNull();
      check(detector.add(_level(-25)))
          .equals(const Duration(milliseconds: 256 + 500));
      // Once per turn.
      check(_feed(detector, -25, 20)).isNull();
    });

    test('ignores the grace period after playback starts', () {
      final detector = BargeInOnsetDetector()..arm();
      detector.add(_level(-60));
      // 9 loud frames: all inside the 300 ms grace period.
      check(_feed(detector, -20, 9)).isNull();
      check(_feed(detector, -60, 20)).isNull();
    });

    test('tolerates syllable gaps but not longer pauses', () {
      final detector = BargeInOnsetDetector()..arm();
      _feed(detector, -60, 20);
      // 128 ms above, 160 ms below: each burst starts over.
      for (var i = 0; i < 5; i++) {
        check(_feed(detector, -25, 4)).isNull();
        check(_feed(detector, -60, 5)).isNull();
      }
      // 128 ms above, a 64 ms dip, 128 ms above: one utterance.
      check(_feed(detector, -25, 4)).isNull();
      check(_feed(detector, -60, 2)).isNull();
      check(_feed(detector, -25, 4))
          .equals(const Duration(milliseconds: 320 + 500));
    });

    test('learns a steady echo residue into the floor', () {
      final detector = BargeInOnsetDetector()..arm();
      _feed(detector, -60, 20);
      // Residue that creeps up slowly never stands out from the floor.
      for (var level = -59.0; level <= -40; level += 0.25) {
        check(_feed(detector, level, 2)).isNull();
      }
      check(detector.thresholdDb).isGreaterThan(-35);
      check(_feed(detector, -15, 10)).isNotNull();
    });

    test('needs the absolute minimum level in a silent room', () {
      final detector = BargeInOnsetDetector()..arm();
      _feed(detector, -90, 20);
      check(detector.thresholdDb).equals(-50);
      check(_feed(detector, -60, 20)).isNull();
    });
  });

  group('Pcm16LevelMeter', () {
    Uint8List pcm(List<int> samples) {
      final data = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        data.setInt16(i * 2, samples[i], Endian.little);
      }
      return data.buffer.asUint8List();
    }

    test('reports one level per frame across chunk and byte boundaries', () {
      final meter = Pcm16LevelMeter(sampleRate: 16000, frameSamples: 4);
      final bytes = pcm(<int>[16384, -16384, 16384, -16384, 0, 0, 0, 0]);
      final levels = [
        ...meter.add(Uint8List.sublistView(bytes, 0, 3)),
        ...meter.add(Uint8List.sublistView(bytes, 3)),
      ];
      check(levels.length).equals(2);
      check(levels.first.dbfs).isCloseTo(-6.02, 0.01);
      check(levels.first.duration).equals(const Duration(microseconds: 250));
      check(levels.last.dbfs).equals(-100);
    });
  });
}
