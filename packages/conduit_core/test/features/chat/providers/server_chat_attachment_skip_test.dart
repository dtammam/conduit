import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

class _CountingApi {
  int calls = 0;

  Future<Map<String, dynamic>> getFileInfo(String id) async {
    calls++;
    return {
      'filename': '$id.png',
      'meta': {'content_type': 'image/png'},
    };
  }

  Future<String> getFileContent(String id) async {
    calls++;
    return 'AAAA$id';
  }
}

List<ChatMessage> _history() => [
  ChatMessage(
    id: 'u1',
    role: 'user',
    content: 'look at this',
    timestamp: DateTime.utc(2026, 1, 1),
    attachmentIds: const ['img1', 'img2'],
  ),
  ChatMessage(
    id: 'a1',
    role: 'assistant',
    content: 'nice',
    timestamp: DateTime.utc(2026, 1, 1),
  ),
  ChatMessage(
    id: 'u2',
    role: 'user',
    content: 'and this',
    timestamp: DateTime.utc(2026, 1, 2),
    attachmentIds: const ['img3'],
  ),
];

void main() {
  test('server chat: same request, no attachment fetches', () async {
    // Before the change: build everything, then keep only system messages.
    final before = (await buildOpenWebUiCompletionRequestMessagesForTest(
      messages: _history(),
      api: _CountingApi(),
      systemPrompt: 'Be brief.',
    )).where((m) => m['role'] == 'system').toList();

    final api = _CountingApi();
    final after = await buildOpenWebUiCompletionRequestMessagesForTest(
      messages: _history(),
      api: api,
      isTemporary: false,
      systemPrompt: 'Be brief.',
    );
    expect(after, before);
    expect(after, isNotEmpty);
    expect(api.calls, 0);
  });

  test('temporary chat still embeds images', () async {
    final api = _CountingApi();
    final out = await buildOpenWebUiCompletionRequestMessagesForTest(
      messages: _history(),
      api: api,
    );
    expect(api.calls, greaterThan(0));
    expect(out.first['content'], isA<List>());
    expect(
      (out.first['content'] as List).any((p) => p['type'] == 'image_url'),
      isTrue,
    );
  });
}
