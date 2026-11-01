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

  test('toM4a goes through the native exportM4a call on iOS', () async {
    // Platform.isIOS is false on the test host, so this checks the fallback:
    // the MP3 comes back unchanged and no channel call is made.
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return '/tmp/share/x.m4a';
        });
    final out = await ReplyMp3Export.toM4a(File('/tmp/in/x.mp3'));
    if (Platform.isIOS) {
      expect(calls.single.method, 'exportM4a');
      expect(out.path, '/tmp/share/x.m4a');
    } else {
      expect(calls, isEmpty);
      expect(out.path, '/tmp/in/x.mp3');
    }
  });

  test('shareFile on iOS sends the file path only', () async {
    if (!Platform.isIOS) return;
    MethodCall? seen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          seen = call;
          return <String, Object?>{
            'completed': true,
            'activityType': 'com.hammerandchisel.discord.Share',
          };
        });
    final done = await ReplyMp3Export.shareFile(
      File('/tmp/share/x.m4a'),
      mimeType: 'audio/mp4',
    );
    expect(done, isTrue);
    expect(seen!.method, 'shareAudioFile');
    expect((seen!.arguments as Map)['path'], '/tmp/share/x.m4a');
  });
}
