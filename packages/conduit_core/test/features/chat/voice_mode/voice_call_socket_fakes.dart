import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';

/// A relay stand-in: a real WebSocket server on loopback that records what
/// the phone sends and lets a test play the relay's side.
class FakeRelay {
  FakeRelay._(this.server);
  final HttpServer server;
  int refuseWith = 0; // when set, the upgrade answers this status
  bool sayReady = true;
  final sockets = <WebSocket>[];
  final texts = <Map<String, Object?>>[];
  final micFrames = <Uint8List>[];
  final hellos = <Map<String, Object?>>[];
  int connections = 0;

  static Future<FakeRelay> start() async {
    final s = await HttpServer.bind('127.0.0.1', 0);
    final relay = FakeRelay._(s);
    s.listen((req) async {
      relay.connections++;
      if (relay.refuseWith != 0) {
        req.response.statusCode = relay.refuseWith;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      relay.sockets.add(ws);
      ws.listen((m) {
        if (m is String) {
          final j = jsonDecode(m) as Map<String, Object?>;
          if (j['type'] == 'hello') {
            relay.hellos.add(j);
            if (relay.sayReady) {
              ws.add(
                jsonEncode({
                  'type': 'ready',
                  'v': 1,
                  'out': 'pcm16',
                  'out_rate': 24000,
                  'barge_server': true,
                }),
              );
            }
          } else {
            relay.texts.add(j);
          }
        } else if (m is List<int>) {
          relay.micFrames.add(Uint8List.fromList(m));
        }
      });
    });
    return relay;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${server.port}/voice/call?v=1');
  WebSocket get ws => sockets.last;
  void json(Map<String, Object?> m) => ws.add(jsonEncode(m));
  void audio(int part, int bytes, {int fill = 1}) {
    final b = Uint8List(bytes + 3)
      ..[0] = 0x02
      ..[1] = part >> 8
      ..[2] = part & 0xff;
    for (var i = 3; i < b.length; i++) {
      b[i] = fill;
    }
    ws.add(b);
  }

  List<Map<String, Object?>> played() =>
      texts.where((t) => t['type'] == 'played').toList();
  Future<void> close() => server.close(force: true);
}

class FakeMic implements VoiceCallMicPort {
  final controller = StreamController<Uint8List>.broadcast();
  int starts = 0;
  int stops = 0;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return controller.stream;
  }

  @override
  Future<void> stop() async => stops++;
  void speak(int ms) =>
      controller.add(Uint8List(ms * 32)..fillRange(0, ms * 32, 3));
}

class FakePlayer implements VoiceCallPlayerPort {
  final ev = StreamController<VoicePlayerEvent>.broadcast();
  final fail = StreamController<Object>.broadcast();
  final log = <String>[];
  final clock = Stopwatch()..start();
  final times = <String, int>{};
  final bytes = <int, int>{};
  final lastFlags = <int, bool>{};
  final gains = <double>[];
  ({int part, int posMs})? pos;
  final viseme = <int, String?>{};

  void _note(String what) {
    log.add(what);
    times[what] = clock.elapsedMilliseconds;
  }

  @override
  Stream<VoicePlayerEvent> get events => ev.stream;
  @override
  Stream<Object> get failures => fail.stream;
  @override
  Future<void> dispose() async => _note('dispose');
  @override
  Future<void> reset() async => _note('reset');
  @override
  Future<void> appendPcm(int part, Uint8List pcm, {bool isLast = false}) async {
    bytes[part] = (bytes[part] ?? 0) + pcm.length;
    if (isLast) lastFlags[part] = true;
  }

  @override
  Future<void> play() async => _note('play');
  @override
  Future<void> stop() async => _note('stop');
  @override
  Future<void> setGain(double gain, {Duration ramp = Duration.zero}) async {
    gains.add(gain);
    _note('gain ${gain.toStringAsFixed(2)}');
  }

  @override
  Future<({int part, int posMs})?> position() async => pos;
  @override
  void bindViseme(int part, String? visemeId) => viseme[part] = visemeId;
}

Future<void> until(bool Function() ok, {int ms = 2000, String? what}) async {
  final sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsedMilliseconds > ms) {
      throw TimeoutException('waiting for ${what ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

