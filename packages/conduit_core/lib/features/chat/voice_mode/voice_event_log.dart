import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit_core/utils/debug_logger.dart';

/// How many speech requests the server TTS prefetch runs at once in a read
/// that is not streamed (the manager's own constant, shared so call logs can
/// report it).
const int kTtsServerPrefetchParallelism = 3;

/// Sends one batch of events; true when the relay took it. Never throws into
/// the caller.
typedef VoiceEventSender = Future<bool> Function(Map<String, Object?> body);

/// Timing events of a voice call, buffered in memory and posted to the relay
/// every few seconds so a call can be measured on a release build.
///
/// Everything here is fire and forget: [add] returns at once, a post is never
/// awaited by the audio path, a failed post is retried once and then dropped.
/// Nothing is recorded outside a call ([start] to [stop]).
class VoiceEventLog {
  VoiceEventLog._();

  static final VoiceEventLog instance = VoiceEventLog._();

  /// Most events one post carries.
  static const int maxPerPost = 500;

  /// Most events held while posts are failing; the oldest go first.
  static const int maxBuffered = 2000;

  static const Duration flushInterval = Duration(seconds: 3);

  /// The running build ("1.2.3+45"), set by the app at startup.
  String build = '';

  VoiceEventSender? _sender;
  Timer? _timer;
  final List<Map<String, Object?>> _buffer = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _carried = <Map<String, Object?>>[];
  String? _turn;
  int _turnCounter = 0;
  String _device = '';

  /// Whether a call is being logged.
  bool get active => _sender != null;

  /// The id of the user turn in progress, if any.
  String? get currentTurn => _turn;

  /// Headers that tie a request to the turn in progress; empty outside a
  /// logged call.
  Map<String, String> get turnHeaders {
    final turn = _turn;
    if (!active || turn == null) return const <String, String>{};
    return <String, String>{'X-Voice-Turn': turn};
  }

  /// Starts logging a call and records its `call-start` with [info].
  void start({
    required VoiceEventSender sender,
    Map<String, Object?> info = const <String, Object?>{},
  }) {
    _timer?.cancel();
    _buffer.clear();
    _turn = null;
    _sender = sender;
    _device = _deviceName();
    _timer = Timer.periodic(flushInterval, (_) => flush());
    add('call-start', info);
    // Out at once, not with the next 3 s batch: the relay warms the persona's
    // voice on call-start, and every second it waits is a second of cold start.
    flush();
    // Engine failures that happened between calls, where nothing was logged.
    final carried = List<Map<String, Object?>>.of(_carried);
    _carried.clear();
    for (final fields in carried) {
      add('engine-failed', <String, Object?>{...fields, 'between-calls': true});
    }
  }

  /// Ends the call's log: the last events are posted, then logging stops.
  ///
  /// [reason] says why the call ended (overlay-end, callkit, a failure kind...)
  /// and [fields] carries what was true at that moment.
  void stop({String? reason, Map<String, Object?> fields = const {}}) {
    if (!active) return;
    add('call-end', <String, Object?>{
      'reason': ?reason,
      ...fields,
    });
    flush();
    _timer?.cancel();
    _timer = null;
    _sender = null;
    _turn = null;
  }

  /// Starts a new user turn and returns its id.
  String beginTurn() {
    final turn =
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '-${(++_turnCounter).toRadixString(36)}';
    _turn = turn;
    return turn;
  }

  /// Records an event now. [t] overrides the time (epoch ms).
  void add(String kind, [Map<String, Object?> fields = const {}, int? t]) {
    if (!active) {
      // A speech engine failure outside a call (hang-up, between calls) used
      // to vanish, and the next call then played whole clips with no trace of
      // why (+189 to +191). Keep it for the next call-start.
      if (kind == 'engine-failed') {
        _carried.add(Map<String, Object?>.of(fields));
        if (_carried.length > 5) _carried.removeAt(0);
      }
      return;
    }
    final event = <String, Object?>{
      't': t ?? DateTime.now().millisecondsSinceEpoch,
      'kind': kind,
      ...fields,
    };
    final turn = _turn;
    if (turn != null) event['turn'] = turn;
    _buffer.add(event);
    if (_buffer.length > maxBuffered) {
      _buffer.removeRange(0, _buffer.length - maxBuffered);
    }
  }

  /// Posts what is buffered, up to [maxPerPost] events a post, without
  /// waiting for the answer.
  void flush() {
    final sender = _sender;
    if (sender == null) return;
    while (_buffer.isNotEmpty) {
      final count = _buffer.length < maxPerPost ? _buffer.length : maxPerPost;
      final events = List<Map<String, Object?>>.of(_buffer.take(count));
      _buffer.removeRange(0, count);
      unawaited(_post(sender, events));
    }
  }

  Future<void> _post(
    VoiceEventSender sender,
    List<Map<String, Object?>> events,
  ) async {
    final body = <String, Object?>{
      'device': _device,
      'build': build,
      'events': events,
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (await sender(body)) return;
      } catch (_) {
        // Retried once below, then dropped.
      }
    }
    DebugLogger.warning(
      'voice-log-dropped',
      scope: 'chat/voice_mode',
      data: {'events': events.length},
    );
  }

  static String _deviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'unknown';
    }
  }
}
