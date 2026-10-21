import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';

/// Owns the PCM bridge between the microphone and VAD for one session.
///
/// The bridge exists because VAD 0.0.8 still declares Record 6.x support, so
/// Conduit owns the Record 7 stream itself and passes only PCM bytes in. The
/// capture side is now [AudioCapturePort], which is what let this drop its
/// plugin import — the ordering below is the part that matters and is
/// unchanged: VAD subscribes before the recorder starts, so the beginning of
/// the microphone stream cannot be lost during setup.
class ServerVadRecorderSession {
  ServerVadRecorderSession(this._recorder);

  final AudioCapturePort _recorder;
  StreamController<Uint8List>? _audioController;
  StreamSubscription<Uint8List>? _recorderSubscription;
  bool _stopping = false;
  bool _recorderStarted = false;
  bool _forwarding = false;
  bool _holdingForResponse = false;
  bool _disposed = false;

  /// Hears the microphone while it is held for the assistant's turn, so the
  /// caller can tell when the user starts talking over the assistant (server
  /// barge-in). Null discards held audio unheard.
  void Function(Uint8List bytes)? onHeldAudio;

  /// How many bytes of the most recent held audio are kept, so a recording
  /// resumed on voice onset can start with the beginning of the speech.
  int heldAudioRetentionBytes = 0;

  final ListQueue<Uint8List> _heldTail = ListQueue<Uint8List>();
  int _heldTailBytes = 0;

  bool get isHoldingForResponse =>
      _holdingForResponse && _recorderStarted && !_disposed;

  Future<void> start({
    required AudioCaptureConfig config,
    required bool iosAudioSessionManagedExternally,
    required Future<void> Function(Stream<Uint8List> audioStream) connectVad,
    required void Function(Object error, StackTrace stackTrace) onRecorderError,
  }) async {
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Microphone permission not granted');
      }
      _throwIfStopping();
      if (iosAudioSessionManagedExternally) {
        await _recorder.manageIosAudioSession(false);
        _throwIfStopping();
      }

      final controller = StreamController<Uint8List>();
      _audioController = controller;
      _forwarding = true;

      // VAD initializes its model and subscribes before Record starts, so the
      // beginning of the microphone stream cannot be dropped during setup.
      await connectVad(controller.stream);
      _throwIfStopping();
      final recorderStream = await _recorder.startStream(config);
      _recorderStarted = true;
      _throwIfStopping();
      _recorderSubscription = recorderStream.listen(
        (bytes) {
          final activeController = _audioController;
          if (_forwarding &&
              activeController != null &&
              !activeController.isClosed) {
            activeController.add(bytes);
          } else if (_holdingForResponse) {
            _retainHeldAudio(bytes);
            onHeldAudio?.call(bytes);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _forwarding = false;
          _holdingForResponse = false;
          onRecorderError(error, stackTrace);
        },
        onDone: () {
          _forwarding = false;
          _holdingForResponse = false;
          if (!_stopping) {
            onRecorderError(
              StateError('Microphone stream ended unexpectedly'),
              StackTrace.current,
            );
          }
          unawaited(_closeAudioController());
        },
      );
    } catch (_) {
      await _cleanupAfterFailedStart();
      rethrow;
    }
  }

  Future<void> stopForwarding() async {
    _stopping = true;
    _forwarding = false;
    _holdingForResponse = false;
    final subscription = _recorderSubscription;
    _recorderSubscription = null;
    await subscription?.cancel();
  }

  Future<bool> holdForResponse() async {
    if (_disposed || _stopping || !_recorderStarted) return false;
    // Keep the call's real input I/O alive for iOS background execution, but
    // detach VAD and discard every buffer while the assistant owns the turn.
    _forwarding = false;
    _holdingForResponse = true;
    _clearHeldTail();
    await _closeAudioController();
    return isHoldingForResponse;
  }

  /// Hands the held microphone back to a fresh VAD. [lookbackBytes] of the
  /// most recent held audio (as far as [heldAudioRetentionBytes] kept it) go
  /// to the VAD first, so a take started on voice onset keeps its beginning.
  Future<bool> resumeForwarding({
    required Future<void> Function(Stream<Uint8List> audioStream) connectVad,
    int lookbackBytes = 0,
  }) async {
    if (!isHoldingForResponse || _stopping) return false;

    final controller = StreamController<Uint8List>();
    _audioController = controller;
    try {
      await connectVad(controller.stream);
      _throwIfStopping();
      if (!identical(_audioController, controller) || !isHoldingForResponse) {
        throw StateError('Response-wait recorder ownership changed');
      }
      final lookback = _takeHeldTail(lookbackBytes);
      if (lookback.isNotEmpty) controller.add(lookback);
      _holdingForResponse = false;
      _forwarding = true;
      return true;
    } catch (_) {
      if (identical(_audioController, controller)) {
        _audioController = null;
      }
      if (!controller.isClosed) {
        await controller.close();
      }
      rethrow;
    }
  }

  Future<void> stopRecorder() async {
    _holdingForResponse = false;
    _clearHeldTail();
    try {
      if (_recorderStarted) {
        _recorderStarted = false;
        await _recorder.stop();
      }
    } finally {
      await _closeAudioController();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopForwarding();
    try {
      await stopRecorder();
    } finally {
      await _recorder.dispose();
    }
  }

  Future<void> _cleanupAfterFailedStart() async {
    try {
      await stopForwarding();
    } catch (_) {}
    try {
      await stopRecorder();
    } catch (_) {}
    try {
      await dispose();
    } catch (_) {}
  }

  void _retainHeldAudio(Uint8List bytes) {
    final limit = heldAudioRetentionBytes;
    if (limit <= 0 || bytes.isEmpty) return;
    _heldTail.addLast(bytes);
    _heldTailBytes += bytes.length;
    while (_heldTail.length > 1 &&
        _heldTailBytes - _heldTail.first.length >= limit) {
      _heldTailBytes -= _heldTail.removeFirst().length;
    }
  }

  /// The last [count] held bytes (fewer when fewer were kept), trimmed to
  /// whole 16-bit samples, and forgets the rest.
  Uint8List _takeHeldTail(int count) {
    final available = math.min(math.max(count, 0), _heldTailBytes) & ~1;
    final out = Uint8List(available);
    var end = available;
    for (final chunk in _heldTail.toList().reversed) {
      if (end == 0) break;
      final take = math.min(end, chunk.length);
      out.setRange(end - take, end, chunk, chunk.length - take);
      end -= take;
    }
    _clearHeldTail();
    return out;
  }

  void _clearHeldTail() {
    _heldTail.clear();
    _heldTailBytes = 0;
  }

  void _throwIfStopping() {
    if (_stopping) {
      throw StateError('Server VAD recording was stopped during startup');
    }
  }

  Future<void> _closeAudioController() async {
    final controller = _audioController;
    _audioController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}
