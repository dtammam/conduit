import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';
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
class HybridSpeechPlayback implements AudioPlaybackPort {
  HybridSpeechPlayback({AudioPlaybackPort? files, EngineSpeechPlayback? engine})
    : _files = files ?? JustAudioPlayback(),
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
      ..add(_engine.failures.listen((_) => unawaited(_fallBack())));
  }

  /// Moves the engine's queue to just_audio as whole clips, from the clip it
  /// was playing, and keeps playing if it was.
  Future<void> _fallBack() async {
    if (_engineDisabled) return;
    _engineDisabled = true;
    if (!identical(_active, _engine)) return;
    final resumeAt = _engine.currentIndex ?? 0;
    final clips = await Future.wait(_engineClips.map(wholeSpeechClip));
    _active = _files;
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
  final _subs = <StreamSubscription<Object?>>[];
  final _states = StreamController<AudioPlaybackState>.broadcast();
  final _indices = StreamController<int?>.broadcast();

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
    final next = onEngine && !_engineDisabled ? _engine : _files;
    if (!identical(next, _active)) {
      await _active.stop();
      _active = next;
    }
    if (identical(next, _engine)) {
      _engineClips
        ..clear()
        ..addAll(clips);
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
    if (_engineDisabled && clip.progressive != null) {
      return _files.addClip(await wholeSpeechClip(clip));
    }
    return _files.addClip(clip);
  }

  @override
  Future<void> clearClips() => _active.clearClips();
  @override
  Future<void> play() {
    _playing = true;
    return _active.play();
  }

  @override
  Future<void> pause() {
    _playing = false;
    return _active.pause();
  }

  @override
  Future<void> stop() {
    _playing = false;
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
  }
}

/// Plays clips on the native speech engine (`SpeechEngineQueue.swift`).
///
/// A streamed MP3 clip is cut into its pieces ([mp3Pieces]); the engine
/// decodes each, drops the encoder's lead-in and flush samples, and plays
/// them as one waveform, so the half-second joins are seamless. A whole clip
/// (a file, or a body that cannot be cut) plays as it is.
class EngineSpeechPlayback implements AudioPlaybackPort {
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

  void _fail(Object error) {
    if (_failed) return;
    _failed = true;
    if (!_failures.isClosed) _failures.add(error);
  }

  final _states = StreamController<AudioPlaybackState>.broadcast();
  final _indices = StreamController<int?>.broadcast();
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
    if (!_states.isClosed) {
      _states.add(
        AudioPlaybackState(playing: _playing, processingState: processing),
      );
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'event') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    switch (args['type']) {
      case 'failed':
        _fail(StateError('${args['message'] ?? 'speech engine failed'}'));
      case 'started':
        final item = args['item'];
        if (item is int && item != _currentIndex) {
          _currentIndex = item;
          if (!_indices.isClosed) _indices.add(item);
        }
        if (_processing != AudioProcessingState.ready) {
          _emit(AudioProcessingState.ready);
        }
      case 'starved':
        _emit(AudioProcessingState.buffering);
      case 'drained':
        _emit(AudioProcessingState.completed);
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
    await _call('reset');
  }

  /// Hands [clip] to the engine as the next item, piece by piece.
  void _feed(AudioClip clip) {
    final item = _count++;
    final generation = _generation;
    final progressive = clip.progressive;
    if (progressive != null && isMp3MimeType(progressive.mimeType)) {
      late final StreamSubscription<Uint8List> sub;
      void finish() {
        _feeds.remove(sub);
        if (generation == _generation) {
          unawaited(_call('finishItem', {'item': item}));
        }
      }

      sub = mp3Pieces(progressive).listen(
        (piece) {
          if (generation != _generation) return;
          unawaited(
            _call('appendPiece', {'item': item, 'bytes': piece, 'trim': true}),
          );
        },
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

  @override
  Future<void> play() async {
    _playing = true;
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
  return AudioClip(uri: file.uri, tag: clip.tag);
}
