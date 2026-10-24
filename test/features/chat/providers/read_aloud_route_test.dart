import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service extends TextToSpeechService {
  final calls = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async => true;

  @override
  Future<void> speak(String text) async => calls.add('speak');

  @override
  Future<void> stop() async {}
}

class _Voice extends ChatVoiceModeController {
  _Voice(this.phase);

  final ChatVoiceModePhase phase;

  @override
  ChatVoiceModeSnapshot build() => ChatVoiceModeSnapshot(phase: phase);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<String>> readAloud(ChatVoiceModePhase voicePhase) async {
    final service = _Service();
    final container = ProviderContainer(
      overrides: [
        textToSpeechServiceProvider.overrideWithValue(service),
        chatVoiceModeControllerProvider.overrideWith(() => _Voice(voicePhase)),
        readAloudAudioRouteProvider.overrideWithValue(
          () async => service.calls.add('route'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(textToSpeechControllerProvider.notifier)
        .toggleForMessage(messageId: 'm1', text: 'Goldfish live long.');
    return service.calls;
  }

  test('reading a message aloud sets the playback route first', () async {
    check(
      await readAloud(ChatVoiceModePhase.idle),
    ).deepEquals(['route', 'speak']);
  });

  test('during a voice call the call keeps its route', () async {
    check(
      await readAloud(ChatVoiceModePhase.speaking),
    ).deepEquals(['speak']);
  });
}
