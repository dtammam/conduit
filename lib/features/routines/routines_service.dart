import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';

const String _logScope = 'routines/server';

/// How long a request to the routines server may take.
const Duration kRoutinesRequestTimeout = Duration(seconds: 6);

/// The marker line the routines server puts first in an automation's prompt:
/// `[check-in:<slug> quiet keep=N]`.
final RegExp _routineMarker = RegExp(
  r'^\s*\[check-in:([a-z0-9][a-z0-9-]{0,47})((?:[ \t]+[a-z]+(?:=\d+)?)*)\][ \t]*\n?',
  caseSensitive: false,
);

/// The slug of the routine whose automation prompt is [prompt], or null for
/// an automation that is not a routine.
String? routineSlugOf(String prompt) =>
    _routineMarker.firstMatch(prompt)?.group(1)?.toLowerCase();

/// [prompt] without its marker line, for showing to a person.
String stripRoutineMarker(String prompt) =>
    prompt.replaceFirst(_routineMarker, '').trim();

/// Normalizes the address a person typed: trimmed, `http://` when no scheme
/// is given, no trailing slash. Null when empty or not an http(s) address.
String? normalizeRoutinesUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'http://$value';
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// What the server holds about a routine's latest runs.
class RoutineLast {
  const RoutineLast({this.at, this.text = '', this.quietAt});

  /// When the last reply that was worth sending came.
  final DateTime? at;

  /// That reply's text, empty when there is none.
  final String text;

  /// When the latest "Nothing new." run was, if there was one.
  final DateTime? quietAt;

  static RoutineLast? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    return RoutineLast(
      at: _time(json['at']),
      text: text is String ? text : '',
      quietAt: _time(json['quiet_at']),
    );
  }

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;

  @override
  bool operator ==(Object other) =>
      other is RoutineLast &&
      other.at == at &&
      other.text == text &&
      other.quietAt == quietAt;

  @override
  int get hashCode => Object.hash(at, text, quietAt);
}

/// The server's push settings.
class PushSettings {
  const PushSettings({
    required this.quiet,
    required this.quietStart,
    required this.quietEnd,
    this.quietNow = false,
    this.devices = 0,
    this.held = 0,
  });

  final bool quiet;

  /// `HH:MM`, the person's time.
  final String quietStart;
  final String quietEnd;
  final bool quietNow;
  final int devices;
  final int held;

  static PushSettings? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = json['quiet_start'];
    final end = json['quiet_end'];
    if (start is! String || end is! String) return null;
    return PushSettings(
      quiet: json['quiet'] == true,
      quietStart: start,
      quietEnd: end,
      quietNow: json['quiet_now'] == true,
      devices: _count(json['devices']),
      held: _count(json['held']),
    );
  }

  static int _count(Object? value) => value is num
      ? value.toInt()
      : value is List
      ? value.length
      : 0;

  PushSettings copyWith({bool? quiet, String? quietStart, String? quietEnd}) =>
      PushSettings(
        quiet: quiet ?? this.quiet,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
        quietNow: quietNow,
        devices: devices,
        held: held,
      );

  @override
  bool operator ==(Object other) =>
      other is PushSettings &&
      other.quiet == quiet &&
      other.quietStart == quietStart &&
      other.quietEnd == quietEnd &&
      other.quietNow == quietNow &&
      other.devices == devices &&
      other.held == held;

  @override
  int get hashCode =>
      Object.hash(quiet, quietStart, quietEnd, quietNow, devices, held);
}

/// Talks to the routines server (the chat relay on SANDYJAR): the last result
/// of each routine, push settings, and push registration. The bearer token is
/// the one stored for Switchboard; it is only ever sent in the Authorization
/// header and never logged.
///
/// Every call answers null or false instead of throwing: the routines list
/// must still show when this server is away.
class RoutinesService {
  RoutinesService({Dio? dio, this.timeout = kRoutinesRequestTimeout})
    : _dio = dio ?? Dio();

  final Dio _dio;
  final Duration timeout;

  Future<Map<String, RoutineLast>?> last({
    required String base,
    required String token,
  }) async {
    final body = await _request('GET', base, token, '/routines/last');
    if (body is! Map) return null;
    final out = <String, RoutineLast>{};
    for (final entry in body.entries) {
      final parsed = RoutineLast.fromJson(entry.value);
      if (entry.key is String && parsed != null) {
        out[(entry.key as String).toLowerCase()] = parsed;
      }
    }
    return out;
  }

  Future<PushSettings?> settings({
    required String base,
    required String token,
  }) async => PushSettings.fromJson(
    await _request('GET', base, token, '/push/settings'),
  );

  /// Changes the given settings and returns the server's new ones, or null.
  Future<PushSettings?> updateSettings({
    required String base,
    required String token,
    bool? quiet,
    String? quietStart,
    String? quietEnd,
  }) async => PushSettings.fromJson(
    await _request(
      'PUT',
      base,
      token,
      '/push/settings',
      body: {
        'quiet': ?quiet,
        'quiet_start': ?quietStart,
        'quiet_end': ?quietEnd,
      },
    ),
  );

  Future<bool> sendTest({
    required String base,
    required String token,
    required String title,
    required String body,
  }) async =>
      await _request(
        'POST',
        base,
        token,
        '/push/test',
        body: {'title': title, 'body': body},
      ) !=
      null;

  Future<bool> registerDevice({
    required String base,
    required String token,
    required String deviceToken,
    required String key,
    required String env,
    required String bundle,
    required String name,
  }) async =>
      await _request(
        'POST',
        base,
        token,
        '/push/devices',
        body: {
          'token': deviceToken,
          'key': key,
          'env': env,
          'bundle': bundle,
          'name': name,
        },
      ) !=
      null;

  Future<bool> removeDevice({
    required String base,
    required String token,
    required String deviceToken,
  }) async =>
      await _request(
        'POST',
        base,
        token,
        '/push/devices/remove',
        body: {'token': deviceToken},
      ) !=
      null;

  /// The decoded JSON answer (an empty map for an empty body) on a 2xx, else
  /// null.
  Future<Object?> _request(
    String method,
    String base,
    String token,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final cancel = CancelToken();
    final timer = Timer(timeout, () => cancel.cancel('timeout'));
    try {
      final response = await _dio.request<Object>(
        '$base$path',
        data: body == null ? null : jsonEncode(body),
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: {
            'Authorization': 'Bearer $token',
            if (body != null) 'Content-Type': 'application/json',
          },
          responseType: ResponseType.plain,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        DebugLogger.log(
          'bad-status',
          scope: _logScope,
          data: {'path': path, 'status': status},
        );
        return null;
      }
      final data = response.data;
      if (data is String) {
        return data.trim().isEmpty
            ? const <String, Object?>{}
            : jsonDecode(data);
      }
      // A JSON content type may already have been decoded.
      return data ?? const <String, Object?>{};
    } on DioException catch (error) {
      DebugLogger.log(
        'unreachable',
        scope: _logScope,
        data: {'path': path, 'type': error.type.name},
      );
      return null;
    } on FormatException {
      return null;
    } finally {
      timer.cancel();
    }
  }
}
