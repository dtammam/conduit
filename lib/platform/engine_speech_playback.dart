import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/chat/avatar/lip_sync.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_event_log.dart';
import 'package:flutter/services.dart';

import 'engine_voice_capture.dart';
import 'just_audio_playback.dart';

/// The iOS speech player: streamed clips on the native speech engine, all
/// else on `just_audio`.
///
/// A queue that starts with a streamed clip (Stream speech on) plays on
/// [EngineSpeechPlayback], one continuous waveform; any other queue, such as
/// a message read aloud as whole clips, stays on [JustAudioPlayback]. The
/// choice is made when a queue is set and holds until the next one.
class HybridSpeechPlayback
    implements AudioPlaybackPort, AudioItemEndReporting, AudioDucking {
  HybridSpeechPlayback({
    AudioPlaybackPort? files,
    EngineSpeechPlayback? engine,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _files = files ?? JustAudioPlayback(),
      _engine = engine ?? EngineSpeechPlayback() {
    _subs
      ..add(_files.stateChanges.listen((s) => _forward(_files, s, _states)))
      ..add(_engine.stateChanges.listen((s) => _forward(_engine, s, _states)))
      ..add(
        _files.currentIndexChanges.listen((i) => _forward(_files, i, _indices)),
      )
      ..add(
        _engine.currentIndexChanges.listen(
          (i) => _forward(_engine, i, _indices),
        ),
      )
      ..add(
        _engine.itemEnds.listen((i) {
          if (identical(_active, _engine) && !_ends.isClosed) _ends.add(i);
        }),
      )
      ..add(_engine.failures.listen((_) => unawaited(_fallBack())));
    final files = _files;
    if (files is AudioPositionReporting) {
      _subs.add(
        (files as AudioPositionReporting).positionStream.listen(
          _onFilePosition,
        ),
      );
    }
  }

  /// The viseme id of each clip queued on [_files], by index.
  final List<String?> _fileVisemes = <String?>[];

  /// Reports how far into the playing whole clip the audio is, so the avatar
  /// can follow the clip's viseme timeline (just_audio has no loudness tap).
  void _onFilePosition(Duration position) {
    if (!identical(_active, _files) || !_playing) return;
    final index = _files.currentIndex;
    final id = index != null && index >= 0 && index < _fileVisemes.length
        ? _fileVisemes[index]
        : null;
    if (id == null) {
      SpeechLevelMeter.instance.clearPosition();
      return;
    }
    SpeechLevelMeter.instance.pushPosition(
      id,
      position.inMilliseconds,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Moves the engine's queue to just_audio as whole clips, from the clip it
  /// was playing, and keeps playing if it was.
  Future<void> _fallBack() async {
    if (_engineDisabled) return;
    _engineDisabled = true;
    _engineFailedAt = _now();
    if (!identical(_active, _engine)) return;
    final resumeAt = _engine.currentIndex ?? 0;
    final clips = await Future.wait(_engineClips.map(wholeSpeechClip));
    _active = _files;
    _fileVisemes
      ..clear()
      ..addAll(
        clips.map((clip) => clip.visemeId ?? clip.progressive?.visemeId),
      );
    if (clips.isEmpty) return;
    await _files.setClips(
      clips,
      initialIndex: resumeAt.clamp(0, clips.length - 1),
    );
    if (_playing) await _files.play();
  }

  final AudioPlaybackPort _files;
  final EngineSpeechPlayback _engine;
  late AudioPlaybackPort _active = _files;

  /// The engine's queue, kept so a failure can hand it to just_audio.
  final List<AudioClip> _engineClips = <AudioClip>[];
  bool _playing = false;

  /// Set after the engine failed once; streamed speech then plays whole
  /// clips on just_audio for the rest of the run.
  bool _engineDisabled = false;

  final DateTime Function() _now;
  DateTime? _engineFailedAt;

  /// How long after a failure the engine is tried again. One failure used to
  /// switch it off until the app restarted: a failure at hang-up left every
  /// later call on whole clips, where a clip starts when its last byte lands
  /// (13.6 s on build 191, 2.6 s on build 189), with nothing in the log.
  static const Duration engineRetryAfter = Duration(seconds: 10);

  /// Whether [_engineDisabled] still holds; past [engineRetryAfter] the engine
  /// gets a fresh start. A second failure falls back again as before.
  bool _engineStillDisabled() {
    if (!_engineDisabled) return false;
    final at = _engineFailedAt;
    if (at == null || _now().difference(at) < engineRetryAfter) return true;
    _engineDisabled = false;
    _engine.rearm();
    VoiceEventLog.instance.add('engine-rearmed');
    return false;
  }
  final _subs = <StreamSubscription<Object?>>[];
  final _states = StreamController<AudioPlaybackState>.broadcast();
  final _indices = StreamController<int?>.broadcast();
  final _ends = StreamController<int>.broadcast();

  @override
  Stream<int> get itemEnds => _ends.stream;
  @override
  bool get endsAreNative => identical(_active, _engine);
  @override
  int? get lastStartGapMs => _engine.lastStartGapMs;

  void _forward<T>(AudioPlaybackPort from, T value, StreamController<T> into) {
    if (identical(from, _active) && !into.isClosed) into.add(value);
  }

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;
  @override
  Stream<int?> get currentIndexChanges => _indices.stream;
  @override
  int? get currentIndex => _active.currentIndex;
  @override
  AudioProcessingState get processingState => _active.processingState;

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    final streamed = clips.any((clip) => clip.progressive != null);
    // During a voice call whose microphone is on the engine, every clip plays
    // there: the echo canceller needs the assistant's voice as its reference.
    final onEngine = streamed || EngineVoiceCapture.voiceProcessingActive;
    final next = onEngine && !_engineStillDisabled() ? _engine : _files;
    if (!identical(next, _active)) {
      await _active.stop();
      _active = next;
    }
    if (identical(next, _engine)) {
      _engineClips
        ..clear()
        ..addAll(clips);
    }
    if (identical(next, _files)) {
      _fileVisemes
        ..clear()
        ..addAll(
          clips.map((clip) => clip.visemeId ?? clip.progressive?.visemeId),
        );
    }
    await _active.setClips(
      streamed && _engineDisabled
          ? await Future.wait(clips.map(wholeSpeechClip))
          : clips,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }

  @override
  Future<void> addClip(AudioClip clip) async {
    if (identical(_active, _engine)) {
      _engineClips.add(clip);
      return _engine.addClip(clip);
    }
    _fileVisemes.add(clip.visemeId ?? clip.progressive?.visemeId);
    if (_engineDisabled && clip.progressive != null) {
      return _files.addClip(await wholeSpeechClip(clip));
    }
    return _files.addClip(clip);
  }

  @override
  Future<void> clearClips() => _active.clearClips();

  @override
  Future<bool> setDuck(double gain, {Duration ramp = Duration.zero}) =>
      identical(_active, _engine)
      ? _engine.setDuck(gain, ramp: ramp)
      : Future<bool>.value(false);

  @override
  Future<void> play() {
    _playing = true;
    return _active.play();
  }

  @override
  Future<void> pause() {
    _playing = false;
    SpeechLevelMeter.instance.clearPosition();
    return _active.pause();
  }

  @override
  Future<void> stop() {
    _playing = false;
    SpeechLevelMeter.instance.clearPosition();
    return _active.stop();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) =>
      _active.seek(position, index: index);

  @override
  Future<void> setSpeed(double speed) async {
    await _files.setSpeed(speed);
    await _engine.setSpeed(speed);
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _files.dispose();
    await _engine.dispose();
    await _states.close();
    await _indices.close();
    await _ends.close();
  }
}

/// Plays clips on the native speech engine (`SpeechEngineQueue.swift`).
///
/// A streamed MP3 clip is cut into its pieces ([mp3Pieces]); the engine
/// decodes each, drops the encoder's lead-in and flush samples, and plays
/// them as one waveform, so the half-second joins are seamless. A whole clip
/// (a file, or a body that cannot be cut) plays as it is.
class EngineSpeechPlayback
    implements AudioPlaybackPort, AudioItemEndReporting, AudioDucking {
  EngineSpeechPlayback({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'app.cogwheel.conduit/speech_engine';

  final MethodChannel _channel;
  final _failures = StreamController<Object>.broadcast();

  /// Errors from the native engine: a failed call or a failure it reported.
  /// The engine stays unusable afterwards; [HybridSpeechPlayback] moves the
  /// queue to just_audio.
  Stream<Object> get failures => _failures.stream;
  bool _failed = false;
  bool get failed => _failed;

  /// Forgets a past failure so the next queue is tried on the engine again.
  void rearm() => _failed = false;

  void _fail(Object error) {
    if (_failed) return;
    _failed = true;
    // From here the run plays whole clips on just_audio (a clip then starts
    // when its last byte lands), so say why in the voice log.
    VoiceEventLog.instance.add('engine-failed', <String, Object?>{
      'error': error.toString().split('\n').first,
    });
    if (!_failures.isClosed) _failures.add(error);
  }

  final _states = StreamController<AudioPlaybackState>.broadcast();
  final _indices = StreamController<int?>.broadcast();
  final _ends = StreamController<int>.broadcast();
  int? _gapMs;
  final _feeds = <StreamSubscription<Uint8List>>[];

  /// Every call to the engine, in order: pieces must land in queue order.
  Future<void> _serial = Future<void>.value();
  int _count = 0;
  int _generation = 0;
  int? _currentIndex;
  bool _playing = false;
  AudioProcessingState _processing = AudioProcessingState.idle;

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;
  @override
  Stream<int?> get currentIndexChanges => _indices.stream;
  @override
  int? get currentIndex => _currentIndex;
  @override
  AudioProcessingState get processingState => _processing;
  @override
  Stream<int> get itemEnds => _ends.stream;
  @override
  bool get endsAreNative => true;
  @override
  int? get lastStartGapMs => _gapMs;

  Future<void> _call(String method, [Map<String, Object?>? args]) {
    if (_failed) return Future<void>.value();
    final run = _serial.then(
      (_) => _channel.invokeMethod<Object?>(method, args),
    );
    _serial = run.then((_) {}, onError: (Object _) {});
    // A failing engine never throws into the caller: it reports on [failures].
    return run.then((_) {}, onError: (Object error) => _fail(error));
  }

  void _emit(AudioProcessingState processing) {
    _processing = processing;
    if (!_playing ||
        processing == AudioProcessingState.completed ||
        processing == AudioProcessingState.idle) {
      SpeechLevelMeter.instance.clear();
    }
    if (!_states.isClosed) {
      _states.add(
        AudioPlaybackState(playing: _playing, processingState: processing),
      );
    }
  }

  int _lastOutLevelMs = 0;

  /// The viseme id of each queued item, by engine item index.
  final _itemVisemes = <int, String?>{};

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'event') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    switch (args['type']) {
      case 'failed':
        VoiceEventLog.instance.add('engine-failed', <String, Object?>{
          'message': '${args['message'] ?? ''}',
        });
        _fail(StateError('${args['message'] ?? 'speech engine failed'}'));
      case 'started':
        final item = args['item'];
        final gap = args['gapMs'];
        _gapMs = gap is int ? gap : null;
        if (item is int && item != _currentIndex) {
          _currentIndex = item;
          if (!_indices.isClosed) _indices.add(item);
        }
        if (_processing != AudioProcessingState.ready) {
          _emit(AudioProcessingState.ready);
        }
      case 'ended':
        final item = args['item'];
        if (item is int && !_ends.isClosed) _ends.add(item);
      case 'streamScheduled':
        VoiceEventLog.instance.add('stream-scheduled', <String, Object?>{
          'part': args['item'],
        });
      case 'starved':
        VoiceEventLog.instance.add('starved', <String, Object?>{
          'item': args['item'] ?? _currentIndex,
        });
        _emit(AudioProcessingState.buffering);
      case 'drained':
        _emit(AudioProcessingState.completed);
      case 'native':
        final name = args['name'];
        final fields = args['fields'];
        if (name == 'level') {
          // The loudness of the voice for the avatar's lip sync, about 20 a
          // second; not logged. Ignored unless the engine is playing.
          if (_playing &&
              _processing != AudioProcessingState.completed &&
              fields is Map) {
            final db = fields['rmsDb'];
            final hz = fields['zcrHz'];
            final item = fields['item'];
            final posMs = fields['posMs'];
            if (item is int && posMs is num) {
              // How far into the playing item the audio is (the engine's
              // own sample position), for lip sync from a viseme timeline.
              SpeechLevelMeter.instance.pushPosition(
                _itemVisemes[item],
                posMs.round(),
                DateTime.now().millisecondsSinceEpoch,
              );
            } else {
              SpeechLevelMeter.instance.clearPosition();
            }
            if (db is num) {
              SpeechLevelMeter.instance.push(
                db.toDouble(),
                hz is num ? hz.toDouble() : null,
                DateTime.now().millisecondsSinceEpoch,
              );
            }
          }
          return null;
        }
        if (name == 'out-level') {
          // At most about one a second, so a call's log cannot be flooded.
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastOutLevelMs < 900) return null;
          _lastOutLevelMs = now;
        }
        if (name is String) {
          VoiceEventLog.instance.add('native-$name', <String, Object?>{
            if (fields is Map)
              for (final e in fields.entries) '${e.key}': e.value,
          });
        }
    }
    return null;
  }

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    await _resetQueue();
    _emit(AudioProcessingState.loading);
    for (final clip in clips) {
      _feed(clip);
    }
    if (initialIndex > 0) await _call('seek', {'item': initialIndex});
  }

  @override
  Future<void> addClip(AudioClip clip) async => _feed(clip);

  @override
  Future<void> clearClips() => _resetQueue();

  Future<void> _resetQueue() async {
    _generation++;
    for (final feed in _feeds) {
      await feed.cancel();
    }
    _feeds.clear();
    _count = 0;
    _currentIndex = null;
    _itemVisemes.clear();
    await _call('reset');
  }

  /// Hands [clip] to the engine as the next item, piece by piece.
  void _feed(AudioClip clip) {
    final item = _count++;
    final generation = _generation;
    final progressive = clip.progressive;
    _itemVisemes[item] = clip.visemeId ?? progressive?.visemeId;
    if (progressive != null && isMp3MimeType(progressive.mimeType)) {
      final router = Mp3StreamRouter();
      var announced = false;
      late final StreamSubscription<Uint8List> sub;

      void dispatch(Mp3Route route) {
        if (generation != _generation) return;
        if (!announced) {
          announced = true;
          VoiceEventLog.instance.add('stream-bytes', <String, Object?>{
            'part': item,
            'path': route is Mp3ContinuousBytes ? 'continuous' : 'pieces',
            'bytes': route.bytes.length,
          });
        }
        unawaited(switch (route) {
          Mp3ContinuousBytes() => _call('appendStreamBytes', {
            'item': item,
            'bytes': route.bytes,
            'isLast': false,
          }),
          Mp3FilePiece() => _call('appendPiece', {
            'item': item,
            'bytes': route.bytes,
            'trim': true,
          }),
        });
      }

      void finish() {
        _feeds.remove(sub);
        if (generation != _generation) return;
        router.finish().forEach(dispatch);
        unawaited(
          router.continuous
              ? _call('appendStreamBytes', {
                  'item': item,
                  'bytes': Uint8List(0),
                  'isLast': true,
                })
              : _call('finishItem', {'item': item}),
        );
      }

      sub = progressive
          .read()
          .map(
            (bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          )
          .listen(
            (bytes) => router.add(bytes).forEach(dispatch),
            onError: (Object _) => finish(),
            onDone: finish,
            cancelOnError: true,
          );
      _feeds.add(sub);
      return;
    }
    unawaited(() async {
      Uint8List bytes;
      try {
        bytes = progressive != null
            ? await _readAll(progressive.read())
            : await File.fromUri(clip.uri).readAsBytes();
      } catch (_) {
        bytes = Uint8List(0);
      }
      if (generation != _generation) return;
      if (bytes.isNotEmpty) {
        await _call('appendPiece', {
          'item': item,
          'bytes': bytes,
          'trim': false,
        });
      }
      await _call('finishItem', {'item': item});
    }());
  }

  static Future<Uint8List> _readAll(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in stream) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  /// Ramps the engine's output gain without pausing it. A failed engine
  /// reports false (the caller pauses, which the failed engine ignores).
  @override
  Future<bool> setDuck(double gain, {Duration ramp = Duration.zero}) async {
    if (_failed) return false;
    final level = gain.clamp(0.0, 1.0);
    await _call('setGain', {'gain': level, 'rampMs': ramp.inMilliseconds});
    if (_failed) return false;
    VoiceEventLog.instance.add('barge-in-duck', <String, Object?>{
      'level': level,
      'rampMs': ramp.inMilliseconds,
      'item': _currentIndex,
    });
    return true;
  }

  @override
  Future<void> play() async {
    _playing = true;
    VoiceEventLog.instance.add('playback-resumed', <String, Object?>{
      'item': _currentIndex,
    });
    await _call('play');
    if (_processing == AudioProcessingState.idle ||
        _processing == AudioProcessingState.loading) {
      _emit(AudioProcessingState.buffering);
    } else {
      _emit(_processing);
    }
  }

  @override
  Future<void> pause() async {
    _playing = false;
    VoiceEventLog.instance.add('playback-paused', <String, Object?>{
      'item': _currentIndex,
    });
    await _call('pause');
    _emit(
      _processing == AudioProcessingState.completed
          ? _processing
          : AudioProcessingState.ready,
    );
  }

  @override
  Future<void> stop() async {
    _playing = false;
    await _call('stop');
    _emit(AudioProcessingState.idle);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    // The engine plays the next clip by itself once it is queued; a seek to
    // the clip already playing would only restart it.
    if (index == null || index == _currentIndex) return;
    _currentIndex = null;
    await _call('seek', {'item': index});
    _emit(AudioProcessingState.buffering);
  }

  @override
  Future<void> setSpeed(double speed) => _call('setRate', {'rate': speed});

  @override
  Future<void> dispose() async {
    await _resetQueue();
    await _call('dispose');
    await _states.close();
    await _indices.close();
    await _ends.close();
    await _failures.close();
  }
}

/// [clip] as a whole file, waiting for a streamed body to end; the clip
/// itself when it already is one.
Future<AudioClip> wholeSpeechClip(AudioClip clip) async {
  final progressive = clip.progressive;
  if (progressive == null) return clip;
  final builder = BytesBuilder(copy: false);
  await for (final bytes in progressive.read()) {
    builder.add(bytes);
  }
  final dir = await Directory.systemTemp.createTemp('conduit_speech_');
  final extension = isMp3MimeType(progressive.mimeType) ? 'mp3' : 'wav';
  final file = File('${dir.path}/clip.$extension');
  await file.writeAsBytes(builder.takeBytes(), flush: true);
  return AudioClip(uri: file.uri, tag: clip.tag, visemeId: clip.visemeId);
}
