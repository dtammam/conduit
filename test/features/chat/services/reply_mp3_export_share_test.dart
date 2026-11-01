import 'dart:io';

import 'package:conduit/features/chat/services/reply_mp3_export.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.cogwheel.conduit/speech_engine');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final variant in ['A', 'B', 'C']) {
    test(
      'Discord test $variant calls shareDiscordTest with the variant',
      () async {
        MethodCall? seen;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              seen = call;
              return <String, Object?>{
                'variant': variant,
                'path': '/tmp/share/x.mp3',
                'size': 12,
                'completed': true,
                'activityType': 'com.hammerandchisel.discord.Share',
                'error': '',
              };
            });
        final reply = await ReplyMp3Export.shareDiscordTest(
          variant,
          File('/tmp/in/x.mp3'),
          origin: const Rect.fromLTWH(1, 2, 3, 4),
        );
        expect(seen!.method, 'shareDiscordTest');
        final args = seen!.arguments as Map;
        expect(args['variant'], variant);
        expect(args['path'], '/tmp/in/x.mp3');
        expect(args['x'], 1.0);
        expect(args['h'], 4.0);
        expect(reply!['completed'], true);
        expect(reply['activityType'], contains('discord'));
      },
    );
  }

  test('Discord test returns null without a native side', () async {
    final reply = await ReplyMp3Export.shareDiscordTest(
      'A',
      File('/tmp/in/x.mp3'),
    );
    expect(reply, isNull);
  });
}
