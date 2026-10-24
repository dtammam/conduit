import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_playback_port.dart';
import 'mp3_pieces.dart';

/// One item in a host player's flat queue: a file or bytes in memory.
@immutable
class QueueSource {
  const QueueSource.uri(Uri this.uri, {this.tag})
    : bytes = null,
      mimeType = null;

  const QueueSource.bytes(
    Uint8List this.bytes,
    String this.mimeType, {
    this.tag,
  }) : uri = null;

  final Uri? uri;
  final Uint8List? bytes;
  final String? mimeType;
  final Object? tag;
}

/// The host player under [PieceQueuePlayback]: a plain gapless queue.
abstract interface class AudioSourceQueue {
  Stream<AudioPlaybackState> get stateChanges;
  Stream<int?> get currentIndexChanges;
  int? get currentIndex;
  AudioProcessingState get processingState;
  bool get playing;
  Future<void> setSources(
    List<QueueSource> sources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  });
  Future<void> insertSource(int index, QueueSource source);
  Future<void> clearSources();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration? position, {int? index});
  Future<void> setSpeed(double speed);
  Future<void> dispose();
}

/// An [AudioPlaybackPort] that plays streamed MP3 clips as they arrive.
///
/// iOS's player waits for the whole body of an audio stream of unknown
/// length before it starts (measured 2026-10-24: start = end of body plus
/// about one second, whatever the content type, ID3 tags or range answers).
/// A streaming speech server sends a clip as a run of small complete MP3
/// files ([mp3Pieces]), and each of those starts at once. So a clip with
/// progressive MP3 audio becomes several items in the host queue, inserted as
/// they arrive, while callers still see one item per clip: indices, seeks and
/// the end of the queue are translated.
///
/// While the clip being played is still arriving and the host reaches its
/// last piece, the host's "completed" is reported as buffering and playback
/// resumes on the next piece. A clip that is not MP3, or that cannot be cut,
/// plays once it is whole.
class PieceQueuePlayback implements AudioPlaybackPort {
  PieceQueuePlayback(this._host) {
    _hostStateSub = _host.stateChanges.listen(_onHostState);
    _hostIndexSub = _host.currentIndexChanges.listen(_onHostIndex);
  }

  final AudioSourceQueue _host;
  late final StreamSubscription<AudioPlaybackState> _hostStateSub;
  late final StreamSubscription<int?> _hostIndexSub;
  final _states = StreamController<AudioPlaybackState>.broadcast();
  final _indices = StreamController<int?>.broadcast();

  final List<_Entry> _entries = <_Entry>[];
  int _generation = 0;
  int? _lastIndex;
  AudioPlaybackState? _lastHostState;

  /// Set while the host finished the last piece of a clip still arriving.
  bool _stalled = false;

  /// Serialises queue changes so pieces land in order.
  Future<void> _serial = Future<void>.value();

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;

  @override
  Stream<int?> get currentIndexChanges => _indices.stream;

  @override
  int? get currentIndex => _entryOf(_host.currentIndex);

  @override
  AudioProcessingState get processingState {
    final state = _host.processingState;
    if (state == AudioProcessingState.completed && _tailStillArriving) {
      return AudioProcessingState.buffering;
    }
    return state;
  }

  bool get _tailStillArriving {
    for (var i = _entries.length - 1; i >= 0; i--) {
      final entry = _entries[i];
      if (entry.count > 0 || entry.arriving) return entry.arriving;
    }
    return false;
  }

  int _offset(int entry) {
    var sum = 0;
    for (var i = 0; i < entry; i++) {
      sum += _entries[i].count;
    }
    return sum;
  }

  int? _entryOf(int? flat) {
    if (flat == null) return null;
    var sum = 0;
    for (var i = 0; i < _entries.length; i++) {
      sum += _entries[i].count;
      if (flat < sum) return i;
    }
    return null;
  }

  void _onHostIndex(int? flat) {
    final index = _entryOf(flat);
    if (index == null || index == _lastIndex) return;
    _lastIndex = index;
    _indices.add(index);
  }

  void _onHostState(AudioPlaybackState state) {
    _lastHostState = state;
    if (state.processingState == AudioProcessingState.completed &&
        _tailStillArriving) {
      _stalled = true;
      _states.add(
        AudioPlaybackState(
          playing: true,
          processingState: AudioProcessingState.buffering,
        ),
      );
      return;
    }
    _states.add(state);
  }

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) {
    return _queue(() async {
      _reset();
      final generation = _generation;
      if (!clips.any((clip) => clip.progressive != null)) {
        _entries.addAll(clips.map((_) => _Entry(count: 1)));
        await _host.setSources(
          [for (final clip in clips) _whole(clip)],
          initialIndex: initialIndex,
          initialPosition: initialPosition,
        );
        return;
      }
      await _host.setSources(const []);
      for (final clip in clips) {
        if (generation != _generation) return;
        await _append(clip, generation);
      }
      if (generation != _generation) return;
      if (initialIndex > 0 || initialPosition > Duration.zero) {
        await _host.seek(initialPosition, index: _offset(initialIndex));
      }
    });
  }

  @override
  Future<void> addClip(AudioClip clip) {
    final generation = _generation;
    return _queue(() async {
      if (generation != _generation) return;
      await _append(clip, generation);
    });
  }

  @override
  Future<void> clearClips() => _queue(() async {
    _reset();
    await _host.clearSources();
  });

  /// Adds [clip] at the end; for a clip that arrives in pieces, returns once
  /// its first piece is queued (or it ended without one).
  Future<void> _append(AudioClip clip, int generation) async {
    final entry = _Entry(count: 0);
    _entries.add(entry);
    final index = _entries.length - 1;
    if (!_cuts(clip)) {
      final progressive = clip.progressive;
      final source = progressive == null
          ? _whole(clip)
          : QueueSource.bytes(
              await _readWhole(progressive.read()),
              progressive.mimeType,
              tag: clip.tag,
            );
      if (generation != _generation) return;
      await _host.insertSource(_offset(index), source);
      entry.count = 1;
      return;
    }
    // Pieces of an earlier clip that is still arriving go first.
    final before = [
      for (final earlier in _entries.take(index))
        if (earlier.arriving) earlier.done.future,
    ];
    if (before.isNotEmpty) await Future.wait(before);
    if (generation != _generation) return;

    final firstQueued = Completer<void>();
    final finished = _finisher(entry, firstQueued, generation);
    entry.arriving = true;
    entry.subscription = mp3Pieces(clip.progressive!).listen(
      (piece) {
        _serialPiece(() async {
          if (generation != _generation) return;
          final at = _offset(index) + entry.count;
          await _host.insertSource(
            at,
            QueueSource.bytes(piece, 'audio/mpeg', tag: clip.tag),
          );
          entry.count++;
          if (!firstQueued.isCompleted) firstQueued.complete();
          if (_stalled) {
            _stalled = false;
            await _host.seek(Duration.zero, index: at);
            await _host.play();
          }
        });
      },
      // A body cut short ends the clip at the pieces that arrived.
      onError: (Object _) => finished(),
      onDone: finished,
      cancelOnError: true,
    );
    await firstQueued.future;
  }

  void Function() _finisher(
    _Entry entry,
    Completer<void> firstQueued,
    int generation,
  ) {
    return () {
      _serialPiece(() async {
        entry.arriving = false;
        if (!entry.done.isCompleted) entry.done.complete();
        if (!firstQueued.isCompleted) firstQueued.complete();
        if (_stalled && generation == _generation && !_tailStillArriving) {
          // The host is past the last piece and nothing more is coming.
          _stalled = false;
          final last = _lastHostState;
          if (last != null) _states.add(last);
        }
      });
    };
  }

  /// Runs piece insertions in arrival order, outside [_serial] so that a
  /// queued [addClip] that waits for this clip cannot block it.
  Future<void> _pieceSerial = Future<void>.value();
  void _serialPiece(Future<void> Function() task) {
    _pieceSerial = _pieceSerial.then((_) => task()).catchError((Object _) {});
  }

  static bool _cuts(AudioClip clip) {
    final progressive = clip.progressive;
    return progressive != null && isMp3MimeType(progressive.mimeType);
  }

  static QueueSource _whole(AudioClip clip) =>
      QueueSource.uri(clip.uri, tag: clip.tag);

  static Future<Uint8List> _readWhole(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in stream) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  void _reset() {
    _generation++;
    for (final entry in _entries) {
      entry.subscription?.cancel();
      if (!entry.done.isCompleted) entry.done.complete();
    }
    _entries.clear();
    _stalled = false;
    _lastIndex = null;
  }

  Future<void> _queue(Future<void> Function() task) {
    final run = _serial.then((_) => task());
    _serial = run.catchError((Object _) {});
    return run;
  }

  @override
  Future<void> play() => _host.play();

  @override
  Future<void> pause() => _host.pause();

  @override
  Future<void> stop() async {
    _stalled = false;
    await _host.stop();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) => _host.seek(
    position,
    index: index == null ? null : _offset(index.clamp(0, _entries.length)),
  );

  @override
  Future<void> setSpeed(double speed) => _host.setSpeed(speed);

  @override
  Future<void> dispose() async {
    _reset();
    await _hostStateSub.cancel();
    await _hostIndexSub.cancel();
    await _host.dispose();
    await _states.close();
    await _indices.close();
  }
}

class _Entry {
  _Entry({required this.count});

  /// Items of this clip in the host queue.
  int count;

  /// Whether more pieces may still come.
  bool arriving = false;

  final Completer<void> done = Completer<void>();
  StreamSubscription<Uint8List>? subscription;
}
