import 'dart:io';

import 'package:conduit/features/chat/services/speech_take_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late DateTime clock;
  late List<String> excluded;
  late SpeechTakeStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('take_store_');
    clock = DateTime(2026, 11, 5, 12);
    excluded = [];
    store = SpeechTakeStore(
      supportDirectory: () async => tmp,
      now: () => clock,
      excludeFromBackup: (d) async => excluded.add(d.path),
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<File> source(List<int> bytes) async {
    final f = File('${tmp.path}/src_${bytes.length}_${bytes.first}.bin');
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<SpeechTake> save(
    String id,
    String voice,
    String text,
    List<int> bytes, {
    String? chat,
  }) async => store.save(
    messageId: id,
    voiceKey: voice,
    text: text,
    source: await source(bytes),
    extension: 'mp3',
    chatId: chat,
  );

  test('a saved take comes back for the same message, voice and text', () async {
    await save('m1', 'direct|a|alloy', 'Hello there.', [1, 2, 3]);
    final found = await store.find(
      messageId: 'm1',
      voiceKey: 'direct|a|alloy',
      text: 'Hello there.',
    );
    expect(found, isNotNull);
    expect(await found!.file.readAsBytes(), [1, 2, 3]);
    expect(found.mimeType, 'audio/mpeg');
    expect(excluded, hasLength(1));
    expect(excluded.single, endsWith('speech_takes'));
  });

  test('another voice is another take', () async {
    await save('m1', 'voice-a', 'Hello there.', [1]);
    await save('m1', 'voice-b', 'Hello there.', [2]);
    final a = await store.find(
      messageId: 'm1',
      voiceKey: 'voice-a',
      text: 'Hello there.',
    );
    final b = await store.find(
      messageId: 'm1',
      voiceKey: 'voice-b',
      text: 'Hello there.',
    );
    expect(await a!.file.readAsBytes(), [1]);
    expect(await b!.file.readAsBytes(), [2]);
    expect(
      await store.find(
        messageId: 'm1',
        voiceKey: 'voice-c',
        text: 'Hello there.',
      ),
      isNull,
    );
  });

  test('a newer take replaces the one before', () async {
    await save('m1', 'v', 'Hello there.', [1, 1]);
    await save('m1', 'v', 'Hello there.', [9, 9, 9]);
    final found = await store.find(
      messageId: 'm1',
      voiceKey: 'v',
      text: 'Hello there.',
    );
    expect(await found!.file.readAsBytes(), [9, 9, 9]);
    final files = Directory('${tmp.path}/speech_takes/m1').listSync();
    expect(files.where((f) => f.path.endsWith('.mp3')), hasLength(1));
  });

  test('changed text invalidates the take', () async {
    await save('m1', 'v', 'Hello there.', [1]);
    expect(
      await store.find(messageId: 'm1', voiceKey: 'v', text: 'Hello there, friend.'),
      isNull,
    );
    // The stale file is gone, not just hidden.
    expect(
      await store.find(messageId: 'm1', voiceKey: 'v', text: 'Hello there.'),
      isNull,
    );
  });

  test('markup and spacing do not change which text it is', () async {
    await save('m1', 'v', 'Hello **there**.', [1]);
    expect(
      await store.find(messageId: 'm1', voiceKey: 'v', text: 'hello   there'),
      isNotNull,
    );
  });

  test('a voice-call take is found by text and filed under its message', () async {
    await save('', 'v', 'Spoken in a call.', [4, 5], chat: null);
    final found = await store.find(
      messageId: 'm7',
      voiceKey: 'v',
      text: 'Spoken in a call.',
      chatId: 'chat-1',
    );
    expect(await found!.file.readAsBytes(), [4, 5]);
    expect(found.messageId, 'm7');
    expect(found.file.path, contains('/m7/'));
    // Claimed once: the loose copy is gone, and deleting the chat removes it.
    await store.removeChat('chat-1');
    expect(
      await store.find(messageId: 'm7', voiceKey: 'v', text: 'Spoken in a call.'),
      isNull,
    );
  });

  test('deleting messages and chats removes their takes', () async {
    await save('m1', 'v', 'One.', [1], chat: 'c1');
    await save('m2', 'v', 'Two.', [2], chat: 'c1');
    await save('m3', 'v', 'Three.', [3], chat: 'c2');
    await store.removeMessages(['m1']);
    expect(await store.find(messageId: 'm1', voiceKey: 'v', text: 'One.'), isNull);
    await store.removeChat('c1');
    expect(await store.find(messageId: 'm2', voiceKey: 'v', text: 'Two.'), isNull);
    expect(await store.find(messageId: 'm3', voiceKey: 'v', text: 'Three.'), isNotNull);
  });

  test('the sweep removes takes older than 30 days', () async {
    await save('old', 'v', 'Old.', [1]);
    clock = clock.add(const Duration(days: 29));
    await save('new', 'v', 'New.', [2]);
    clock = clock.add(const Duration(days: 2));
    await store.sweep();
    expect(await store.find(messageId: 'old', voiceKey: 'v', text: 'Old.'), isNull);
    expect(await store.find(messageId: 'new', voiceKey: 'v', text: 'New.'), isNotNull);
  });

  test('past the size cap the oldest go first', () async {
    await save('a', 'v', 'A.', List.filled(100, 1));
    clock = clock.add(const Duration(hours: 1));
    await save('b', 'v', 'B.', List.filled(100, 2));
    clock = clock.add(const Duration(hours: 1));
    await save('c', 'v', 'C.', List.filled(100, 3));
    await store.sweep(cap: 250);
    expect(await store.find(messageId: 'a', voiceKey: 'v', text: 'A.'), isNull);
    expect(await store.find(messageId: 'b', voiceKey: 'v', text: 'B.'), isNotNull);
    expect(await store.find(messageId: 'c', voiceKey: 'v', text: 'C.'), isNotNull);
  });

  test('the sweep clears a recording a crash left behind', () async {
    final work = await store.workDirectory('tts-9');
    await File('${work.path}/clip_0.part').writeAsBytes([1]);
    await store.sweep();
    expect(work.existsSync(), isFalse);
  });
}
