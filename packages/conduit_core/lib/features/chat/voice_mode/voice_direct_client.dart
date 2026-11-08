/// Client for Contract A of the realtime voice program: one voice turn sent
/// straight to the relay (`POST <relay>:1236/voice/turn`), answered as a
/// server-sent event stream. See `~/srv/docs/VOICE-REALTIME.md`, section 12.1.
///
/// Pure Dart (dio only). The relay is the single writer of the chat in Open
/// WebUI on this path: nothing here, or in [VoiceDirectTurnRunner], writes to
/// Open WebUI.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';

/// The relay's chat port. The Voice provider points at the audio port (1237);
/// the same host and key serve the voice turn here.
const int voiceDirectRelayPort = 1236;

/// One message of the session history Musey sends. [content] is the message
/// text byte for byte, invisible card markers included.
final class VoiceHistoryEntry {
  const VoiceHistoryEntry({
    required this.id,
    required this.role,
    required this.content,
  });

  final String id;
  final String role;
  final String content;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'role': role,
    'content': content,
  };
}

final class VoiceDirectRequest {
  const VoiceDirectRequest({
    required this.turnId,
    required this.callId,
    required this.chatId,
    required this.text,
    required this.history,
    this.personaId,
    this.build = '',
    this.tz = '',
    this.test = false,
  });

  /// Client UUID v4. The idempotency key: a retry sends the same one.
  final String turnId;
  final String callId;
  final String chatId;
  final String? personaId;
  final String text;
  final List<VoiceHistoryEntry> history;
  final String build;
  final String tz;
  final bool test;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'turn_id': turnId,
    'call_id': callId,
    'chat_id': chatId,
    'persona_id': ?personaId,
    'text': text,
    'history': [for (final entry in history) entry.toJson()],
    'build': build,
    'tz': tz,
    if (test) 'test': true,
  };
}

sealed class VoiceDirectEvent {
  const VoiceDirectEvent();
}

final class VoiceDirectMeta extends VoiceDirectEvent {
  const VoiceDirectMeta({
    required this.turnId,
    required this.lane,
    required this.route,
    this.cache,
  });
  final String turnId;
  final String? lane;

  /// `direct` or `owui`.
  final String route;
  final Object? cache;

  bool get isOwui => route == 'owui';
}

final class VoiceDirectAck extends VoiceDirectEvent {
  const VoiceDirectAck(this.text);
  final String text;
}

/// A clause already past the relay's honesty gate: final, never retracted.
final class VoiceDirectDelta extends VoiceDirectEvent {
  const VoiceDirectDelta(this.text);
  final String text;
}

final class VoiceDirectDone extends VoiceDirectEvent {
  const VoiceDirectDone({
    required this.turnId,
    required this.userId,
    required this.assistantId,
    required this.content,
    required this.interrupted,
  });
  final String turnId;
  final String? userId;
  final String? assistantId;

  /// The full reply, markers included.
  final String content;
  final bool interrupted;
}

final class VoiceDirectError extends VoiceDirectEvent {
  const VoiceDirectError({required this.code, required this.message});
  final String code;
  final String message;

  /// The relay's `voice_direct` switch is off: same meaning as a 404.
  bool get meansUnavailable =>
      code == 'voice_direct_off' || code == 'unavailable';
}

/// `/voice/turn` is missing (404), refused (400, 401, 403, 501) or switched
/// off. Use the Open WebUI path, and stay on it for the rest of the call.
final class VoiceDirectUnavailable implements Exception {
  const VoiceDirectUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'VoiceDirectUnavailable: $reason';
}

/// The connection failed or the stream ended without `done`, on every try.
final class VoiceDirectNetworkException implements Exception {
  const VoiceDirectNetworkException(this.message);
  final String message;
  @override
  String toString() => 'VoiceDirectNetworkException: $message';
}

/// A random UUID v4 (the turn id).
String newVoiceTurnId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Parses an SSE byte stream into the JSON object of every `data:` line, in
/// order. A line that is not a JSON object is skipped. Comment lines (`:`)
/// and other fields are ignored.
Stream<Map<String, Object?>> parseVoiceSse(Stream<List<int>> bytes) async* {
  String? eventName;
  await for (final line
      in bytes.cast<List<int>>().transform(utf8.decoder).transform(
        const LineSplitter(),
      )) {
    if (line.isEmpty) {
      eventName = null;
      continue;
    }
    if (line.startsWith('event:')) {
      eventName = line.substring(6).trim();
      continue;
    }
    if (!line.startsWith('data:')) continue;
    var payload = line.substring(5);
    if (payload.startsWith(' ')) payload = payload.substring(1);
    if (payload.isEmpty || payload == '[DONE]') continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      continue;
    }
    if (decoded is Map) {
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));
      // The event name may ride in an SSE `event:` line instead of the JSON.
      if (eventName != null &&
          eventName.isNotEmpty &&
          json['type'] == null &&
          json['event'] == null) {
        json['type'] = eventName;
      }
      yield json;
    }
  }
}

VoiceDirectEvent? voiceDirectEventFromJson(Map<String, Object?> json) {
  String? str(String key) {
    final value = json[key];
    return value is String ? value : null;
  }

  // The relay names the event in `type` (or `event`); without a name, the
  // fields that only one event has say which it is.
  final name =
      json['type'] ??
      json['event'] ??
      (json.containsKey('route')
          ? 'meta'
          : json.containsKey('assistant_id')
          ? 'done'
          : (json.containsKey('code') && json.containsKey('message'))
          ? 'error'
          : null);
  switch (name) {
    case 'meta':
      return VoiceDirectMeta(
        turnId: str('turn_id') ?? '',
        lane: str('lane'),
        route: str('route') ?? 'direct',
        cache: json['cache'],
      );
    case 'ack':
      return VoiceDirectAck(str('text') ?? '');
    case 'delta':
      return VoiceDirectDelta(str('text') ?? '');
    case 'done':
      return VoiceDirectDone(
        turnId: str('turn_id') ?? '',
        userId: str('user_id'),
        assistantId: str('assistant_id'),
        content: str('content') ?? '',
        interrupted: json['interrupted'] == true,
      );
    case 'error':
      return VoiceDirectError(
        code: str('code') ?? 'error',
        message: str('message') ?? 'The voice turn failed.',
      );
  }
  return null;
}

/// Talks to `/voice/turn` and `/voice/saved` over [dio] (the Voice provider's
/// client: same key, headers and certificates as the speech requests).
final class VoiceDirectClient {
  VoiceDirectClient({
    required this.dio,
    required this.turnUri,
    Uri? savedUri,
    this.maxAttempts = 3,
    this.retryDelay = const Duration(milliseconds: 300),
  }) : savedUri = savedUri ?? turnUri.replace(path: '/voice/saved');

  /// The client for the Voice provider [profile]: its host, relay port 1236.
  factory VoiceDirectClient.forProfile(
    DirectConnectionProfile profile,
    Dio dio, {
    int port = voiceDirectRelayPort,
  }) {
    final base = profile.requestBaseUri();
    final turn = base.replace(
      port: port,
      path: '/voice/turn',
      query: '',
      fragment: '',
    );
    return VoiceDirectClient(dio: dio, turnUri: turn);
  }

  final Dio dio;
  final Uri turnUri;
  final Uri savedUri;
  final int maxAttempts;
  final Duration retryDelay;

  /// Sends the turn and yields its events in order, ending after `done` or
  /// `error`. A network failure (or a stream that ends without `done`) is
  /// retried with the same turn id; the relay replays the stored stream, so
  /// the deltas already yielded are skipped, never doubled.
  ///
  /// Throws [VoiceDirectUnavailable] when the route is missing or off, and
  /// [VoiceDirectNetworkException] when every try failed.
  Stream<VoiceDirectEvent> turn(
    VoiceDirectRequest request, {
    CancelToken? cancel,
  }) async* {
    var deltasYielded = 0;
    var metaYielded = false;
    var ackYielded = false;
    var owui = false;
    Object? lastFailure;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(retryDelay * (attempt - 1));
        if (cancel?.isCancelled ?? false) return;
      }
      var deltasSeen = 0;
      var finished = false;
      try {
        final response = await dio.postUri<ResponseBody>(
          turnUri,
          data: request.toJson(),
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            contentType: Headers.jsonContentType,
            headers: const {'Accept': 'text/event-stream'},
            validateStatus: (_) => true,
          ),
        );
        final status = response.statusCode ?? 0;
        final body = response.data;
        if (status == 404 ||
            status == 501 ||
            status == 400 ||
            status == 401 ||
            status == 403) {
          unawaited(body?.stream.drain<void>().catchError((Object _) {}));
          throw VoiceDirectUnavailable('http $status');
        }
        if (status < 200 || status >= 300 || body == null) {
          unawaited(body?.stream.drain<void>().catchError((Object _) {}));
          throw VoiceDirectNetworkException('http $status');
        }
        await for (final json in parseVoiceSse(body.stream)) {
          final event = voiceDirectEventFromJson(json);
          if (event == null) continue;
          switch (event) {
            case VoiceDirectMeta():
              if (event.isOwui) owui = true;
              if (metaYielded) continue;
              metaYielded = true;
              yield event;
            case VoiceDirectAck():
              if (ackYielded) continue;
              ackYielded = true;
              yield event;
            case VoiceDirectDelta():
              deltasSeen++;
              if (deltasSeen <= deltasYielded) continue;
              deltasYielded = deltasSeen;
              yield event;
            case VoiceDirectDone():
              finished = true;
              yield event;
              return;
            case VoiceDirectError():
              finished = true;
              yield event;
              return;
          }
        }
        // The owui route ends after meta and ack, with no `done`.
        if (owui) return;
        if (!finished) {
          throw const VoiceDirectNetworkException('stream ended without done');
        }
      } on VoiceDirectUnavailable {
        rethrow;
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) return;
        lastFailure = error.message ?? error.type.name;
      } on VoiceDirectNetworkException catch (error) {
        lastFailure = error.message;
      } on Exception catch (error) {
        // A body stream that breaks mid-way raises the raw io error (socket
        // closed, bad chunk), not a DioException.
        if (cancel?.isCancelled ?? false) return;
        lastFailure = error;
      }
    }
    throw VoiceDirectNetworkException('$lastFailure');
  }

  /// Waits until the relay's save queue for [chatId] is empty, so an Open WebUI
  /// send that follows finds every direct turn already stored. Returns true
  /// when drained (or when the relay cannot say), false on timeout.
  Future<bool> waitSaved(
    String chatId, {
    Duration timeout = const Duration(seconds: 6),
    Duration interval = const Duration(milliseconds: 300),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        final response = await dio.getUri<Object?>(
          savedUri.replace(queryParameters: {'chat_id': chatId}),
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
            validateStatus: (_) => true,
          ),
        );
        final data = response.data;
        final pending = data is Map ? data['pending'] : null;
        if (response.statusCode != 200 || pending is! num) return true;
        if (pending <= 0) return true;
      } on DioException {
        return true;
      }
      if (DateTime.now().add(interval).isAfter(deadline)) return false;
      await Future<void>.delayed(interval);
    }
  }
}

/// A [VoiceDirectClient] on loan from the connection pool.
final class VoiceDirectLease {
  VoiceDirectLease(this.client, this._release);
  final VoiceDirectClient client;
  final void Function() _release;
  void release() => _release();
}

/// Where the controller gets a client. Null when no Voice provider is set.
abstract interface class VoiceDirectAccess {
  VoiceDirectLease acquire();
}

final class PooledVoiceDirectAccess implements VoiceDirectAccess {
  PooledVoiceDirectAccess(this.profile, this.pool);
  final DirectConnectionProfile profile;
  final DirectHttpClientPool pool;

  @override
  VoiceDirectLease acquire() {
    final lease = pool.acquire(profile);
    return VoiceDirectLease(
      VoiceDirectClient.forProfile(profile, lease.dio),
      lease.release,
    );
  }
}
