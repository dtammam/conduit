library;

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';

/// What a host gives a call for the realtime socket: a microphone and a
/// speaker that cancel echo together, and how to open a WebSocket.
final class VoiceCallSocketKit {
  const VoiceCallSocketKit({
    required this.mic,
    required this.player,
    this.connector = ioVoiceSocketConnector,
  });

  final VoiceCallMicPort Function() mic;
  final VoiceCallPlayerPort Function() player;
  final VoiceSocketConnector connector;
}

/// The host's socket kit. Null (the default, and every host but iOS) keeps
/// calls on the direct and old paths. Tests override it with fakes.
final voiceCallSocketKitProvider = Provider<VoiceCallSocketKit?>((ref) => null);

/// `ws(s)://<voice host>:1236/voice/call?v=1` for the Voice provider
/// [profile]: the same host as the audio port, relay port 1236.
Uri voiceCallSocketUri(
  DirectConnectionProfile profile, {
  int port = voiceSocketRelayPort,
}) {
  final base = profile.requestBaseUri();
  return base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    port: port,
    path: '/voice/call',
    query: 'v=1',
    fragment: '',
  );
}
