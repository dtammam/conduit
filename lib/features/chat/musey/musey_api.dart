import 'dart:async';

import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const Duration _requestTimeout = Duration(seconds: 8);

/// One option of a choice field (`{"value","label"}`).
@immutable
class MuseyOption {
  const MuseyOption({required this.value, required this.label});

  final String value;
  final String label;
}

enum MuseyFieldType { choice, text, number, date, time }

/// One slot of an action (`fields[]` of `GET /musey/actions`).
@immutable
class MuseyField {
  const MuseyField({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.options = const <MuseyOption>[],
    this.defaultValue,
    this.showWhenKey,
    this.showWhenValue,
    this.note,
    this.suggestions = const <MuseyOption>[],
  });

  final String key;
  final String label;
  final MuseyFieldType type;
  final bool required;
  final List<MuseyOption> options;

  /// The relay's suggested value, as sent (string or number), or null.
  final Object? defaultValue;

  /// This field shows only while the field [showWhenKey] has the value
  /// [showWhenValue] (`show_when` of the relay). Null: always shown.
  final String? showWhenKey;
  final String? showWhenValue;

  /// A short helper line under the field.
  final String? note;

  /// Known values for a text field (`suggestions` of the relay, possibly
  /// several hundred). The form lists the ones matching what is typed; free
  /// text stays allowed. Empty: a plain text field.
  final List<MuseyOption> suggestions;

  /// A field the relay reveals only for one value (the "Other" text) counts as
  /// required once it shows, whatever its own flag says.
  bool get mustFill => required || showWhenKey != null;

  /// Whether the field shows given the current values of the other fields.
  bool visibleGiven(String? Function(String key) valueOf) =>
      showWhenKey == null || valueOf(showWhenKey!) == showWhenValue;
}

/// One action of the wrench menu.
@immutable
class MuseyAction {
  const MuseyAction({
    required this.id,
    required this.label,
    this.icon,
    this.fields = const <MuseyField>[],
  });

  final String id;
  final String label;

  /// An SF Symbol name the relay suggests; the app falls back to a wrench.
  final String? icon;
  final List<MuseyField> fields;

  /// The one required choice field that makes a single tap send, or null when
  /// the action needs more than that tap.
  MuseyField? get oneTapField => oneTapFieldGiven((_) => null);

  /// Like [oneTapField], counting only the fields visible given the current
  /// values ([valueOf] by field key).
  MuseyField? oneTapFieldGiven(String? Function(String key) valueOf) {
    final required = fields
        .where((f) => f.mustFill && f.visibleGiven(valueOf))
        .toList();
    if (required.length != 1) return null;
    final field = required.single;
    return field.type == MuseyFieldType.choice && field.options.isNotEmpty
        ? field
        : null;
  }
}

MuseyFieldType? _fieldType(Object? raw) => switch (raw) {
  'choice' => MuseyFieldType.choice,
  'text' => MuseyFieldType.text,
  'number' => MuseyFieldType.number,
  'date' => MuseyFieldType.date,
  'time' => MuseyFieldType.time,
  _ => null,
};

/// `[{value, label}]` entries; malformed ones are skipped, a missing label
/// falls back to the value.
List<MuseyOption> _parseOptions(Object? raw) {
  final out = <MuseyOption>[];
  if (raw is! List) return out;
  for (final o in raw) {
    if (o is! Map) continue;
    final value = o['value'];
    final label = o['label'];
    if (value is! String || value.isEmpty) continue;
    out.add(MuseyOption(value: value, label: label is String ? label : value));
  }
  return out;
}

/// The actions in a `GET /musey/actions` answer. Malformed entries are
/// skipped; anything that is not the expected shape gives an empty list.
List<MuseyAction> parseMuseyActions(Object? data) {
  if (data is! Map) return const [];
  final list = data['actions'];
  if (list is! List) return const [];
  final out = <MuseyAction>[];
  for (final entry in list) {
    if (entry is! Map) continue;
    final id = entry['id'];
    final label = entry['label'];
    if (id is! String || id.isEmpty || label is! String || label.isEmpty) {
      continue;
    }
    final fields = <MuseyField>[];
    var valid = true;
    final rawFields = entry['fields'];
    if (rawFields is List) {
      for (final f in rawFields) {
        if (f is! Map) {
          valid = false;
          break;
        }
        final key = f['key'];
        final fLabel = f['label'];
        final type = _fieldType(f['type']);
        if (key is! String ||
            key.isEmpty ||
            fLabel is! String ||
            type == null) {
          valid = false;
          break;
        }
        final options = _parseOptions(f['options']);
        final suggestions = _parseOptions(f['suggestions']);
        final showWhen = f['show_when'];
        final note = f['note'];
        fields.add(
          MuseyField(
            showWhenKey: showWhen is Map && showWhen['key'] is String
                ? showWhen['key'] as String
                : null,
            showWhenValue: showWhen is Map && showWhen['value'] != null
                ? showWhen['value'].toString()
                : null,
            note: note is String && note.isNotEmpty ? note : null,
            key: key,
            label: fLabel,
            type: type,
            required: f['required'] == true,
            options: options,
            suggestions: type == MuseyFieldType.text
                ? suggestions
                : const <MuseyOption>[],
            defaultValue: f['default'],
          ),
        );
      }
    }
    if (!valid) continue;
    final icon = entry['icon'];
    out.add(
      MuseyAction(
        id: id,
        label: label,
        icon: icon is String && icon.isNotEmpty ? icon : null,
        fields: fields,
      ),
    );
  }
  return out;
}

/// Why a Musey relay call failed. [badSlot] is the relay's own `{"error"}`
/// text for a 400, which is shown to Dean as is.
class MuseyApiException implements Exception {
  const MuseyApiException(this.message, {this.badSlot = false});

  final String message;
  final bool badSlot;

  @override
  String toString() => 'MuseyApiException($message)';
}

/// A reply marked as broken, with Dean's note (`POST /musey/flags`).
@immutable
class MuseyFlag {
  const MuseyFlag({
    required this.localId,
    required this.chatId,
    required this.messageId,
    required this.replyText,
    required this.userText,
    required this.note,
    required this.ts,
    required this.build,
    this.persona,
  });

  /// Names this entry in the local retry queue; never sent.
  final String localId;
  final String chatId;
  final String messageId;
  final String replyText;
  final String userText;
  final String note;
  final DateTime ts;
  final String build;
  final String? persona;

  Map<String, Object?> toJson() => <String, Object?>{
    'chat_id': chatId,
    'message_id': messageId,
    'reply_text': replyText,
    'user_text': userText,
    'note': note,
    'ts': ts.toUtc().toIso8601String(),
    'build': build,
    'persona': ?persona,
  };

  /// The queue form: the wire body plus [localId].
  Map<String, Object?> toQueueJson() => <String, Object?>{
    ...toJson(),
    'local_id': localId,
  };

  static MuseyFlag? fromQueueJson(Object? json) {
    if (json is! Map) return null;
    final id = json['local_id'];
    final chat = json['chat_id'];
    final message = json['message_id'];
    final note = json['note'];
    final ts = json['ts'];
    if (id is! String ||
        chat is! String ||
        message is! String ||
        note is! String ||
        ts is! String) {
      return null;
    }
    final at = DateTime.tryParse(ts);
    if (at == null) return null;
    final reply = json['reply_text'];
    final user = json['user_text'];
    final build = json['build'];
    final persona = json['persona'];
    return MuseyFlag(
      localId: id,
      chatId: chat,
      messageId: message,
      replyText: reply is String ? reply : '',
      userText: user is String ? user : '',
      note: note,
      ts: at,
      build: build is String ? build : '',
      persona: persona is String ? persona : null,
    );
  }
}

/// The relay's Musey routes. A fake of this stands in for the relay in tests.
abstract class MuseyApi {
  Future<List<MuseyAction>> fetchActions();

  /// The text to send as a normal user message. Returned exactly as the relay
  /// gave it: it carries an invisible marker, so it is never trimmed or
  /// normalised.
  Future<String> compose(String action, Map<String, Object?> slots);

  /// True when the relay took the flag.
  Future<bool> postFlag(MuseyFlag flag);
}

/// [MuseyApi] over the Voice provider's own client: same address, key,
/// headers and certificates the speech and open-posts requests use.
class DioMuseyApi implements MuseyApi {
  DioMuseyApi(this._ref);

  final Ref _ref;

  Future<Response<Object?>> _call(
    String method,
    String path, {
    Object? data,
  }) async {
    final voice = _ref.read(directVoiceProviderProvider);
    if (voice == null) {
      throw const MuseyApiException('No Voice provider is set.');
    }
    final lease = _ref
        .read(directHttpClientPoolProvider)
        .acquire(voice.profile);
    try {
      final url = voice.profile.requestBaseUri().replace(
        path: path,
        query: '',
        fragment: '',
      );
      return await lease.dio.requestUri<Object?>(
        url,
        data: data,
        options: Options(
          method: method,
          sendTimeout: _requestTimeout,
          receiveTimeout: _requestTimeout,
          validateStatus: (_) => true,
        ),
      );
    } finally {
      lease.release();
    }
  }

  @override
  Future<List<MuseyAction>> fetchActions() async {
    final Response<Object?> response;
    try {
      response = await _call('GET', '/musey/actions');
    } on MuseyApiException {
      rethrow;
    } catch (_) {
      throw const MuseyApiException('Could not reach the relay.');
    }
    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status < 200 ||
        status >= 300 ||
        data is! Map ||
        data['actions'] is! List) {
      throw const MuseyApiException('The relay did not return the actions.');
    }
    return parseMuseyActions(data);
  }

  @override
  Future<String> compose(String action, Map<String, Object?> slots) async {
    final Response<Object?> response;
    try {
      response = await _call(
        'POST',
        '/musey/actions/compose',
        data: <String, Object?>{'action': action, 'slots': slots},
      );
    } on MuseyApiException {
      rethrow;
    } catch (_) {
      throw const MuseyApiException('Could not reach the relay.');
    }
    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status == 400) {
      final error = data is Map ? data['error'] : null;
      throw MuseyApiException(
        error is String && error.isNotEmpty ? error : 'Check the fields.',
        badSlot: true,
      );
    }
    final text = data is Map ? data['text'] : null;
    if (status < 200 || status >= 300 || text is! String || text.isEmpty) {
      throw const MuseyApiException('The relay could not build that message.');
    }
    return text;
  }

  @override
  Future<bool> postFlag(MuseyFlag flag) async {
    try {
      final response = await _call('POST', '/musey/flags', data: flag.toJson());
      final status = response.statusCode ?? 0;
      return status >= 200 && status < 300;
    } catch (_) {
      return false;
    }
  }
}

/// The relay client, or null when no Voice provider is set (so the wrench and
/// the break reaction stay hidden).
final museyApiProvider = Provider<MuseyApi?>((ref) {
  final voice = ref.watch(directVoiceProviderProvider);
  if (voice == null) return null;
  return DioMuseyApi(ref);
});
