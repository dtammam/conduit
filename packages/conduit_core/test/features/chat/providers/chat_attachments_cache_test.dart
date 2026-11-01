import 'dart:async';

import 'package:conduit_core/features/chat/providers/attachment_payload_cache.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:test/test.dart';

/// The request builder as it was before the cache, kept here as the
/// reference the new one must match.
Future<Map<String, dynamic>> oldBuild({
  required dynamic api,
  required String role,
  required String cleanedText,
  required List<String> attachmentIds,
}) async {
  final List<Map<String, dynamic>> contentArray = [];
  if (cleanedText.isNotEmpty) {
    contentArray.add({'type': 'text', 'text': cleanedText});
  }
  final allFiles = <Map<String, dynamic>>[];
  for (final attachmentId in attachmentIds) {
    try {
      if (attachmentId.startsWith('data:image/')) {
        contentArray.add({
          'type': 'image_url',
          'image_url': {'url': attachmentId},
        });
        continue;
      }
      final fileInfo = await api.getFileInfo(attachmentId);
      final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'Unknown';
      final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
      final contentType =
          fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';
      final isImage = contentType.toString().startsWith('image/');
      if (isImage) {
        try {
          final fileContent = await api.getFileContent(attachmentId);
          String dataUrl;
          if (fileContent.startsWith('data:')) {
            dataUrl = fileContent;
          } else {
            final mimeType = contentType.isNotEmpty
                ? contentType.toString()
                : mimeTypeFromFileNameForTest(fileName) ?? 'image/png';
            dataUrl = 'data:$mimeType;base64,$fileContent';
          }
          contentArray.add({
            'type': 'image_url',
            'image_url': {'url': dataUrl},
          });
        } catch (error) {
          // skipped
        }
      } else {
        final filePayload = <String, dynamic>{
          'type': 'file',
          'id': attachmentId,
          'url': attachmentId,
          'name': fileName,
        };
        if (fileSize != null) {
          filePayload['size'] = fileSize;
        }
        allFiles.add(filePayload);
      }
    } catch (_) {}
  }
  final messageMap = <String, dynamic>{
    'role': role,
    'content': contentArray.isNotEmpty ? contentArray : cleanedText,
  };
  if (allFiles.isNotEmpty) {
    messageMap['files'] = allFiles;
  }
  return messageMap;
}

class FakeApi {
  FakeApi(this.infos, this.contents);

  final Map<String, Map<String, dynamic>> infos;
  final Map<String, String> contents;
  final Set<String> failInfo = {};
  final Set<String> failContent = {};
  final Map<String, Completer<void>> gates = {};
  int infoCalls = 0;
  int contentCalls = 0;
  int running = 0;
  int maxRunning = 0;
  final List<String> started = [];

  Future<void> _work(String id) async {
    started.add(id);
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      await (gates[id]?.future ?? Future<void>.delayed(Duration.zero));
    } finally {
      running--;
    }
  }

  Future<Map<String, dynamic>> getFileInfo(String id) async {
    infoCalls++;
    await _work(id);
    if (failInfo.contains(id)) throw StateError('info $id');
    return infos[id]!;
  }

  Future<String> getFileContent(String id) async {
    contentCalls++;
    await _work(id);
    if (failContent.contains(id)) throw StateError('content $id');
    return contents[id]!;
  }

  int get calls => infoCalls + contentCalls;

  void resetCounts() {
    infoCalls = 0;
    contentCalls = 0;
    started.clear();
    maxRunning = 0;
  }
}

FakeApi fixtureApi() => FakeApi(
  {
    'img1': {
      'filename': 'a.png',
      'meta': {'content_type': 'image/png', 'size': 10},
    },
    'img2': {'name': 'b.jpg', 'content_type': 'image/jpeg', 'size': 20},
    'img3': {
      'filename': 'noext',
      'meta': {'content_type': ''},
    },
    'img4': {
      'filename': 'd.webp',
      'meta': {'content_type': 'image/webp'},
    },
    'doc1': {
      'filename': 'r.pdf',
      'size': 999,
      'meta': {'content_type': 'application/pdf'},
    },
    'doc2': {'name': 'n.txt', 'content_type': 'text/plain'},
  },
  {
    'img1': 'QUJD',
    'img2': 'data:image/jpeg;base64,REVG',
    'img3': 'R0hJ',
    'img4': 'SktM',
  },
);

// A chat's history: several messages, mixed attachments, a repeated id.
const fixtureChat = <List<String>>[
  [],
  ['img1', 'doc1', 'img2'],
  ['doc2'],
  ['img3', 'data:image/png;base64,INLINE', 'img1', 'img4', 'doc1'],
  ['img2', 'img2'],
];

Future<List<Map<String, dynamic>>> buildChat(
  FakeApi api,
  Future<Map<String, dynamic>> Function({
    required dynamic api,
    required String role,
    required String cleanedText,
    required List<String> attachmentIds,
  })
  build,
) async {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < fixtureChat.length; i++) {
    out.add(
      await build(
        api: api,
        role: 'user',
        cleanedText: i.isEven ? 'text $i' : '',
        attachmentIds: fixtureChat[i],
      ),
    );
  }
  return out;
}

void main() {
  setUp(() => setAttachmentCacheForTest(AttachmentPayloadCache()));

  group('attachment payload cache', () {
    test(
      'first turn and a second turn from cache equal the old output',
      () async {
        final expected = await buildChat(fixtureApi(), oldBuild);

        final api = fixtureApi();
        final first = await buildChat(
          api,
          buildMessagePayloadWithAttachmentsForTest,
        );
        expect(first, equals(expected));

        api.resetCounts();
        final second = await buildChat(
          api,
          buildMessagePayloadWithAttachmentsForTest,
        );
        expect(second, equals(expected));
        expect(api.calls, 0, reason: 'cached ids make no network calls');
      },
    );

    test('order of images and files follows the attachments', () async {
      final api = fixtureApi();
      // Make the first image the slowest to arrive.
      api.gates['img1'] = Completer<void>();
      final pending = buildMessagePayloadWithAttachmentsForTest(
        api: api,
        role: 'user',
        cleanedText: 'hi',
        attachmentIds: ['img1', 'doc1', 'img3', 'doc2', 'img4'],
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      api.gates['img1']!.complete();
      final message = await pending;
      final expected = await oldBuild(
        api: fixtureApi(),
        role: 'user',
        cleanedText: 'hi',
        attachmentIds: ['img1', 'doc1', 'img3', 'doc2', 'img4'],
      );
      expect(message, equals(expected));
      final urls = [
        for (final part in message['content'] as List)
          if (part['type'] == 'image_url') part['image_url']['url'],
      ];
      expect(urls, [
        'data:image/png;base64,QUJD',
        'data:image/webp;base64,SktM',
      ]);
    });

    test('no more than four fetches run at once', () async {
      final ids = [for (var i = 0; i < 10; i++) 'x$i'];
      final api = FakeApi(
        {
          for (final id in ids)
            id: {
              'filename': '$id.png',
              'meta': {'content_type': 'image/png'},
            },
        },
        {for (final id in ids) id: 'QQ=='},
      );
      for (final id in ids) {
        api.gates[id] = Completer<void>();
      }
      final pending = buildMessagePayloadWithAttachmentsForTest(
        api: api,
        role: 'user',
        cleanedText: '',
        attachmentIds: ids,
      );
      for (var round = 0; round < 40; round++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        for (final gate in api.gates.values) {
          if (!gate.isCompleted && api.started.isNotEmpty) {
            // Release in start order, one at a time.
          }
        }
        for (final id in List.of(api.started)) {
          final gate = api.gates[id]!;
          if (!gate.isCompleted) gate.complete();
        }
      }
      final message = await pending;
      expect(api.maxRunning, lessThanOrEqualTo(4));
      expect(api.maxRunning, greaterThan(1));
      expect((message['content'] as List).length, 10);
    });

    test('the cache evicts the oldest past its byte cap', () {
      final cache = AttachmentPayloadCache(maxBytes: 1200, maxEntryBytes: 600);
      AttachmentFileEntry entry(int size) => AttachmentFileEntry(
        fileName: 'f',
        fileSize: null,
        contentType: 'image/png',
        dataUrl: 'x' * size,
      );
      cache.put('a', entry(300));
      cache.put('b', entry(300));
      cache.get('a'); // a is now the newest
      cache.put('c', entry(300));
      expect(cache.contains('a'), isTrue);
      expect(cache.contains('b'), isFalse, reason: 'least recently used goes');
      expect(cache.contains('c'), isTrue);
      expect(cache.bytes, lessThanOrEqualTo(1200));
      cache.put('big', entry(700));
      expect(cache.get('big')!.dataUrl, isNull, reason: 'over the entry limit');
    });

    test('a different api client drops the cache', () async {
      final first = fixtureApi();
      await buildMessagePayloadWithAttachmentsForTest(
        api: first,
        role: 'user',
        cleanedText: '',
        attachmentIds: ['img1'],
      );
      final second = fixtureApi();
      await buildMessagePayloadWithAttachmentsForTest(
        api: second,
        role: 'user',
        cleanedText: '',
        attachmentIds: ['img1'],
      );
      expect(second.calls, 2);
    });

    test('a failed fetch is not cached and acts as before', () async {
      final api = fixtureApi()
        ..failInfo.add('doc1')
        ..failContent.add('img1');
      final ref = fixtureApi()
        ..failInfo.add('doc1')
        ..failContent.add('img1');
      final ids = ['img1', 'doc1', 'img2'];
      final expected = await oldBuild(
        api: ref,
        role: 'user',
        cleanedText: 't',
        attachmentIds: ids,
      );
      final got = await buildMessagePayloadWithAttachmentsForTest(
        api: api,
        role: 'user',
        cleanedText: 't',
        attachmentIds: ids,
      );
      expect(got, equals(expected));

      // The server recovers: the failed ones are fetched again and appear.
      api.failInfo.clear();
      api.failContent.clear();
      api.resetCounts();
      final healed = await buildMessagePayloadWithAttachmentsForTest(
        api: api,
        role: 'user',
        cleanedText: 't',
        attachmentIds: ids,
      );
      final healedExpected = await oldBuild(
        api: fixtureApi(),
        role: 'user',
        cleanedText: 't',
        attachmentIds: ids,
      );
      expect(healed, equals(healedExpected));
      // img2 came from cache; doc1 (info) and img1 (content) were fetched.
      expect(api.infoCalls, 1);
      expect(api.contentCalls, 1);
    });
  });
}
