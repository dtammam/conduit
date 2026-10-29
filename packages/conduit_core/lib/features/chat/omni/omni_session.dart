/// Sessions in the Omni chat: the chat shows every turn, but the model sees
/// only the current session.
///
/// Open WebUI rebuilds a saved chat's history from its database along the
/// parent chain of the message being answered, so the app cannot shorten it
/// by sending fewer messages. Instead every Omni request carries one system
/// line, [omniSessionMarker], that says how many of the person's messages
/// belong to the current session. The server that relays to the model strips
/// that line and keeps the history from that message on. Without such a
/// server the line reaches the model as a harmless system note.
///
/// A session starts with a message sent more than
/// [AppSettings.omniSessionIdleMinutes] after the one before it (by the
/// messages' own timestamps, so it is the same whether the app stayed open,
/// was in the background or was killed), or with the first message after a
/// manual fresh start. The ids of the messages that started sessions are stored per
/// account; the transcript draws a divider above each of them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart' show ListEquality;
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// The system line that tells the relay how many of the person's messages
/// the current session holds, the one being sent included.
String omniSessionMarker(int turns) => '[omni-session turns=$turns]';

/// Session starts kept per chat; older ones lose their divider only.
const int _maxStoredBoundaries = 500;

/// The Omni chat's session state.
@immutable
class OmniSessionState {
  const OmniSessionState({
    this.chatId,
    this.boundaries = const <String>[],
    this.pending = false,
  });

  /// The chat [boundaries] belong to.
  final String? chatId;

  /// Ids of the messages that started a session, oldest first.
  final List<String> boundaries;

  /// Whether the next message starts a session (a fresh start).
  final bool pending;

  /// This state for chat [id]: the boundaries of another chat do not apply.
  OmniSessionState forChat(String id) =>
      chatId == id ? this : OmniSessionState(chatId: id, pending: pending);

  OmniSessionState copyWith({List<String>? boundaries, bool? pending}) =>
      OmniSessionState(
        chatId: chatId,
        boundaries: boundaries ?? this.boundaries,
        pending: pending ?? this.pending,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chatId': ?chatId,
    'boundaries': boundaries,
    'pending': pending,
  };

  static OmniSessionState fromJson(Object? json) {
    if (json is! Map) return const OmniSessionState();
    final chatId = json['chatId'];
    final rawBoundaries = json['boundaries'];
    return OmniSessionState(
      chatId: chatId is String && chatId.isNotEmpty ? chatId : null,
      boundaries: rawBoundaries is List
          ? [
              for (final id in rawBoundaries)
                if (id is String && id.isNotEmpty) id,
            ]
          : const <String>[],
      pending: json['pending'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OmniSessionState &&
      other.chatId == chatId &&
      other.pending == pending &&
      const ListEquality<String>().equals(other.boundaries, boundaries);

  @override
  int get hashCode => Object.hash(chatId, pending, Object.hashAll(boundaries));
}

/// What an outgoing Omni turn sends, and the session state after it.
@immutable
class OmniSessionTurn {
  const OmniSessionTurn({required this.state, required this.turns});

  final OmniSessionState state;

  /// The person's messages in the session the turn belongs to, or null when
  /// no session start is known for it (then no marker is sent and the model
  /// sees the whole chat, as before).
  final int? turns;
}

/// Plans the request for the latest user message in [messages] of the Omni
/// chat [chatId].
///
/// With [mayStartSession] (a new message, not a regeneration) that message
/// starts a session when one is pending, when none was ever started, or when
/// the message before it is more than [idleGap] older.
OmniSessionTurn planOmniSessionTurn({
  required OmniSessionState state,
  required String chatId,
  required List<ChatMessage> messages,
  required Duration idleGap,
  required bool mayStartSession,
}) {
  var next = state.forChat(chatId);
  final userIndex = messages.lastIndexWhere((m) => m.role == 'user');
  if (userIndex < 0) return OmniSessionTurn(state: next, turns: null);
  final user = messages[userIndex];

  if (mayStartSession && !next.boundaries.contains(user.id)) {
    final previous = _idleReference(messages, userIndex);
    final idle =
        previous != null &&
        user.timestamp.difference(previous.timestamp) > idleGap;
    if (next.pending || next.boundaries.isEmpty || idle) {
      final boundaries = [...next.boundaries, user.id];
      next = next.copyWith(
        boundaries: boundaries.length > _maxStoredBoundaries
            ? boundaries.sublist(boundaries.length - _maxStoredBoundaries)
            : boundaries,
        pending: false,
      );
    }
  }

  final starts = next.boundaries.toSet();
  var start = -1;
  for (var i = userIndex; i >= 0; i--) {
    if (starts.contains(messages[i].id)) {
      start = i;
      break;
    }
  }
  if (start < 0) return OmniSessionTurn(state: next, turns: null);
  var turns = 0;
  for (var i = start; i <= userIndex; i++) {
    if (messages[i].role == 'user') turns++;
  }
  return OmniSessionTurn(state: next, turns: turns);
}

/// The message the idle gap before the user message at [userIndex] is
/// measured from: the one before it, except that assistant messages nobody
/// asked for (a routine's reply the server posted, which follows another
/// assistant message instead of a user message) are passed over. Otherwise a
/// reply to a post that arrived minutes ago would count as a continuation of
/// a conversation that had been quiet for hours.
ChatMessage? _idleReference(List<ChatMessage> messages, int userIndex) {
  var i = userIndex - 1;
  while (i >= 0 &&
      messages[i].role == 'assistant' &&
      (i == 0 || messages[i - 1].role != 'user')) {
    i--;
  }
  return i >= 0 ? messages[i] : null;
}

/// [requestMessages] with the marker for [turns]: appended on a new line to
/// the first system message (Open WebUI keeps only the first one), or as a
/// system message of its own when there is none.
List<Map<String, dynamic>> withOmniSessionMarker(
  List<Map<String, dynamic>> requestMessages,
  int turns,
) => withSystemMarker(requestMessages, omniSessionMarker(turns));

/// [requestMessages] with [marker] on its own line at the end of the first
/// system message, or as a system message of its own when there is none.
List<Map<String, dynamic>> withSystemMarker(
  List<Map<String, dynamic>> requestMessages,
  String marker,
) {
  final out = [
    for (final message in requestMessages) Map<String, dynamic>.from(message),
  ];
  final index = out.indexWhere(
    (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
  );
  if (index < 0) {
    return [
      <String, dynamic>{'role': 'system', 'content': marker},
      ...out,
    ];
  }
  final content = out[index]['content'];
  if (content is List) {
    out[index]['content'] = [
      ...content,
      <String, dynamic>{'type': 'text', 'text': '\n$marker'},
    ];
  } else {
    final text = content?.toString() ?? '';
    out[index]['content'] = text.isEmpty ? marker : '$text\n$marker';
  }
  return out;
}

/// The Omni chat's session state for the active account.
final omniSessionProvider =
    NotifierProvider<OmniSessionNotifier, OmniSessionState>(
      OmniSessionNotifier.new,
    );

class OmniSessionNotifier extends Notifier<OmniSessionState> {
  @override
  OmniSessionState build() {
    ref.watch(settledActiveAccountIdProvider);
    if (!PreferencesStore.isReady) return const OmniSessionState();
    final raw = PreferencesStore.getString(
      scopedPreferenceReadKey(PreferenceKeys.omniSession),
    );
    if (raw == null || raw.isEmpty) return const OmniSessionState();
    try {
      return OmniSessionState.fromJson(jsonDecode(raw));
    } on FormatException {
      return const OmniSessionState();
    }
  }

  /// The next Omni message starts a session.
  Future<void> startFresh() => _save(state.copyWith(pending: true));

  /// Plans the request for the latest user message of [messages] and keeps
  /// the session start it may have made. See [planOmniSessionTurn].
  int? planTurn({
    required String chatId,
    required List<ChatMessage> messages,
    required Duration idleGap,
    required bool mayStartSession,
  }) {
    final turn = planOmniSessionTurn(
      state: state,
      chatId: chatId,
      messages: messages,
      idleGap: idleGap,
      mayStartSession: mayStartSession,
    );
    if (turn.state != state) {
      // The request goes out now; storing the boundary may finish later.
      unawaited(_save(turn.state));
    }
    return turn.turns;
  }

  Future<void> _save(OmniSessionState next) async {
    state = next;
    if (!PreferencesStore.isReady) return;
    await PreferencesStore.put(
      scopedPreferenceWriteKey(PreferenceKeys.omniSession),
      jsonEncode(next.toJson()),
    );
  }
}
