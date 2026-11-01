import 'dart:async';
import 'dart:collection';

/// What the server said about one stored file, and (for an image small enough
/// to keep) the data URL the request carries for it.
class AttachmentFileEntry {
  AttachmentFileEntry({
    required this.fileName,
    required this.fileSize,
    required this.contentType,
    this.dataUrl,
  });

  /// As the server sent them, untouched, so a request built from the cache is
  /// the one built from the server.
  final dynamic fileName;
  final dynamic fileSize;
  final dynamic contentType;

  /// The image as a `data:` URL, or null when it was not fetched or is too big
  /// to keep.
  String? dataUrl;

  int get cost => 256 + (dataUrl?.length ?? 0);
}

/// Files of a chat's history, kept for the session so each turn does not
/// fetch them again: a least-recently-used cache holding at most [maxBytes],
/// never an image of more than [maxEntryBytes].
///
/// It follows one API client: given a different client (another server or
/// account), everything in it is dropped.
class AttachmentPayloadCache {
  AttachmentPayloadCache({
    this.maxBytes = 50 * 1024 * 1024,
    this.maxEntryBytes = 10 * 1024 * 1024,
  });

  final int maxBytes;
  final int maxEntryBytes;

  final LinkedHashMap<String, AttachmentFileEntry> _entries =
      LinkedHashMap<String, AttachmentFileEntry>();
  Object? _owner;
  int _bytes = 0;

  int get bytes => _bytes;
  int get length => _entries.length;
  bool contains(String id) => _entries.containsKey(id);

  /// Drops everything when [owner] is not the client the cache was filled by.
  void bind(Object owner) {
    if (identical(_owner, owner)) return;
    clear();
    _owner = owner;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
    _inflight.clear();
  }

  AttachmentFileEntry? get(String id) {
    final entry = _entries.remove(id);
    if (entry == null) return null;
    _entries[id] = entry;
    return entry;
  }

  void put(String id, AttachmentFileEntry entry) {
    _remove(id);
    if ((entry.dataUrl?.length ?? 0) > maxEntryBytes) entry.dataUrl = null;
    _entries[id] = entry;
    _bytes += entry.cost;
    _evict();
  }

  /// Keeps [dataUrl] with the cached [id], unless it is over the entry limit
  /// or the entry is gone.
  void putDataUrl(String id, String dataUrl) {
    final entry = _entries[id];
    if (entry == null || dataUrl.length > maxEntryBytes) return;
    _bytes -= entry.cost;
    entry.dataUrl = dataUrl;
    _bytes += entry.cost;
    get(id);
    _evict();
  }

  void _remove(String id) {
    final old = _entries.remove(id);
    if (old != null) _bytes -= old.cost;
  }

  void _evict() {
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      _remove(_entries.keys.first);
    }
  }

  // Requests under way, so the same file asked for twice at once is fetched
  // once.
  final Map<String, Future<Object?>> _inflight = <String, Future<Object?>>{};

  Future<T> shared<T>(String key, Future<T> Function() start) {
    final existing = _inflight[key];
    if (existing != null) return existing.then((value) => value as T);
    final future = start();
    _inflight[key] = future;
    void done() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    }

    future.then<void>((_) => done(), onError: (Object _) => done());
    return future;
  }
}

/// Runs at most [limit] jobs at once, the rest wait their turn in order.
class AsyncLimiter {
  AsyncLimiter(this.limit);

  final int limit;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}
