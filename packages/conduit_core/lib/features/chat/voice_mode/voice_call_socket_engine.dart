/// A voice call over the relay's realtime socket (Contract B): the phone
/// streams the echo-cancelled microphone up all the time; the relay decides
/// when he is done, runs the turn, speaks it clause by clause and sends the
/// audio back as it is made. The relay is the only writer of the chat.
///
/// This is a [RealtimeCallEngine], so the call controller shows it in the
/// same snapshot a realtime call uses (phase, captions, mute, hang-up).
///
/// Barge-in is always on and has no setting (product decision, 2026-11-08): the relay
/// sends `duck` at about 90 ms of loud voice and `stop` at about 200 ms; the
/// phone turns down at once, stops within the same message, keeps what was
/// heard (the relay cuts the reply at the `played` position) and listens on.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/realtime_call/realtime_call_state.dart';
import 'package:conduit_core/features/chat/server_speech/viseme_timeline.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_history.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_client.dart'
    show VoiceHistoryEntry, newVoiceTurnId;
import 'package:conduit_core/features/chat/voice_mode/voice_event_log.dart';
import 'package:conduit_core/models/chat_message.dart';

/// How a socket call ended, for the controller's fallback.
enum VoiceSocketEnd {
  /// Still running.
  none,

  /// The user hung up (or the controller ended it).
  hangup,

  /// The connection dropped and did not come back: carry on with the direct
  /// or the old path.
  dropped,

  /// The relay routed a turn the Open WebUI way (a tool turn): the call
  /// carries on on the old path from this turn.
  owui,
}

/// The characters of a part he has heard when [posMs] of its audio played.
///
/// [audioMs] is the audio received so far; while the part is still arriving
/// ([complete] false) the total is not known, so a speaking rate of about 14
/// characters a second is the floor of the total: never more than the audio
/// really played, never ahead of it.
int playedChars({
  required int start,
  required int length,
  required int posMs,
  required int audioMs,
  required bool complete,
}) {
  if (length <= 0) return start;
  final total = complete ? audioMs : (audioMs > length * 70 ? audioMs : length * 70);
  if (total <= 0) return start;
  final fraction = (posMs / total).clamp(0.0, 1.0);
  return start + (length * fraction).round();
}

final class _Part {
  _Part(this.index, this.text, this.start, this.end);
  final int index;
  final String text;
  final int start;
  final int end;
  int bytes = 0;
  bool complete = false;
  int? carry;

  int get audioMs => bytes * 1000 ~/ (2 * voiceSocketOutRate);
}

final class _Turn {
  _Turn(this.id, this.userText, this.atIndex);
  final String id;
  final String userText;
  final int atIndex;
  final Map<int, _Part> parts = <int, _Part>{};
  bool done = false;
  bool interrupted = false;
  bool owui = false;
  bool audioStarted = false;

  /// The speaker played everything queued (reset by any new audio).
  bool drained = false;
  bool recorded = false;
  int lastPartSeen = -1;
  final Stopwatch clock = Stopwatch()..start();

  String get spoken {
    final keys = parts.keys.toList()..sort();
    return keys.map((k) => parts[k]!.text).join();
  }
}

final class VoiceSocketCallEngine implements RealtimeCallEngine {
  VoiceSocketCallEngine({
    required this.connector,
    required this.uri,
    required this.headers,
    required this.mic,
    required this.player,
    required this.chatId,
    required this.chatMessages,
    required this.history,
    VisemeStore? visemes,
    this.callId,
    this.personaId,
    this.build = '',
    this.tz = '',
    this.test = false,
    this.readyTimeout = const Duration(seconds: 5),
    this.reconnectDelays = const [
      Duration(milliseconds: 300),
      Duration(milliseconds: 800),
      Duration(milliseconds: 1500),
    ],
    this.playedEvery = const Duration(milliseconds: 200),
    this.unduckAfter = const Duration(milliseconds: 1200),
    this.duckGain = 0.2,
    this.localBargeMinRms = 900,
    this.localBargeMs = 200,
    this.owuiAckWait = const Duration(milliseconds: 150),
  }) : visemes = visemes ?? VisemeStore.instance;

  final VoiceSocketConnector connector;
  final Uri uri;
  final Map<String, String> headers;
  final VoiceCallMicPort mic;
  final VoiceCallPlayerPort player;
  final VisemeStore visemes;
  final String chatId;
  final List<ChatMessage> Function() chatMessages;
  final VoiceCallHistory history;
  String? callId;
  final String? personaId;
  final String build;
  final String tz;
  final bool test;

  final Duration readyTimeout;
  final List<Duration> reconnectDelays;
  final Duration playedEvery;
  final Duration unduckAfter;
  final double duckGain;
  final double localBargeMinRms;
  final int localBargeMs;

  /// How long a route owui waits for the ack that follows it before the
  /// socket closes.
  final Duration owuiAckWait;
  Timer? _owuiTimer;

  VoiceSocketEnd endKind = VoiceSocketEnd.none;

  /// With [endKind] owui: what he said in the turn the relay handed back.
  String? owuiText;

  /// With [endKind] owui: the relay's spoken ack for that turn, when it sent
  /// one right after the route (the app speaks it; no second request needed).
  String? owuiAck;

  /// Turns the call completed (done, or cut), for the controller's reread of
  /// the chat after the call.
  int get turnsRecorded => _recorded;
  int _recorded = 0;

  final _states = StreamController<RealtimeCallState>.broadcast();
  var _state = const RealtimeCallState();
  VoiceSocketChannel? _channel;
  StreamSubscription<Object>? _channelSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<VoicePlayerEvent>? _playerSub;
  StreamSubscription<Object>? _failureSub;
  Timer? _playedTimer;
  Timer? _unduckTimer;
  var _ended = false;
  var _muted = false;
  var _paused = false;
  var _bargeServer = true;
  var _connecting = false;
  var _ready = Completer<void>();
  _Turn? _turn;
  String? _audioTurn;
  int _localLoudMs = 0;
  var _micBuffer = BytesBuilder(copy: false);
  Future<void>? _ending;
  final _log = VoiceEventLog.instance;

  @override
  RealtimeCallState get state => _state;
  @override
  Stream<RealtimeCallState> get states => _states.stream;

  void _update(RealtimeCallState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  // ------------------------------------------------------------- connect

  var _opened = false;

  /// Opens the socket and says hello, without touching the microphone, so a
  /// refusal (503, 404) or a missing `ready` is known before the call's audio
  /// and system call UI start. Throws [VoiceSocketUnavailable].
  Future<void> preflight() async {
    if (_opened || _ended) return;
    callId ??= newVoiceTurnId();
    await _open();
    _opened = true;
  }

  @override
  Future<void> connect() async {
    if (_ended) return;
    await preflight();
    if (_ended) return;
    try {
      final stream = await mic.start();
      _micSub = stream.listen(_onMic, onError: (_) {});
    } catch (error) {
      await _closeChannel();
      throw VoiceSocketUnavailable('microphone: $error');
    }
    _playerSub = player.events.listen(_onPlayerEvent);
    _failureSub = player.failures.listen((error) {
      if (_ended) return;
      _log.add('socket-player-failed');
      endKind = VoiceSocketEnd.dropped;
      unawaited(end());
    });
    _update(
      _state.copyWith(
        phase: RealtimeCallPhase.live,
        muted: _muted,
        voice: 'relay',
      ),
    );
  }

  Future<void> _open() async {
    final sw = Stopwatch()..start();
    final VoiceSocketChannel channel;
    try {
      channel = await connector(uri, headers);
    } on VoiceSocketUnavailable {
      rethrow;
    } catch (error) {
      throw VoiceSocketUnavailable('connect failed: $error');
    }
    _channel = channel;
    _ready = Completer<void>();
    _channelSub = channel.messages.listen(
      (message) => _onMessage(channel, message),
      onError: (Object _) {},
      onDone: () => _onChannelClosed(channel),
    );
    final entries = history.build(chatMessages());
    channel.sendText(
      encodeSocketJson({
        'type': 'hello',
        'v': 1,
        'call_id': callId,
        'chat_id': chatId,
        'persona_id': ?personaId,
        'history': [for (final e in entries) e.toJson()],
        'in': {
          'fmt': 'pcm16',
          'rate': voiceSocketMicRate,
          'frame_ms': 20,
        },
        'out': 'pcm16',
        'build': build,
        'tz': tz,
        if (test) 'test': true,
      }),
    );
    try {
      await _ready.future.timeout(readyTimeout);
    } on TimeoutException {
      await _closeChannel();
      throw const VoiceSocketUnavailable('no ready from the relay');
    } on VoiceSocketUnavailable {
      await _closeChannel();
      rethrow;
    }
    _log.add('socket-ready', <String, Object?>{'ms': sw.elapsedMilliseconds});
  }

  Future<void> _closeChannel() async {
    final channel = _channel;
    _channel = null;
    await _channelSub?.cancel();
    _channelSub = null;
    if (channel != null) await channel.close();
  }

  // ------------------------------------------------------------- microphone

  void _onMic(Uint8List chunk) {
    if (_ended || _muted || _paused) return;
    final channel = _channel;
    if (channel == null || !_ready.isCompleted) return;
    _micBuffer.add(chunk);
    if (_micBuffer.length < voiceSocketFrameBytes) return;
    final all = _micBuffer.takeBytes();
    var offset = 0;
    while (all.length - offset >= voiceSocketFrameBytes) {
      final frame = Uint8List.sublistView(
        all,
        offset,
        offset + voiceSocketFrameBytes,
      );
      offset += voiceSocketFrameBytes;
      channel.sendBinary(micFrame(frame));
      if (!_bargeServer) _localBarge(frame);
    }
    if (offset < all.length) {
      _micBuffer = BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(all, offset));
    }
    final level = (_levelOf(chunk) / 8000).clamp(0.0, 1.0);
    if ((level - _state.inputLevel).abs() > 0.05) {
      _update(_state.copyWith(inputLevel: level));
    }
  }

  double _levelOf(Uint8List chunk) => pcm16Rms(chunk);

  /// Only when the relay says it does not judge barge-in itself.
  void _localBarge(Uint8List frame) {
    if (!_speaking) {
      _localLoudMs = 0;
      return;
    }
    if (pcm16Rms(frame) >= localBargeMinRms) {
      _localLoudMs += 20;
      if (_localLoudMs >= localBargeMs) {
        _localLoudMs = 0;
        _bargeNow('client');
      }
    } else {
      _localLoudMs = 0;
    }
  }

  // ------------------------------------------------------------- messages

  void _onMessage(VoiceSocketChannel channel, Object message) {
    if (_ended || !identical(channel, _channel)) return;
    if (message is String) {
      final json = parseSocketJson(message);
      if (json != null) _onJson(json);
    } else if (message is List<int>) {
      final audio = parseAudioFrame(message);
      if (audio != null) _onAudio(audio.part, audio.pcm);
    }
  }

  String? _s(Map<String, Object?> j, String k) {
    final v = j[k];
    return v is String ? v : null;
  }

  void _onJson(Map<String, Object?> j) {
    switch (j['type']) {
      case 'ready':
        _bargeServer = j['barge_server'] != false;
        if (j['out'] != null && j['out'] != 'pcm16') {
          if (!_ready.isCompleted) {
            _ready.completeError(
              VoiceSocketUnavailable('audio format ${j['out']}'),
            );
          }
          return;
        }
        if (!_ready.isCompleted) _ready.complete();
      case 'partial':
        final text = _s(j, 'text') ?? '';
        _update(_state.copyWith(userCaption: text, userSpeaking: true));
      case 'eot':
        _onEot(j);
      case 'meta':
        if (j['route'] == 'owui') _onOwuiRoute(j);
      case 'ack':
        final turn = _turn;
        if (turn != null && turn.owui && turn.id == _s(j, 'turn_id')) {
          final text = _s(j, 'text');
          if (text != null && text.trim().isNotEmpty) owuiAck = text.trim();
          _owuiTimer?.cancel();
          unawaited(end());
          return;
        }
        if (turn != null &&
            turn.id == _s(j, 'turn_id') &&
            turn.parts.isEmpty) {
          _update(_state.copyWith(assistantCaption: _s(j, 'text') ?? ''));
        }
      case 'part':
        _onPart(j);
      case 'visemes':
        _onVisemes(j);
      case 'duck':
        _onDuck(j);
      case 'stop':
        _onStop(j);
      case 'interrupted':
        _onInterrupted(j);
      case 'done':
        _onDone(j);
      case 'error':
        _onError(j);
    }
  }

  void _onEot(Map<String, Object?> j) {
    final id = _s(j, 'turn_id');
    if (id == null) return;
    final text = _s(j, 'text') ?? '';
    final old = _turn;
    if (old != null && !old.recorded && !old.done && !old.interrupted) {
      // The relay moved on without ending the old turn: it is over.
      _flushLocal();
    }
    _turn = _Turn(id, text, VoiceCallHistory.entriesOf(chatMessages()).length);
    _update(
      _state.copyWith(
        userCaption: text,
        userSpeaking: false,
        working: true,
        assistantCaption: '',
      ),
    );
    _log.add('socket-eot', <String, Object?>{
      'judge': j['judge'],
      'silenceMs': j['silence_ms'],
    });
  }

  void _onOwuiRoute(Map<String, Object?> j) {
    final turn = _turn;
    if (turn == null || turn.id != _s(j, 'turn_id') || turn.owui) return;
    turn.owui = true;
    _log.add('socket-owui-route');
    endKind = VoiceSocketEnd.owui;
    owuiText = turn.userText;
    // The turn goes the old way; this call ends and the controller carries on.
    // The relay's ack comes right behind the route, so wait a moment for it.
    _owuiTimer = Timer(owuiAckWait, () => unawaited(end()));
  }

  void _onPart(Map<String, Object?> j) {
    final turnId = _s(j, 'turn_id');
    final turn = _turn;
    if (turn == null || turn.id != turnId || turn.interrupted) return;
    final part = (j['part'] as num?)?.toInt();
    if (part == null) return;
    final text = _s(j, 'text') ?? '';
    final chars = j['chars'];
    var start = 0;
    var end = text.length;
    if (chars is List && chars.length == 2) {
      start = (chars[0] as num).toInt();
      end = (chars[1] as num).toInt();
    }
    if (_audioTurn != turnId) {
      _audioTurn = turnId;
      unawaited(player.reset());
    }
    turn.parts[part] = _Part(part, text, start, end);
    _update(_state.copyWith(assistantCaption: turn.spoken));
  }

  void _onAudio(int part, Uint8List pcm) {
    final turn = _turn;
    if (turn == null || _audioTurn != turn.id || turn.interrupted) return;
    final info = turn.parts[part];
    if (info == null) return;
    // earlier parts are whole once a later one starts
    if (part > turn.lastPartSeen) {
      for (final p in turn.parts.values) {
        if (p.index < part && !p.complete) _completePart(p);
      }
      turn.lastPartSeen = part;
    }
    var data = pcm;
    if (info.carry != null) {
      data = Uint8List(pcm.length + 1)
        ..[0] = info.carry!
        ..setRange(1, pcm.length + 1, pcm);
      info.carry = null;
    }
    if (data.length.isOdd) {
      info.carry = data[data.length - 1];
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    if (data.isEmpty) return;
    info.bytes += data.length;
    turn.drained = false;
    unawaited(player.appendPcm(part, data));
    if (!turn.audioStarted) {
      turn.audioStarted = true;
      _log.add('socket-first-audio', <String, Object?>{
        'sinceEotMs': turn.clock.elapsedMilliseconds,
      });
      unawaited(player.play());
      _startPlayed();
      _update(_state.copyWith(assistantSpeaking: true, working: false));
    }
  }

  void _completePart(_Part p) {
    if (p.complete) return;
    p.complete = true;
    unawaited(player.appendPcm(p.index, Uint8List(0), isLast: true));
  }

  void _onVisemes(Map<String, Object?> j) {
    final turn = _turn;
    if (turn == null || turn.id != _s(j, 'turn_id') || turn.interrupted) return;
    final part = (j['part'] as num?)?.toInt();
    if (part == null) return;
    final info = turn.parts[part];
    if (info != null) _completePart(info);
    final id = _s(j, 'viseme_id');
    if (id == null) return;
    final answer = parseVisemeAnswer(200, {
      'id': id,
      'duration': j['duration'],
      'timeline': j['timeline'],
    });
    if (answer is VisemeReady) {
      visemes.put(id, answer.timeline);
      player.bindViseme(part, id);
    }
  }

  void _onDuck(Map<String, Object?> j) {
    final turn = _turn;
    if (turn == null || turn.id != _s(j, 'turn_id') || !_speaking) return;
    unawaited(player.setGain(duckGain));
    _log.add('socket-duck');
    _unduckTimer?.cancel();
    _unduckTimer = Timer(unduckAfter, () {
      if (_ended || !_speaking) return;
      unawaited(player.setGain(1, ramp: const Duration(milliseconds: 150)));
      _log.add('socket-unduck');
    });
  }

  void _onStop(Map<String, Object?> j) {
    final turn = _turn;
    if (turn == null || turn.id != _s(j, 'turn_id')) return;
    final sw = Stopwatch()..start();
    _flushLocal();
    _log.add('socket-stop', <String, Object?>{'us': sw.elapsedMicroseconds});
  }

  void _onInterrupted(Map<String, Object?> j) {
    final turn = _turn;
    if (turn == null || turn.id != _s(j, 'turn_id')) return;
    _flushLocal();
    turn.interrupted = true;
    final kept = _s(j, 'kept') ?? '';
    if (!turn.recorded) {
      turn.recorded = true;
      _recorded++;
      history.record(
        atIndex: turn.atIndex,
        user: VoiceHistoryEntry(
          id: '${turn.id}:u',
          role: 'user',
          content: turn.userText,
        ),
        assistant: VoiceHistoryEntry(
          id: '${turn.id}:a',
          role: 'assistant',
          content: kept.isEmpty
              ? '<!--interrupted-->'
              : '$kept\n\n<!--interrupted-->',
        ),
        interrupted: true,
      );
    }
    _log.add('socket-interrupted', <String, Object?>{
      'source': j['source'],
      'keptChars': kept.length,
    });
    _update(
      _state.copyWith(
        assistantCaption: kept,
        assistantSpeaking: false,
        working: false,
      ),
    );
  }

  void _onDone(Map<String, Object?> j) {
    final turn = _turn;
    if (turn == null || turn.id != _s(j, 'turn_id') || turn.interrupted) return;
    for (final p in turn.parts.values) {
      _completePart(p);
    }
    turn.done = true;
    if (!turn.recorded) {
      turn.recorded = true;
      _recorded++;
      final content = _s(j, 'content') ?? turn.spoken;
      history.record(
        atIndex: turn.atIndex,
        user: VoiceHistoryEntry(
          id: _s(j, 'user_id') ?? '${turn.id}:u',
          role: 'user',
          content: turn.userText,
        ),
        assistant: VoiceHistoryEntry(
          id: _s(j, 'assistant_id') ?? '${turn.id}:a',
          role: 'assistant',
          content: content,
        ),
      );
    }
    _update(
      _state.copyWith(
        working: false,
        assistantSpeaking: turn.audioStarted && _state.assistantSpeaking,
      ),
    );
    if (!turn.audioStarted || turn.drained) {
      // nothing was spoken, or it all played before the relay said done
      _stopPlayed();
      if (_audioTurn == turn.id) _audioTurn = null;
      _update(_state.copyWith(assistantSpeaking: false));
    }
  }

  void _onError(Map<String, Object?> j) {
    final turn = _turn;
    final code = _s(j, 'code');
    if (turn != null && turn.owui && code == 'turn_ended') return;
    _log.add('socket-error', <String, Object?>{'code': code});
    if (turn != null && !turn.audioStarted) {
      _update(
        _state.copyWith(
          working: false,
          assistantCaption: _s(j, 'message') ?? 'That did not work.',
        ),
      );
    } else {
      _update(_state.copyWith(working: false));
    }
  }

  // ------------------------------------------------------------- playback

  bool get _speaking => _state.assistantSpeaking && _audioTurn != null;

  void _onPlayerEvent(VoicePlayerEvent event) {
    if (event is VoicePlayerDrained) {
      final turn = _turn;
      if (turn != null && _audioTurn == turn.id) turn.drained = true;
      if (turn != null && turn.done && _audioTurn == turn.id) {
        _stopPlayed();
        _audioTurn = null;
        _update(_state.copyWith(assistantSpeaking: false));
      }
    }
  }

  void _startPlayed() {
    _playedTimer?.cancel();
    _playedTimer = Timer.periodic(playedEvery, (_) => unawaited(_reportPlayed()));
  }

  void _stopPlayed() {
    _playedTimer?.cancel();
    _playedTimer = null;
  }

  /// The characters of the reply he has heard now, from the speaker's own
  /// position; null before anything plays.
  Future<({String turnId, int part, int chars, int ms})?> _heard() async {
    final turn = _turn;
    if (turn == null || _audioTurn != turn.id) return null;
    final pos = await player.position();
    if (pos == null) return null;
    final info = turn.parts[pos.part];
    if (info == null) return null;
    final chars = playedChars(
      start: info.start,
      length: info.end - info.start,
      posMs: pos.posMs,
      audioMs: info.audioMs,
      complete: info.complete,
    );
    return (turnId: turn.id, part: pos.part, chars: chars, ms: pos.posMs);
  }

  Future<void> _reportPlayed() async {
    final heard = await _heard();
    final channel = _channel;
    if (heard == null || channel == null || _ended) return;
    channel.sendText(
      encodeSocketJson({
        'type': 'played',
        'turn_id': heard.turnId,
        'part': heard.part,
        'chars': heard.chars,
        'ms': heard.ms,
      }),
    );
  }

  /// Stops local playback at once and forgets the queue. The relay is
  /// told separately (it sent the stop, or [_bargeNow] does).
  void _flushLocal() {
    _unduckTimer?.cancel();
    _stopPlayed();
    _audioTurn = null;
    unawaited(player.stop());
    _update(_state.copyWith(assistantSpeaking: false));
  }

  /// He cut in (the phone's own judgment or the controller): stop now, tell
  /// the relay how much he heard.
  Future<void> _bargeNow(String why) async {
    final turn = _turn;
    final channel = _channel;
    if (turn == null || channel == null || turn.interrupted) return;
    final heard = await _heard();
    if (heard == null && !_speaking) return;
    _flushLocal();
    channel.sendText(
      encodeSocketJson({
        'type': 'barge',
        'turn_id': turn.id,
        'chars_heard': heard?.chars ?? 0,
      }),
    );
    _log.add('socket-barge', <String, Object?>{'why': why});
  }

  // ------------------------------------------------------------- the call

  @override
  void setMuted(bool muted) {
    _muted = muted;
    if (muted) _micBuffer = BytesBuilder(copy: false);
    _update(_state.copyWith(muted: muted, inputLevel: 0));
  }

  @override
  void interrupt() {
    unawaited(_bargeNow('tap'));
  }

  @override
  void setPaused(bool paused) {
    if (_paused == paused) return;
    _paused = paused;
    if (paused) {
      unawaited(_bargeNow('pause'));
    } else {
      _micBuffer = BytesBuilder(copy: false);
    }
  }

  void _onChannelClosed(VoiceSocketChannel channel) {
    if (_ended || !identical(channel, _channel)) return;
    if (!_ready.isCompleted) {
      _ready.completeError(const VoiceSocketUnavailable('closed before ready'));
      return;
    }
    _channel = null;
    _log.add('socket-dropped');
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    if (_connecting || _ended) return;
    _connecting = true;
    _flushLocal();
    _turn = null;
    _update(
      _state.copyWith(
        phase: RealtimeCallPhase.connecting,
        working: false,
        userSpeaking: false,
      ),
    );
    try {
      for (final delay in reconnectDelays) {
        await Future<void>.delayed(delay);
        if (_ended) return;
        try {
          await _open();
          if (_ended) return;
          _log.add('socket-reconnected');
          _update(_state.copyWith(phase: RealtimeCallPhase.live));
          return;
        } on VoiceSocketUnavailable catch (error) {
          if (error.isRefusal) break;
        }
      }
      if (_ended) return;
      endKind = VoiceSocketEnd.dropped;
      _log.add('socket-lost');
      await end();
    } finally {
      _connecting = false;
    }
  }

  @override
  Future<void> end() => _ending ??= _end();

  Future<void> _end() async {
    if (endKind == VoiceSocketEnd.none) endKind = VoiceSocketEnd.hangup;
    _ended = true;
    _stopPlayed();
    _unduckTimer?.cancel();
    _owuiTimer?.cancel();
    final channel = _channel;
    if (channel != null) {
      channel.sendText(encodeSocketJson({'type': 'bye'}));
    }
    await _micSub?.cancel();
    _micSub = null;
    try {
      await mic.stop();
    } catch (_) {}
    try {
      await player.stop();
    } catch (_) {}
    await _playerSub?.cancel();
    _playerSub = null;
    await _failureSub?.cancel();
    _failureSub = null;
    try {
      await player.dispose();
    } catch (_) {}
    await _closeChannel();
    _update(_state.copyWith(phase: RealtimeCallPhase.ended, assistantSpeaking: false));
    await _states.close();
  }
}
