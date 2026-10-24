import 'dart:async';

/// Encoded audio that is still arriving, readable from its first byte at any
/// time.
///
/// A speech server that streams sends the first bytes of a sentence long
/// before the last. The producer [add]s them as they come and [close]s when the
/// body ends; a player [read]s it from the start, receiving what has arrived
/// and then each new piece, so playback can begin before the clip is whole. A
/// second [read] (a replay or a seek) starts again from byte zero over what has
/// been kept.
final class ProgressiveAudio {
  ProgressiveAudio({required this.mimeType, void Function()? onCancel})
    : _onCancel = onCancel;

  /// A clip that is already whole.
  factory ProgressiveAudio.complete(List<int> bytes, String mimeType) =>
      ProgressiveAudio(mimeType: mimeType)
        ..add(bytes)
        ..close();

  final String mimeType;
  final void Function()? _onCancel;
  final List<List<int>> _pieces = <List<int>>[];
  final List<Completer<void>> _waiters = <Completer<void>>[];
  int _length = 0;
  bool _closed = false;
  bool _cancelled = false;
  Object? _error;

  /// Bytes received so far.
  int get length => _length;

  /// Whether the body has ended, normally or not.
  bool get isDone => _closed;

  /// Whether [cancel] ended it before the body did.
  bool get isCancelled => _cancelled;

  /// The error the body ended with, if any.
  Object? get error => _error;

  void add(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    _pieces.add(bytes);
    _length += bytes.length;
    _wake();
  }

  /// Ends the body. [error] marks it as cut short; readers see the bytes that
  /// did arrive and then end.
  void close([Object? error]) {
    if (_closed) return;
    _closed = true;
    _error = error;
    _wake();
  }

  /// Stops the producer and ends every reader at the bytes already kept.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
    close();
  }

  void _wake() {
    final waiting = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiting) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Every byte from the first, as it arrives, ending when the body does.
  Stream<List<int>> read() async* {
    var piece = 0;
    while (true) {
      while (piece < _pieces.length) {
        yield _pieces[piece++];
      }
      if (_closed) return;
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }
}
