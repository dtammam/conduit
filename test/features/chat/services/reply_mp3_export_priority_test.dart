import 'dart:typed_data';

import 'package:conduit/features/chat/services/reply_mp3_export.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with the relay's 202 and remembers what was sent.
final class _Relay implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    return ResponseBody.fromString(
      '{"url":"https://relay.invalid/x.mp3","estimate":{"audio_s":30,"render_s":20}}',
      202,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Relay relay;
  late Dio dio;

  setUp(() {
    relay = _Relay();
    dio = Dio(BaseOptions(baseUrl: 'https://relay.invalid/v1/'))
      ..httpClientAdapter = relay;
  });

  test('a background render says so on POST audio/export', () async {
    final ticket = await ReplyMp3Export.startWith(dio, 'Hello.', background: true);
    expect(ticket, isNotNull);
    expect(relay.seen.single.path, 'audio/export');
    expect(
      relay.seen.single.headers[ReplyMp3Export.priorityHeader],
      'background',
    );
    expect(ReplyMp3Export.priorityHeader, 'x-audio-export-priority');
  });

  test('Share and Try again send no priority header', () async {
    await ReplyMp3Export.startWith(dio, 'Hello.');
    expect(
      relay.seen.single.headers.containsKey(ReplyMp3Export.priorityHeader),
      isFalse,
    );
  });
}
