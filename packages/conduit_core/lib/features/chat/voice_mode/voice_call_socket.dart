/// The ports and the wire format of the realtime voice socket (Contract B of
/// the voice program): `GET ws://<mac>:1236/voice/call?v=1`, same key as
/// the other relay calls. See `~/srv/docs/VOICE-REALTIME.md` section 12.2 and
/// the relay's `lan-relay/voice/socket.js` (built as R3), which is what this
/// matches where the two differ.
///
/// Text frames are JSON. Binary frames start with one type byte:
/// up `0x01` + PCM16 mono 16 kHz (20 ms = 640 bytes), down `0x02` + u16
/// big-endian part + PCM16 mono 24 kHz.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int voiceSocketRelayPort = 1236;
const int voiceSocketMicRate = 16000;
const int voiceSocketOutRate = 24000;

/// 20 ms of 16 kHz PCM16.
const int voiceSocketFrameBytes = 640;
const int voiceSocketTypeMic = 0x01;
const int voiceSocketTypeAudio = 0x02;

/// The socket was refused (switch off: 503; route missing: 404; other 4xx),
/// could not be reached, or did not say `ready`. Before the call is live this
/// means "use the direct or old path".
final class VoiceSocketUnavailable implements Exception {
  const VoiceSocketUnavailable(this.reason, {this.status});
  final String reason;
  final int? status;

  /// 404 and 503 (and 501) mean the relay will not take socket calls now.
  bool get isRefusal => status == 404 || status == 503 || status == 501;
  @override
  String toString() => 'VoiceSocketUnavailable: $reason';
}

/// One open WebSocket. Messages are `String` (JSON) or `List<int>` (binary).
abstract interface class VoiceSocketChannel {
  Stream<Object> get messages;

  /// Completes when the socket is closed, from either side.
  Future<void> get done;

  void sendText(String text);
  void sendBinary(Uint8List bytes);
  Future<void> close();
}

typedef VoiceSocketConnector =
    Future<VoiceSocketChannel> Function(Uri uri, Map<String, String> headers);

/// Opens a socket with `dart:io` (no extra package). The upgrade is done by
/// hand so a refusal keeps its HTTP status (`WebSocket.connect` drops it): a
/// non-101 answer throws [VoiceSocketUnavailable] with that status.
Future<VoiceSocketChannel> ioVoiceSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 1);
  try {
    final http = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
    final request = await client.openUrl('GET', http);
    final rng = math.Random.secure();
    final key = base64.encode(List<int>.generate(16, (_) => rng.nextInt(256)));
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', key);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 6));
    if (response.statusCode != HttpStatus.switchingProtocols) {
      unawaited(response.drain<void>().catchError((Object _) {}));
      client.close(force: true);
      throw VoiceSocketUnavailable(
        'http ${response.statusCode}',
        status: response.statusCode,
      );
    }
    final socket = await response.detachSocket();
    final ws = WebSocket.fromUpgradedSocket(socket, serverSide: false);
    ws.pingInterval = const Duration(seconds: 10);
    return _IoChannel(ws);
  } on VoiceSocketUnavailable {
    rethrow;
  } on TimeoutException {
    client.close(force: true);
    throw const VoiceSocketUnavailable('connect timed out');
  } on SocketException catch (error) {
    client.close(force: true);
    throw VoiceSocketUnavailable('unreachable: ${error.message}');
  } on HandshakeException catch (error) {
    client.close(force: true);
    throw VoiceSocketUnavailable('tls: ${error.message}');
  } on HttpException catch (error) {
    client.close(force: true);
    throw VoiceSocketUnavailable('http: ${error.message}');
  }
}

final class _IoChannel implements VoiceSocketChannel {
  _IoChannel(this._socket) {
    _socket.done.then((_) => _done.complete(), onError: (_) => _done.complete());
  }
  final WebSocket _socket;
  final Completer<void> _done = Completer<void>();

  @override
  Stream<Object> get messages => _socket.cast<Object>();
  @override
  Future<void> get done => _done.future;
  @override
  void sendText(String text) {
    if (_socket.readyState == WebSocket.open) _socket.add(text);
  }

  @override
  void sendBinary(Uint8List bytes) {
    if (_socket.readyState == WebSocket.open) _socket.add(bytes);
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close(1000).timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
}

/// The microphone of a socket call: PCM16 mono 16 kHz, echo cancelled (the
/// speech engine's voice processing), in chunks of any size.
abstract interface class VoiceCallMicPort {
  Future<Stream<Uint8List>> start();
  Future<void> stop();
}

/// What the speaker reports.
sealed class VoicePlayerEvent {
  const VoicePlayerEvent();
}

/// Item (part) [part] began playing.
final class VoicePlayerStarted extends VoicePlayerEvent {
  const VoicePlayerStarted(this.part);
  final int part;
}

/// Everything queued has played and the queue is closed.
final class VoicePlayerDrained extends VoicePlayerEvent {
  const VoicePlayerDrained();
}

/// The speaker of a socket call: a gapless queue of PCM16 24 kHz parts.
abstract interface class VoiceCallPlayerPort {
  Stream<VoicePlayerEvent> get events;

  /// The speaker failed (the audio engine): the call cannot go on.
  Stream<Object> get failures;

  Future<void> dispose();

  /// Drops everything queued and restores full volume.
  Future<void> reset();

  /// Adds the next PCM16 bytes of [part]; [isLast] closes the part.
  Future<void> appendPcm(int part, Uint8List pcm, {bool isLast = false});

  Future<void> play();

  /// Stops at once and drops the queue.
  Future<void> stop();

  /// Sets the volume (0 to 1), over [ramp] (zero is at once).
  Future<void> setGain(double gain, {Duration ramp = Duration.zero});

  /// The part playing now and how many ms of it have played; null when none.
  Future<({int part, int posMs})?> position();

  /// Tells lip sync which viseme timeline belongs to [part].
  void bindViseme(int part, String? visemeId);
}

// ----------------------------------------------------------------- messages

Uint8List micFrame(Uint8List pcm) {
  final out = Uint8List(pcm.length + 1);
  out[0] = voiceSocketTypeMic;
  out.setRange(1, out.length, pcm);
  return out;
}

/// A binary frame from the relay: `0x02` + u16 part + PCM16. Null when it is
/// anything else.
({int part, Uint8List pcm})? parseAudioFrame(List<int> bytes) {
  if (bytes.length < 3 || bytes[0] != voiceSocketTypeAudio) return null;
  final part = (bytes[1] << 8) | bytes[2];
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return (part: part, pcm: Uint8List.sublistView(data, 3));
}

Map<String, Object?>? parseSocketJson(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  } on FormatException {
    return null;
  }
}

String encodeSocketJson(Map<String, Object?> message) => jsonEncode(message);

/// Root-mean-square level of PCM16 little-endian samples.
double pcm16Rms(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  if (n == 0) return 0;
  final view = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = view.getInt16(i * 2, Endian.little);
    sum += s * s;
  }
  return sum == 0 ? 0 : math.sqrt(sum / n);
}
