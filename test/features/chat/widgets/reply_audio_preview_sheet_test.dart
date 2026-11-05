import 'dart:async';
import 'dart:io';

import 'package:conduit/features/chat/services/speech_take_store.dart';
import 'package:conduit/features/chat/widgets/reply_audio_preview_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePlayer implements ReplyAudioPreviewPlayer {
  final loaded = <String>[];
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();
  bool isPlaying = false;
  Duration length = const Duration(seconds: 31);
  bool disposed = false;

  @override
  Future<Duration?> load(File file) async {
    loaded.add(file.path);
    return length;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> seekToStart() async {}
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Future<void> dispose() async => disposed = true;
}

SpeechTake _take(String name) => SpeechTake(
  file: File('/tmp/$name.mp3'),
  extension: 'mp3',
  created: DateTime(2026, 11, 5),
  bytes: 10,
  messageId: 'm1',
  voiceKey: 'v',
);

void main() {
  Future<SpeechTake?> open(
    WidgetTester tester, {
    required _FakePlayer player,
    required Future<SpeechTake> Function() tryAgain,
    String action = 'Share',
  }) async {
    SpeechTake? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showReplyAudioPreview(
                  context,
                  take: _take('first'),
                  onTryAgain: tryAgain,
                  actionLabel: action,
                  playerFactory: () => player,
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    addTearDown(() => done);
    return Future.value(result);
  }

  testWidgets('shows play, the length, Try again and Share', (tester) async {
    final player = _FakePlayer();
    await open(tester, player: player, tryAgain: () async => _take('x'));
    expect(find.byKey(const ValueKey('reply-audio-play')), findsOneWidget);
    expect(find.text('0:00 / 0:31'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(player.loaded, ['/tmp/first.mp3']);

    await tester.tap(find.byKey(const ValueKey('reply-audio-play')));
    await tester.pump();
    expect(player.isPlaying, isTrue);
    await tester.tap(find.byKey(const ValueKey('reply-audio-play')));
    await tester.pump();
    expect(player.isPlaying, isFalse);
  });

  testWidgets('Try again shows progress, swaps the take, and can repeat', (
    tester,
  ) async {
    final player = _FakePlayer();
    final gates = <Completer<SpeechTake>>[];
    var n = 0;
    await open(
      tester,
      player: player,
      tryAgain: () {
        final c = Completer<SpeechTake>();
        gates.add(c);
        n++;
        return c.future;
      },
    );
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.text('Making a new take…'), findsOneWidget);
    // Share waits while a new take is being made.
    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(find.text('Making a new take…'), findsOneWidget);
    gates.single.complete(_take('second'));
    await tester.pumpAndSettle();
    expect(find.text('Making a new take…'), findsNothing);
    expect(player.loaded.last, '/tmp/second.mp3');

    await tester.tap(find.text('Try again'));
    await tester.pump();
    gates.last.complete(_take('third'));
    await tester.pumpAndSettle();
    expect(n, 2);
    expect(player.loaded.last, '/tmp/third.mp3');
  });

  testWidgets('a failed Try again keeps the current take', (tester) async {
    final player = _FakePlayer();
    await open(
      tester,
      player: player,
      tryAgain: () async => throw StateError('relay down'),
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't make a new take"), findsOneWidget);
    expect(player.loaded, ['/tmp/first.mp3']);
  });

  testWidgets('Share returns exactly the take last previewed', (tester) async {
    final player = _FakePlayer();
    SpeechTake? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showReplyAudioPreview(
                context,
                take: _take('first'),
                onTryAgain: () async => _take('second'),
                actionLabel: 'Share',
                playerFactory: () => player,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(result!.file.path, '/tmp/second.mp3');
    expect(player.disposed, isTrue);
  });
}
