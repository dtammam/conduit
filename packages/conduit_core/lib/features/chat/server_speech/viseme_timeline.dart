import 'dart:collection';

import 'package:meta/meta.dart';

/// One change of mouth in a viseme timeline: from [atMs] on the mouth is
/// [shape] (a server shape name) until the next entry.
@immutable
class VisemeKey {
  const VisemeKey(this.atMs, this.shape);

  final int atMs;
  final String shape;
}

/// The mouth shapes of one spoken clip, built by the speech relay from the
/// words (`GET /v1/audio/visemes/<id>`, see `lan-relay/README.md`).
///
/// Times count from the first sample of the audio the server sent. A shape
/// holds until the next entry.
@immutable
class VisemeTimeline {
  const VisemeTimeline({
    required this.id,
    required this.durationMs,
    required this.keys,
  });

  final String id;
  final int durationMs;
  final List<VisemeKey> keys;

  /// The server shape name at [posMs] into the clip: the last entry at or
  /// before it. Null before the first entry (or negative), and the last
  /// entry's shape after the end.
  String? shapeAt(int posMs) {
    if (keys.isEmpty || posMs < keys.first.atMs) return null;
    var low = 0;
    var high = keys.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (keys[mid].atMs <= posMs) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return keys[low].shape;
  }
}

/// What the viseme endpoint said.
sealed class VisemeAnswer {
  const VisemeAnswer();
}

/// 200: the timeline is ready.
final class VisemeReady extends VisemeAnswer {
  const VisemeReady(this.timeline);
  final VisemeTimeline timeline;
}

/// 202: still being built; ask again or give [wait] a longer time.
final class VisemePending extends VisemeAnswer {
  const VisemePending();
}

/// 404 (unknown or expired id, failed build, switch off), or any answer
/// that cannot be read: keep loudness mode.
final class VisemeUnavailable extends VisemeAnswer {
  const VisemeUnavailable();
}

/// Reads one answer of `GET /v1/audio/visemes/<id>`: [status] and the decoded
/// JSON [body]. 200 with a readable timeline is ready, 202 is pending,
/// everything else is unavailable.
VisemeAnswer parseVisemeAnswer(int? status, Object? body) {
  if (status == 202) return const VisemePending();
  if (status != 200 || body is! Map) return const VisemeUnavailable();
  final raw = body['timeline'];
  if (raw is! List) return const VisemeUnavailable();
  final keys = <VisemeKey>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final t = entry['t'];
    final shape = entry['shape'];
    if (t is! num || shape is! String || t.isNaN || t < 0) continue;
    keys.add(VisemeKey((t * 1000).round(), shape));
  }
  if (keys.isEmpty) return const VisemeUnavailable();
  keys.sort((a, b) => a.atMs.compareTo(b.atMs));
  final duration = body['duration'];
  final id = body['id'];
  return VisemeReady(
    VisemeTimeline(
      id: id is String ? id : '',
      durationMs: duration is num ? (duration * 1000).round() : keys.last.atMs,
      keys: List<VisemeKey>.unmodifiable(keys),
    ),
  );
}

/// The timelines fetched so far, by viseme id, for the avatar's lip sync to
/// look up while a clip plays. Keeps the last [capacity]; the relay keeps its
/// own for only 3 minutes. Listeners hear when one arrives, so a mouth can
/// switch from loudness to the timeline in the middle of a clip.
class VisemeStore {
  VisemeStore({this.capacity = 48});

  static final VisemeStore instance = VisemeStore();

  final int capacity;
  final List<void Function()> _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  final LinkedHashMap<String, VisemeTimeline> _byId =
      LinkedHashMap<String, VisemeTimeline>();

  VisemeTimeline? operator [](String? id) => id == null ? null : _byId[id];

  void put(String id, VisemeTimeline timeline) {
    _byId.remove(id);
    _byId[id] = timeline;
    while (_byId.length > capacity) {
      _byId.remove(_byId.keys.first);
    }
    _notify();
  }

  void clear() {
    if (_byId.isEmpty) return;
    _byId.clear();
    _notify();
  }
}

/// Remembers which viseme id came with which audio bytes, so the id travels
/// with a whole clip without changing its record type.
final class SpeechVisemes {
  SpeechVisemes._();

  static final Expando<String> _ids = Expando<String>('visemeId');

  static void tag(Object bytes, String? id) {
    if (id != null && id.isNotEmpty) _ids[bytes] = id;
  }

  static String? idOf(Object bytes) => _ids[bytes];
}
