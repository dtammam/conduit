import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/lip_sync.dart';
import 'package:conduit/features/chat/avatar/lip_sync_controller.dart';
import 'package:conduit/features/chat/avatar/persona_appearance_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _mouths({int count = 5}) => {
  for (final name in kMouthShapeNames.take(count))
    name: {
      'etag': 'e-$name',
      'content_type': 'image/png',
      'url': '/api/personas/uncle-ruckus/mouths/$name',
    },
};

/// Distinct providers for the core five, and for the extras when [extras].
Map<MouthShape, ImageProvider> _stills({bool extras = false}) => {
  for (final shape in MouthShape.values)
    if (extras || kMouthCoreShapes.contains(shape))
      shape: MemoryImage(Uint8List(1), scale: 1),
};

void main() {
  group('shapeForLevel', () {
    test('silence and gaps are closed', () {
      check(shapeForLevel(-100)).equals(MouthShape.closed);
      check(shapeForLevel(-48.1)).equals(MouthShape.closed);
      check(shapeForLevel(double.nan)).equals(MouthShape.closed);
    });

    test('five loudness buckets open the mouth step by step', () {
      check(shapeForLevel(-48)).equals(MouthShape.slight);
      check(shapeForLevel(-40.1)).equals(MouthShape.slight);
      check(shapeForLevel(-40)).equals(MouthShape.mid);
      check(shapeForLevel(-32.1)).equals(MouthShape.mid);
      check(shapeForLevel(-32)).equals(MouthShape.open);
      check(shapeForLevel(-24.1)).equals(MouthShape.open);
      check(shapeForLevel(-24)).equals(MouthShape.wide);
      check(shapeForLevel(-10)).equals(MouthShape.wide);
    });

    test('a mid-loud low sound is the rounded oo mouth', () {
      check(shapeForLevel(-30, zcrHz: 250)).equals(MouthShape.oo);
      check(shapeForLevel(-36, zcrHz: 250)).equals(MouthShape.oo);
      check(shapeForLevel(-30, zcrHz: 600)).equals(MouthShape.open);
      check(shapeForLevel(-30)).equals(MouthShape.open);
      // Quiet or loud sounds never round, whatever the pitch.
      check(shapeForLevel(-45, zcrHz: 250)).equals(MouthShape.slight);
      check(shapeForLevel(-15, zcrHz: 250)).equals(MouthShape.wide);
      check(shapeForLevel(-60, zcrHz: 250)).equals(MouthShape.closed);
    });

    test('a mid-loud bright sound is the wide flat ee mouth', () {
      check(shapeForLevel(-30, zcrHz: kMouthEeMinHz)).equals(MouthShape.ee);
      check(shapeForLevel(-36, zcrHz: 1200)).equals(MouthShape.ee);
      check(shapeForLevel(-30, zcrHz: kMouthEeMinHz - 1))
          .equals(MouthShape.open);
      // Loud bright sounds stay wide.
      check(shapeForLevel(-15, zcrHz: 1200)).equals(MouthShape.wide);
    });

    test('a quiet-to-mid noisy sound is the teeth-on-lip fv mouth', () {
      check(shapeForLevel(-45, zcrHz: kMouthFvMinHz)).equals(MouthShape.fv);
      check(shapeForLevel(-33, zcrHz: 3000)).equals(MouthShape.fv);
      // Not when it is loud (open range) or the pitch is only bright.
      check(shapeForLevel(-30, zcrHz: 3000)).equals(MouthShape.open);
      check(shapeForLevel(-45, zcrHz: 1200)).equals(MouthShape.slight);
      // Near silence is closed, noise or not.
      check(shapeForLevel(-60, zcrHz: 3000)).equals(MouthShape.closed);
    });

    test('a dip to near silence right after sound is the mbp mouth', () {
      check(shapeForLevel(-60, recentlyLoud: true)).equals(MouthShape.mbp);
      check(shapeForLevel(-60, recentlyLoud: false)).equals(MouthShape.closed);
      check(shapeForLevel(-30, recentlyLoud: true)).equals(MouthShape.open);
    });
  });

  group('resolveMouthShape', () {
    final core = kMouthCoreShapes.toSet();

    test('a shape the persona has is used as it is', () {
      check(resolveMouthShape(MouthShape.ee, MouthShape.values.toSet()))
          .equals(MouthShape.ee);
    });

    test('with only the old five, extras fall back to a core shape', () {
      check(resolveMouthShape(MouthShape.mid, core)).equals(MouthShape.slight);
      check(resolveMouthShape(MouthShape.ee, core)).equals(MouthShape.open);
      check(resolveMouthShape(MouthShape.fv, core)).equals(MouthShape.slight);
      check(resolveMouthShape(MouthShape.mbp, core)).equals(MouthShape.closed);
      for (final shape in kMouthCoreShapes) {
        check(resolveMouthShape(shape, core)).equals(shape);
      }
    });

    test('every fallback is a core shape', () {
      for (final fallback in kMouthFallback.values) {
        check(kMouthCoreShapes.contains(fallback)).isTrue();
      }
    });
  });

  group('MouthTracker', () {
    test('mbp follows loud sound only within the window', () {
      final t = MouthTracker();
      MouthShape? at(double db, int ms) => mouthShapeToShow(
        enabled: true,
        stillsReady: true,
        level: SpeechLevel(db, null, ms),
        nowMs: ms,
        tracker: t,
      );
      check(at(-30, 1000)).equals(MouthShape.open);
      // 47 ms of near silence: the hold has run 47 ms, mbp may cut in.
      check(at(-70, 1047)).equals(MouthShape.mbp);
      // Silence past the window is a plain closed mouth (hold passed too).
      check(at(-70, 1047 + kMouthMbpWindowMs + 10)).equals(MouthShape.closed);
    });
  });

  group('MouthHold', () {
    test('the first shape shows at once', () {
      final hold = MouthHold();
      check(hold.update(MouthShape.open, 1000)).equals(MouthShape.open);
    });

    test('the hold is 60 to 80 ms', () {
      check(kMouthMinHoldMs).isGreaterOrEqual(60);
      check(kMouthMinHoldMs).isLessOrEqual(80);
      check(kMouthFadeMs).isGreaterOrEqual(40);
      check(kMouthFadeMs).isLessOrEqual(60);
    });

    test('a change inside the hold is ignored, after it is taken', () {
      final hold = MouthHold();
      hold.update(MouthShape.open, 1000);
      check(hold.update(MouthShape.wide, 1040)).equals(MouthShape.open);
      check(hold.update(MouthShape.closed, kMouthMinHoldMs + 999))
          .equals(MouthShape.open);
      check(hold.update(MouthShape.wide, 1000 + kMouthMinHoldMs))
          .equals(MouthShape.wide);
      // The hold restarts from the change.
      check(hold.update(MouthShape.closed, 1100)).equals(MouthShape.wide);
      check(hold.update(MouthShape.closed, 1000 + 2 * kMouthMinHoldMs))
          .equals(MouthShape.closed);
    });

    test('mbp may cut a held shape short, other shapes may not', () {
      final hold = MouthHold();
      hold.update(MouthShape.open, 1000);
      check(hold.update(MouthShape.closed, 1000 + kMouthMbpInterruptMs))
          .equals(MouthShape.open);
      check(hold.update(MouthShape.mbp, 1000 + kMouthMbpInterruptMs - 1))
          .equals(MouthShape.open);
      check(hold.update(MouthShape.mbp, 1000 + kMouthMbpInterruptMs))
          .equals(MouthShape.mbp);
    });

    test('the same shape keeps its original start', () {
      final hold = MouthHold();
      hold.update(MouthShape.slight, 0);
      hold.update(MouthShape.slight, 70);
      check(hold.update(MouthShape.open, kMouthMinHoldMs + 1))
          .equals(MouthShape.open);
    });

    test('reset closes the mouth and forgets the hold', () {
      final hold = MouthHold();
      hold.update(MouthShape.wide, 0);
      hold.reset();
      check(hold.shape).equals(MouthShape.closed);
      check(hold.update(MouthShape.open, 10)).equals(MouthShape.open);
    });
  });

  group('mouthShapeToShow', () {
    const level = SpeechLevel(-30, null, 1000);

    test('falls back to null (today\'s behavior) without stills', () {
      final tracker = MouthTracker();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: false,
          level: level,
          nowMs: 1010,
          tracker: tracker,
        ),
      ).isNull();
    });

    test('is null when the setting is off or nothing is speaking', () {
      final tracker = MouthTracker();
      check(
        mouthShapeToShow(
          enabled: false,
          stillsReady: true,
          level: level,
          nowMs: 1010,
          tracker: tracker,
        ),
      ).isNull();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: true,
          level: null,
          nowMs: 1010,
          tracker: tracker,
        ),
      ).isNull();
    });

    test('a stale reading means the voice stopped', () {
      final tracker = MouthTracker();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: true,
          level: level,
          nowMs: 1000 + kMouthSilenceTimeoutMs + 1,
          tracker: tracker,
        ),
      ).isNull();
    });

    test('a fresh reading gives its shape', () {
      final tracker = MouthTracker();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: true,
          level: level,
          nowMs: 1010,
          tracker: tracker,
        ),
      ).equals(MouthShape.open);
    });
  });

  group('LipSyncController', () {
    late SpeechLevelMeter meter;
    var now = 0;
    late LipSyncController lip;
    var notified = 0;

    setUp(() {
      meter = SpeechLevelMeter.instance..clear();
      now = 1000;
      notified = 0;
      lip = LipSyncController(meter: meter, clock: () => now)
        ..addListener(() => notified++);
    });

    tearDown(() {
      lip.dispose();
      meter.clear();
    });

    test('without stills it stays on the idle clip while the voice plays', () {
      meter.push(-20, null, now);
      check(lip.shape).isNull();
      check(lip.current).isNull();
      check(notified).equals(0);
    });

    test('with stills it follows loudness and returns when playback stops', () {
      final stills = _stills();
      lip.setStills(stills);
      meter.push(-20, null, now);
      check(lip.shape).equals(MouthShape.wide);
      check(identical(lip.current, stills[MouthShape.wide])).isTrue();
      now += 100;
      meter.push(-60, null, now);
      check(lip.shape).equals(MouthShape.closed);
      now += 100;
      meter.clear();
      check(lip.shape).isNull();
      check(notified).equals(3);
    });

    test('flicker inside the hold does not change the shape', () {
      lip.setStills(_stills());
      meter.push(-20, null, now);
      now += 30;
      meter.push(-60, null, now);
      check(lip.shape).equals(MouthShape.wide);
      check(notified).equals(1);
    });

    test('with all nine stills the extras show up', () {
      final stills = _stills(extras: true);
      lip.setStills(stills);
      meter.push(-30, 1200, now);
      check(lip.shape).equals(MouthShape.ee);
      check(identical(lip.current, stills[MouthShape.ee])).isTrue();
    });

    test('with only the old five, an extra shows its fallback', () {
      final stills = _stills();
      lip.setStills(stills);
      meter.push(-30, 1200, now);
      check(lip.shape).equals(MouthShape.open);
      check(identical(lip.current, stills[MouthShape.open])).isTrue();
      now += 100;
      meter.push(-45, 3000, now);
      check(lip.shape).equals(MouthShape.slight);
    });

    test('turning the setting off drops back to the clip', () {
      lip.setStills(_stills());
      meter.push(-30, null, now);
      check(lip.shape).equals(MouthShape.open);
      lip.enabled = false;
      check(lip.shape).isNull();
    });

    test('losing the stills drops back to the clip', () {
      lip.setStills(_stills());
      meter.push(-30, null, now);
      lip.setStills(null);
      check(lip.shape).isNull();
    });
  });

  group('mouths in the persona appearance', () {
    Map<String, Object?> body(Object? mouths) => {
      'id': 'uncle-ruckus',
      'name': 'Uncle Ruckus',
      'appearance': {'clips': <String, Object?>{}, 'mouths': mouths},
    };

    test('the five core stills alone are a set (the old server)', () {
      final a = PersonaAppearance.fromServerJson(body(_mouths(count: 5)))!;
      check(a.mouths.keys.toList())
          .deepEquals(kMouthCoreShapes.map((s) => s.name).toList());
    });

    test('a full set is parsed with its urls', () {
      final a = PersonaAppearance.fromServerJson(body(_mouths(count: 9)))!;
      check(
        a.mouths.keys.toList(),
      ).deepEquals(kMouthShapeNames.take(9).toList());
      check(a.mouths['oo']!.url).equals('/api/personas/uncle-ruckus/mouths/oo');
    });

    test('a partial or missing set means no mouths at all', () {
      check(PersonaAppearance.fromServerJson(body(_mouths(count: 4)))!.mouths)
          .isEmpty();
      // Extras without the core set do not make a set either.
      final extrasOnly = {
        for (final e in _mouths(count: 9).entries.skip(5)) e.key: e.value,
      };
      check(PersonaAppearance.fromServerJson(body(extrasOnly))!.mouths)
          .isEmpty();
      check(PersonaAppearance.fromServerJson(body(null))!.mouths).isEmpty();
      check(PersonaAppearance.fromServerJson(body('x'))!.mouths).isEmpty();
    });

    test('the cache round trip keeps the etags and changes equality', () {
      final a = PersonaAppearance.fromServerJson(body(_mouths()))!;
      final back = PersonaAppearance.fromCacheJson(a.toJson())!;
      check(back.mouths['wide']!.etag).equals('e-wide');
      check(back == a).isTrue();
      final without = PersonaAppearance.fromServerJson(body(null))!;
      check(without == a).isFalse();
      check(without.toJson().containsKey('mouths')).isFalse();
    });
  });
}
