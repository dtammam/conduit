import 'dart:math' as math;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/lip_sync.dart';
import 'package:conduit/features/chat/avatar/lip_sync_controller.dart';
import 'package:conduit_core/features/chat/server_speech/viseme_timeline.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Map<MouthShape, ImageProvider> _stills({bool accents = false}) => {
  for (final shape in MouthShape.values)
    if (accents || !shape.isAccent) shape: MemoryImage(Uint8List(1), scale: 1),
};

VisemeTimeline _timeline(String id, List<(int, String)> keys) => VisemeTimeline(
  id: id,
  durationMs: keys.last.$1,
  keys: [for (final k in keys) VisemeKey(k.$1, k.$2)],
);

/// closed 0, open 100, wide 400, slight 700, closed 900.
VisemeTimeline _a() => _timeline('aaaa', [
  (0, 'closed'),
  (100, 'open'),
  (400, 'wide'),
  (700, 'slight'),
  (900, 'closed'),
]);

VisemeTimeline _b() => _timeline('bbbb', [(0, 'oo'), (200, 'closed')]);

void main() {
  late SpeechLevelMeter meter;
  late VisemeStore store;
  var now = 0;

  setUp(() {
    meter = SpeechLevelMeter.instance..clear();
    store = VisemeStore();
    now = 1000;
  });

  tearDown(() => meter.clear());

  LipSyncController make({math.Random? random, bool accents = false}) {
    final lip = LipSyncController(
      meter: meter,
      clock: () => now,
      visemes: store,
      random: random,
    )..setStills(_stills(accents: accents));
    addTearDown(lip.dispose);
    return lip;
  }

  group('names', () {
    test('accents use the server names', () {
      check(MouthShape.browOpen.serverName).equals('brow_open');
      check(mouthShapeFromName('brow_wide')).equals(MouthShape.browWide);
      check(mouthShapeFromName('blink')).equals(MouthShape.blink);
      check(mouthShapeFromName('nope')).isNull();
      check(kMouthShapeNames).contains('brow_open');
    });
  });

  group('SpeechPosition', () {
    test('carries on from the report and leads by the named constant', () {
      const p = SpeechPosition('x', 500, 1000);
      check(p.posAt(1000)).equals(500 + kMouthLeadMs);
      check(p.posAt(1040)).equals(540 + kMouthLeadMs);
      // A clock that went backwards never moves the position back.
      check(p.posAt(900)).equals(500 + kMouthLeadMs);
    });
  });

  group('following a timeline', () {
    test('the shape comes from the playback position, lead included', () {
      store.put('aaaa', _a());
      final lip = make();
      // 70 ms in plus the 30 ms lead reads at 100: open.
      meter.pushPosition('aaaa', 70, now);
      check(lip.shape).equals(MouthShape.open);
      check(lip.followsTimeline).isTrue();
      // 69 ms in reads at 99: still closed.
      meter.clear();
      now += 500;
      meter.pushPosition('aaaa', 69, now);
      check(lip.shape).equals(MouthShape.closed);
    });

    test('later positions step through the clip, holding 40 ms', () {
      store.put('aaaa', _a());
      final lip = make();
      meter.pushPosition('aaaa', 100, now);
      check(lip.shape).equals(MouthShape.open);
      now += 300;
      meter.pushPosition('aaaa', 400, now);
      check(lip.shape).equals(MouthShape.wide);
      now += 30;
      meter.pushPosition('aaaa', 700, now);
      // The hold (40 ms) has not passed since wide began.
      check(lip.shape).equals(MouthShape.wide);
      now += 20;
      meter.pushPosition('aaaa', 750, now);
      check(lip.shape).equals(MouthShape.slight);
    });

    test('between reports the position is carried forward', () {
      store.put('aaaa', _a());
      final lip = make();
      meter.pushPosition('aaaa', 0, now);
      check(lip.shape).equals(MouthShape.closed);
      now += 100;
      // No new report, a store event re-reads: 0 + 100 + 30 = 130, open.
      store.put('zzzz', _b());
      check(lip.shape).equals(MouthShape.open);
    });

    test('at a chunk boundary the next chunk reads from its own start', () {
      store.put('aaaa', _a());
      store.put('bbbb', _b());
      final lip = make();
      meter.pushPosition('aaaa', 850, now);
      check(lip.shape).equals(MouthShape.slight);
      now += 50;
      meter.pushPosition('bbbb', 0, now);
      // bbbb at 0 + lead is oo.
      check(lip.shape).equals(MouthShape.oo);
      now += 100;
      meter.pushPosition('bbbb', 150, now);
      check(lip.shape).equals(MouthShape.oo);
      now += 100;
      meter.pushPosition('bbbb', 250, now);
      check(lip.shape).equals(MouthShape.closed);
    });

    test('past the end of a timeline the last entry holds', () {
      store.put('aaaa', _a());
      final lip = make();
      meter.pushPosition('aaaa', 5000, now);
      check(lip.shape).equals(MouthShape.closed);
    });

    test('an unknown shape name falls back to loudness', () {
      store.put('cccc', _timeline('cccc', [(0, 'zzz')]));
      final lip = make();
      meter.push(-20, null, now);
      meter.pushPosition('cccc', 10, now);
      check(lip.followsTimeline).isFalse();
      check(lip.shape).equals(MouthShape.wide);
    });
  });

  group('loudness fallback', () {
    test('with no id, no timeline yet, or none ever, loudness decides', () {
      final lip = make();
      meter.push(-20, null, now);
      check(lip.shape).equals(MouthShape.wide);
      check(lip.followsTimeline).isFalse();
      // A position with no id.
      now += 300;
      meter.push(-60, null, now);
      meter.pushPosition(null, 10, now);
      check(lip.shape).equals(MouthShape.closed);
      // An id the store does not have (404 or still on its way).
      now += 100;
      meter.push(-20, null, now);
      meter.pushPosition('nope', 10, now);
      check(lip.shape).equals(MouthShape.wide);
      check(lip.followsTimeline).isFalse();
    });

    test('a timeline arriving mid-chunk switches the mouth over', () {
      final lip = make();
      meter.push(-20, null, now);
      meter.pushPosition('aaaa', 30, now);
      check(lip.shape).equals(MouthShape.wide);
      check(lip.followsTimeline).isFalse();
      // The timeline lands 100 ms later; position carried to 30+100+30=160.
      now += 100;
      store.put('aaaa', _a());
      check(lip.followsTimeline).isTrue();
      check(lip.shape).equals(MouthShape.open);
    });

    test('a stale position is not followed and the mouth goes idle', () {
      store.put('aaaa', _a());
      final lip = make();
      meter.pushPosition('aaaa', 150, now);
      check(lip.shape).equals(MouthShape.open);
      now += kMouthPositionStaleMs + 50;
      store.put('zzzz', _b());
      check(lip.shape).isNull();
    });

    test('a position alone (just_audio, no loudness) speaks', () {
      store.put('aaaa', _a());
      final lip = make();
      meter.pushPosition('aaaa', 450, now);
      check(lip.shape).equals(MouthShape.wide);
      meter.clearPosition();
      check(lip.shape).isNull();
    });
  });

  group('blinks', () {
    test('first blink is 3 to 6 s in, then every 3 to 6 s (seeded)', () {
      final accents = FaceAccents(random: math.Random(7));
      final avail = {MouthShape.blink};
      final starts = <int>[];
      var t = 0;
      var blinking = false;
      while (t < 40000) {
        final shape = accents.apply(
          MouthShape.closed,
          nowMs: t,
          available: avail,
          fading: false,
          loud: false,
        );
        if (shape == MouthShape.blink && !blinking) starts.add(t);
        blinking = shape == MouthShape.blink;
        t += 20;
      }
      check(starts.length).isGreaterOrEqual(6);
      check(starts.first).isGreaterOrEqual(kBlinkMinGapMs);
      check(starts.first).isLessOrEqual(kBlinkMaxGapMs + 20);
      for (var i = 1; i < starts.length; i++) {
        final gap = starts[i] - starts[i - 1];
        check(gap).isGreaterOrEqual(kBlinkMinGapMs);
        check(gap).isLessOrEqual(kBlinkMaxGapMs + 20);
      }
      // The same seed gives the same blinks.
      final again = FaceAccents(random: math.Random(7));
      var t2 = 0;
      var seen = 0;
      var inBlink = false;
      while (t2 < 40000) {
        final s = again.apply(
          MouthShape.closed,
          nowMs: t2,
          available: avail,
          fading: false,
          loud: false,
        );
        if (s == MouthShape.blink && !inBlink) {
          check(t2).equals(starts[seen++]);
        }
        inBlink = s == MouthShape.blink;
        t2 += 20;
      }
      check(seen).equals(starts.length);
    });

    test('a blink lasts about 120 ms', () {
      final accents = FaceAccents(random: math.Random(1));
      final avail = {MouthShape.blink};
      int? began;
      int? ended;
      for (var t = 0; t < 8000; t += 10) {
        final s = accents.apply(
          MouthShape.slight,
          nowMs: t,
          available: avail,
          fading: false,
          loud: false,
        );
        if (s == MouthShape.blink) began ??= t;
        if (began != null && ended == null && s != MouthShape.blink) ended = t;
      }
      check(ended! - began!).equals(kBlinkMs);
    });

    test('never over an open mouth: the blink waits for a closed one', () {
      final accents = FaceAccents(random: math.Random(3));
      final avail = {MouthShape.blink};
      // Speak open for 10 s: no blink.
      for (var t = 0; t < 10000; t += 20) {
        final s = accents.apply(
          MouthShape.open,
          nowMs: t,
          available: avail,
          fading: false,
          loud: false,
        );
        check(s).equals(MouthShape.open);
      }
      // The first closed moment takes the overdue blink at once.
      final s = accents.apply(
        MouthShape.closed,
        nowMs: 10000,
        available: avail,
        fading: false,
        loud: false,
      );
      check(s).equals(MouthShape.blink);
    });

    test('an opening mouth cuts a blink short', () {
      final accents = FaceAccents(random: math.Random(3));
      final avail = {MouthShape.blink};
      var t = 0;
      while (accents.apply(
            MouthShape.closed,
            nowMs: t,
            available: avail,
            fading: false,
            loud: false,
          ) !=
          MouthShape.blink) {
        t += 10;
      }
      check(
        accents.apply(
          MouthShape.wide,
          nowMs: t + 40,
          available: avail,
          fading: false,
          loud: false,
        ),
      ).equals(MouthShape.wide);
    });

    test('not during a cross-fade', () {
      final accents = FaceAccents(random: math.Random(3));
      final avail = {MouthShape.blink};
      for (var t = 0; t < 8000; t += 20) {
        final s = accents.apply(
          MouthShape.closed,
          nowMs: t,
          available: avail,
          fading: true,
          loud: false,
        );
        check(s).equals(MouthShape.closed);
      }
    });

    test('without a blink still there are no blinks', () {
      final accents = FaceAccents(random: math.Random(3));
      for (var t = 0; t < 20000; t += 20) {
        final s = accents.apply(
          MouthShape.closed,
          nowMs: t,
          available: const {},
          fading: false,
          loud: false,
        );
        check(s).equals(MouthShape.closed);
      }
    });

    test('the controller blinks over a closed mouth when the still exists', () {
      store.put('aaaa', _timeline('aaaa', [(0, 'closed'), (30000, 'closed')]));
      final lip = make(random: math.Random(5), accents: true);
      var blinks = 0;
      var was = false;
      var pos = 0;
      for (var i = 0; i < 400; i++) {
        meter.pushPosition('aaaa', pos, now);
        final is_ = lip.shape == MouthShape.blink;
        if (is_ && !was) blinks++;
        was = is_;
        now += 25;
        pos += 25;
      }
      // 10 s of closed mouth at 3 to 6 s apart is 1 to 3 blinks.
      check(blinks).isGreaterOrEqual(1);
      check(blinks).isLessOrEqual(3);
    });
  });

  group('brows', () {
    test('a loud open or wide mouth raises a brow for at least 300 ms', () {
      final accents = FaceAccents(random: math.Random(1));
      final avail = {MouthShape.browOpen, MouthShape.browWide};
      var t = 0;
      // 2 s of ordinary speech first, so there is speaking time to spend.
      for (; t < 2000; t += 20) {
        accents.apply(
          MouthShape.open,
          nowMs: t,
          available: avail,
          fading: false,
          loud: false,
        );
      }
      final s = accents.apply(
        MouthShape.wide,
        nowMs: t,
        available: avail,
        fading: false,
        loud: true,
      );
      check(s).equals(MouthShape.browWide);
      // Loudness drops and the mouth closes: the brow stays 300 ms.
      final held = accents.apply(
        MouthShape.closed,
        nowMs: t + 280,
        available: avail,
        fading: false,
        loud: false,
      );
      check(held).equals(MouthShape.browWide);
      final released = accents.apply(
        MouthShape.closed,
        nowMs: t + 320,
        available: avail,
        fading: false,
        loud: false,
      );
      check(released).equals(MouthShape.closed);
    });

    test('open uses brow_open, wide uses brow_wide', () {
      final accents = FaceAccents(random: math.Random(1));
      final avail = {MouthShape.browOpen, MouthShape.browWide};
      for (var t = 0; t < 2000; t += 20) {
        accents.apply(
          MouthShape.slight,
          nowMs: t,
          available: avail,
          fading: false,
          loud: false,
        );
      }
      check(
        accents.apply(
          MouthShape.open,
          nowMs: 2000,
          available: avail,
          fading: false,
          loud: true,
        ),
      ).equals(MouthShape.browOpen);
    });

    test('no brow before there is speaking time, and none when quiet', () {
      final accents = FaceAccents(random: math.Random(1));
      final avail = {MouthShape.browOpen, MouthShape.browWide};
      check(
        accents.apply(
          MouthShape.wide,
          nowMs: 0,
          available: avail,
          fading: false,
          loud: true,
        ),
      ).equals(MouthShape.wide);
      for (var t = 20; t < 5000; t += 20) {
        check(
          accents.apply(
            MouthShape.wide,
            nowMs: t,
            available: avail,
            fading: false,
            loud: false,
          ),
        ).equals(MouthShape.wide);
      }
    });

    test('brow time stays under 30 percent of speaking time', () {
      final accents = FaceAccents(random: math.Random(1));
      final avail = {MouthShape.browOpen, MouthShape.browWide};
      var browMs = 0;
      var total = 0;
      // A voice that is loud and wide all the time asks for brows all the
      // time; the cap decides.
      for (var t = 0; t < 60000; t += 20) {
        final s = accents.apply(
          MouthShape.wide,
          nowMs: t,
          available: avail,
          fading: false,
          loud: true,
        );
        total += 20;
        if (s == MouthShape.browWide) browMs += 20;
      }
      check(browMs).isGreaterThan(0);
      check(browMs / total).isLessOrEqual(0.3 + 0.01);
      check(accents.browMs / accents.speakingMs).isLessOrEqual(0.31);
    });

    test('a set without brow shapes keeps the plain mouth', () {
      final accents = FaceAccents(random: math.Random(1));
      for (var t = 0; t < 5000; t += 20) {
        check(
          accents.apply(
            MouthShape.wide,
            nowMs: t,
            available: const {},
            fading: false,
            loud: true,
          ),
        ).equals(MouthShape.wide);
      }
    });

    test('the controller uses brows from a loud timeline with loudness', () {
      store.put('aaaa', _timeline('aaaa', [(0, 'wide'), (60000, 'closed')]));
      final lip = make(random: math.Random(2), accents: true);
      var browSeen = false;
      var pos = 0;
      for (var i = 0; i < 200; i++) {
        meter.push(-20, null, now);
        meter.pushPosition('aaaa', pos, now);
        if (lip.shape == MouthShape.browWide) browSeen = true;
        now += 25;
        pos += 25;
      }
      check(browSeen).isTrue();
    });
  });

  group('LoudnessRange', () {
    test('the top of the range is near the chunk peak and not quiet', () {
      final r = LoudnessRange()..note('a', -20);
      check(r.isTop(-20)).isTrue();
      check(r.isTop(-23)).isTrue();
      check(r.isTop(-30)).isFalse();
      r.note('b', -40);
      check(r.isTop(-40)).isFalse(); // under the floor
      r.note('b', -28);
      check(r.isTop(-28)).isTrue();
    });
  });
}
