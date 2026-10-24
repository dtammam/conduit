// StreamAudioSource is marked experimental by just_audio; it is the only way
// to hand the player audio held in memory.
// ignore_for_file: experimental_member_use

import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';
import 'package:just_audio/just_audio.dart';

/// The mobile app's [AudioPlaybackPort], backed by `just_audio`.
///
/// The gapless-queue behaviour the spoken reply depends on is `just_audio`'s.
/// [PieceQueuePlayback] on top of it turns a streamed MP3 clip into the small
/// files it is made of, so a sentence starts as soon as its first half second
/// has arrived (iOS's player would otherwise wait for the whole clip).
class JustAudioPlayback extends PieceQueuePlayback {
  JustAudioPlayback([AudioPlayer? player])
    : super(_JustAudioQueue(player ?? AudioPlayer()));
}

class _JustAudioQueue implements AudioSourceQueue {
  _JustAudioQueue(this._player);

  final AudioPlayer _player;

  @override
  Stream<AudioPlaybackState> get stateChanges => _player.playerStateStream.map(
    (state) => AudioPlaybackState(
      playing: state.playing,
      processingState: _mapProcessingState(state.processingState),
    ),
  );

  @override
  Stream<int?> get currentIndexChanges => _player.currentIndexStream;

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  AudioProcessingState get processingState =>
      _mapProcessingState(_player.processingState);

  @override
  bool get playing => _player.playing;

  @override
  Future<void> setSources(
    List<QueueSource> sources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) => _player.setAudioSources(
    sources.map(_toSource).toList(),
    initialIndex: initialIndex,
    initialPosition: initialPosition,
  );

  @override
  Future<void> insertSource(int index, QueueSource source) =>
      _player.insertAudioSource(index, _toSource(source));

  @override
  Future<void> clearSources() => _player.clearAudioSources();

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration? position, {int? index}) =>
      _player.seek(position, index: index);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> dispose() => _player.dispose();

  AudioSource _toSource(QueueSource source) {
    final bytes = source.bytes;
    if (bytes != null) {
      return _BytesAudioSource(bytes, source.mimeType!, tag: source.tag);
    }
    return AudioSource.uri(source.uri!, tag: source.tag);
  }

  static AudioProcessingState _mapProcessingState(ProcessingState state) =>
      switch (state) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
}

/// A whole clip in memory, served through `just_audio`'s local proxy with
/// its length and byte ranges, the way the platform players expect a file.
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this._bytes, this._mimeType, {super.tag});

  final Uint8List _bytes;
  final String _mimeType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, _bytes.length);
    final to = (end ?? _bytes.length).clamp(from, _bytes.length);
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(Uint8List.sublistView(_bytes, from, to)),
      contentType: _mimeType,
    );
  }
}
