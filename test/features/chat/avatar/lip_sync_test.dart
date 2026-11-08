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

List<ImageProvider> _stills() => [
  for (var i = 0; i < kMouthShapeNames.length; i++)
    MemoryImage(Uint8List(1), scale: 1),
];

void main() {
  group('shapeForLevel', () {
    test('silence and gaps are closed', () {
      check(shapeForLevel(-100)).equals(MouthShape.closed);
      check(shapeForLevel(-48.1)).equals(MouthShape.closed);
      check(shapeForLevel(double.nan)).equals(MouthShape.closed);
    });

    test('louder buckets open the mouth step by step', () {
      check(shapeForLevel(-48)).equals(MouthShape.slight);
      check(shapeForLevel(-37)).equals(MouthShape.slight);
      check(shapeForLevel(-36)).equals(MouthShape.open);
      check(shapeForLevel(-25)).equals(MouthShape.open);
      check(shapeForLevel(-24)).equals(MouthShape.wide);
      check(shapeForLevel(-10)).equals(MouthShape.wide);
    });

    test('a mid-loud low sound is the rounded oo mouth', () {
      check(shapeForLevel(-30, zcrHz: 250)).equals(MouthShape.oo);
      check(shapeForLevel(-30, zcrHz: 600)).equals(MouthShape.open);
      check(shapeForLevel(-30)).equals(MouthShape.open);
      // Quiet or loud sounds never round, whatever the pitch.
      check(shapeForLevel(-45, zcrHz: 250)).equals(MouthShape.slight);
      check(shapeForLevel(-15, zcrHz: 250)).equals(MouthShape.wide);
      check(shapeForLevel(-60, zcrHz: 250)).equals(MouthShape.closed);
    });
  });

  group('MouthHold', () {
    test('the first shape shows at once', () {
      final hold = MouthHold();
      check(hold.update(MouthShape.open, 1000)).equals(MouthShape.open);
    });

    test('a change inside the hold is ignored, after it is taken', () {
      final hold = MouthHold();
      hold.update(MouthShape.open, 1000);
      check(hold.update(MouthShape.wide, 1040)).equals(MouthShape.open);
      check(hold.update(MouthShape.closed, 1079)).equals(MouthShape.open);
      check(hold.update(MouthShape.wide, 1080)).equals(MouthShape.wide);
      // The hold restarts from the change.
      check(hold.update(MouthShape.closed, 1100)).equals(MouthShape.wide);
      check(hold.update(MouthShape.closed, 1160)).equals(MouthShape.closed);
    });

    test('the same shape keeps its original start', () {
      final hold = MouthHold();
      hold.update(MouthShape.slight, 0);
      hold.update(MouthShape.slight, 70);
      check(hold.update(MouthShape.open, 81)).equals(MouthShape.open);
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
      final hold = MouthHold();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: false,
          level: level,
          nowMs: 1010,
          hold: hold,
        ),
      ).isNull();
    });

    test('is null when the setting is off or nothing is speaking', () {
      final hold = MouthHold();
      check(
        mouthShapeToShow(
          enabled: false,
          stillsReady: true,
          level: level,
          nowMs: 1010,
          hold: hold,
        ),
      ).isNull();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: true,
          level: null,
          nowMs: 1010,
          hold: hold,
        ),
      ).isNull();
    });

    test('a stale reading means the voice stopped', () {
      final hold = MouthHold();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: true,
          level: level,
          nowMs: 1000 + kMouthSilenceTimeoutMs + 1,
          hold: hold,
        ),
      ).isNull();
    });

    test('a fresh reading gives its shape', () {
      final hold = MouthHold();
      check(
        mouthShapeToShow(
          enabled: true,
          stillsReady: true,
          level: level,
          nowMs: 1010,
          hold: hold,
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
      check(identical(lip.current, stills[MouthShape.wide.index])).isTrue();
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

    test('a full set is parsed with its urls', () {
      final a = PersonaAppearance.fromServerJson(body(_mouths()))!;
      check(a.mouths.keys.toList()).deepEquals(kMouthShapeNames);
      check(a.mouths['oo']!.url).equals('/api/personas/uncle-ruckus/mouths/oo');
    });

    test('a partial or missing set means no mouths at all', () {
      check(PersonaAppearance.fromServerJson(body(_mouths(count: 4)))!.mouths)
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
