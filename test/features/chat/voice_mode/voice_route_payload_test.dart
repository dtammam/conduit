import 'package:checks/checks.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_audio_session_coordinator.dart';
import 'package:conduit_core/voice/voice_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  VoiceRouteClass of(List<String> outputs, [List<String> inputs = const []]) =>
      ChatVoiceAudioSessionCoordinator.voiceRouteClassFromPayload({
        'currentOutputs': [
          for (final type in outputs) {'type': type, 'uid': 'x'},
        ],
        'currentInputs': [
          for (final type in inputs) {'type': type, 'uid': 'y'},
        ],
      });

  test('reads the route class from the iOS route payload', () {
    check(of(['Speaker'], ['MicrophoneBuiltIn']))
        .equals(VoiceRouteClass.builtInSpeaker);
    check(of(['BluetoothHFP'], ['BluetoothHFP']))
        .equals(VoiceRouteClass.bluetoothHFP);
    check(of(['CarAudio'], ['CarAudio'])).equals(VoiceRouteClass.carPlay);
    check(of(['BluetoothA2DPOutput'], ['MicrophoneBuiltIn']))
        .equals(VoiceRouteClass.bluetoothA2DP);
    check(ChatVoiceAudioSessionCoordinator.voiceRouteClassFromPayload(null))
        .equals(VoiceRouteClass.other);
  });
}
