import 'dart:async';
import 'dart:io';

import 'package:conduit/features/chat/services/reply_audio_flow.dart';
import 'package:conduit/features/chat/services/reply_audio_prefetch.dart';
import 'package:conduit/features/chat/services/speech_take_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pre-generation with the relay replaced by a counter.
class _Rig {
  _Rig({this.cap = 5, int rechecks = 4}) {
    prefetcher = ReplyAudioPrefetcher(
      enabled: () => enabled,
      liveSpeechBusy: () => live,
      appActive: () => active,
      requestFor: (item) => ReplyAudioRequest(
        messageId: item.messageId,
        text: item.text,
        lookupVoiceKeys: [voice],
        renderVoiceKey: voice,
      ),
      savedTake: (request) async => takes['${request.messageId}|${request.renderVoiceKey}'],
      render: (request, {required stillWanted}) async {
        renders.add(request.messageId);
        final gate = gates[request.messageId];
        if (gate != null) await gate.future;
        if (failWith != null) throw failWith!;
        if (!stillWanted()) throw const ReplyAudioDropped();
        final take = SpeechTake(
          file: File('/tmp/${request.messageId}.mp3'),
          extension: 'mp3',
          created: DateTime(2026),
          bytes: 1,
          messageId: request.messageId,
          voiceKey: request.renderVoiceKey,
        );
        takes['${request.messageId}|${request.renderVoiceKey}'] = take;
        return take;
      },
      delay: Duration.zero,
      recheck: const Duration(milliseconds: 5),
      maxRechecks: rechecks,
      openCap: cap,
    );
  }

  final int cap;
  late final ReplyAudioPrefetcher prefetcher;
  bool enabled = true;
  bool live = false;
  bool active = true;
  String voice = 'direct|m|alloy';
  Object? failWith;
  final renders = <String>[];
  final takes = <String, SpeechTake>{};
  final gates = <String, Completer<void>>{};

  ReplyAudioPrefetchItem item(String id, {String? text, String chat = 'c1'}) =>
      ReplyAudioPrefetchItem(
        messageId: id,
        text: text ?? 'Reply $id. It has two sentences.',
        chatId: chat,
      );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

void main() {
  test('a finished reply is rendered once', () async {
    final r = _Rig();
    r.prefetcher.replyFinished(r.item('a'));
    r.prefetcher.replyFinished(r.item('a')); // the same reply again
    await r.settle();
    expect(r.renders, ['a']);
    // Rendered already: offering it again does nothing.
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a']);
  });

  test('nothing starts during live speech, then it goes ahead', () async {
    final r = _Rig(rechecks: 200)..live = true;
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, isEmpty);
    r.live = false;
    await r.settle();
    expect(r.renders, ['a']);
  });

  test('a render held back too long gives up and leaves nothing', () async {
    final r = _Rig()..live = true;
    r.prefetcher.replyFinished(r.item('a'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    r.live = false;
    await r.settle();
    expect(r.renders, isEmpty);
    expect(r.takes, isEmpty);
  });

  test('nothing starts while the app is not in front', () async {
    final r = _Rig()..active = false;
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, isEmpty);
  });

  test('the setting off means nothing fires', () async {
    final r = _Rig()..enabled = false;
    r.prefetcher.replyFinished(r.item('a'));
    await r.prefetcher.chatOpened(r.item('b'));
    await r.settle();
    expect(r.renders, isEmpty);
  });

  test('one render at a time, newest finished reply first', () async {
    final r = _Rig();
    r.gates['a'] = Completer<void>();
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    r.prefetcher.replyFinished(r.item('b'));
    r.prefetcher.replyFinished(r.item('c'));
    await r.settle();
    expect(r.renders, ['a'], reason: 'b and c wait for a');
    r.gates['a']!.complete();
    await r.settle();
    expect(r.renders, ['a', 'c', 'b']);
  });

  test('Listen during a render drops it: nothing is kept', () async {
    final r = _Rig();
    r.gates['a'] = Completer<void>();
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a']);
    r.prefetcher.drop('a');
    r.gates['a']!.complete();
    await r.settle();
    expect(r.takes, isEmpty);
    // And a queued one is dropped before it starts.
    final q = _Rig();
    q.gates['x'] = Completer<void>();
    q.prefetcher.replyFinished(q.item('x'));
    await q.settle();
    q.prefetcher.replyFinished(q.item('y'));
    q.prefetcher.drop('y');
    q.gates['x']!.complete();
    await q.settle();
    expect(q.renders, ['x']);
  });

  test('Share waits for a render of the same reply', () async {
    final r = _Rig();
    r.gates['a'] = Completer<void>();
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    final waiting = r.prefetcher.inFlightFor('a');
    expect(waiting, isNotNull);
    expect(r.prefetcher.inFlightFor('zzz'), isNull);
    r.gates['a']!.complete();
    await waiting;
    expect(r.takes, isNotEmpty);
  });

  test('opening a chat renders the newest without a take, up to the cap', () async {
    final r = _Rig(cap: 3);
    r.takes['heard|direct|m|alloy'] = SpeechTake(
      file: File('/tmp/x.mp3'),
      extension: 'mp3',
      created: DateTime(2026),
      bytes: 1,
      messageId: 'heard',
      voiceKey: 'direct|m|alloy',
    );
    // Offered newest first, as the rows appear from the bottom.
    for (final id in ['n1', 'heard', 'n2', 'n3', 'n4', 'n5']) {
      await r.prefetcher.chatOpened(r.item(id));
    }
    await r.settle();
    expect(r.renders, ['n1', 'n2', 'n3']);
  });

  test('a failure leaves nothing and does not loop', () async {
    final r = _Rig()..failWith = StateError('relay down');
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a']);
    expect(r.takes, isEmpty);
    // Offered again in the same chat open: not retried.
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a']);
    // Opening the chat again clears it.
    r.failWith = null;
    await r.prefetcher.chatOpened(r.item('a', chat: 'c2'));
    await r.settle();
    expect(r.renders, ['a', 'a']);
  });

  test('a changed voice renders the new voice only', () async {
    final r = _Rig();
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a']);
    r.voice = 'direct|m|nova';
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a', 'a']);
    expect(r.takes.keys, containsAll(['a|direct|m|alloy', 'a|direct|m|nova']));
  });

  test('replies with nothing to say or too long are left alone', () async {
    final r = _Rig();
    r.prefetcher.replyFinished(r.item('e', text: '   '));
    r.prefetcher.replyFinished(r.item('long', text: 'word ' * 2000));
    await r.settle();
    expect(r.renders, isEmpty);
  });

  test('Share while a background render runs: it is dropped, Share keeps one take', () async {
    final r = _Rig();
    r.gates['a'] = Completer<void>();
    r.prefetcher.replyFinished(r.item('a'));
    await r.settle();
    expect(r.renders, ['a']);
    // Share is pressed: the background render is dropped, not waited on.
    r.prefetcher.drop('a');
    // Share's own render (priority above background) makes the take.
    final shareTake = SpeechTake(
      file: File('/tmp/share-a.mp3'),
      extension: 'mp3',
      created: DateTime(2026),
      bytes: 1,
      messageId: 'a',
      voiceKey: r.voice,
    );
    r.takes['a|${r.voice}'] = shareTake;
    r.gates['a']!.complete();
    await r.settle();
    // The background result was thrown away: Share's take is the one kept.
    expect(r.takes['a|${r.voice}'], same(shareTake));
    expect(r.takes, hasLength(1));
    expect(r.renders, ['a'], reason: 'no second background render');
  });
}
