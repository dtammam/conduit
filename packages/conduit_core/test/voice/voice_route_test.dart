import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/transcription_confidence.dart';
import 'package:conduit_core/voice/barge_in_echo.dart';
import 'package:conduit_core/voice/voice_route.dart';
import 'package:test/test.dart';

void main() {
  group('classifyVoiceRoute', () {
    VoiceRouteClass of(List<String> outputs, [List<String> inputs = const []]) =>
        classifyVoiceRoute(outputPortTypes: outputs, inputPortTypes: inputs);

    test('names each iOS output', () {
      check(of(['Speaker'])).equals(VoiceRouteClass.builtInSpeaker);
      check(of(['Receiver'])).equals(VoiceRouteClass.builtInReceiver);
      check(of(['Headphones'])).equals(VoiceRouteClass.wiredHeadphones);
      check(of(['USBAudio'])).equals(VoiceRouteClass.wiredHeadphones);
      check(of(['BluetoothA2DPOutput'])).equals(VoiceRouteClass.bluetoothA2DP);
      check(of(['BluetoothHFP'])).equals(VoiceRouteClass.bluetoothHFP);
      check(of(['CarAudio'])).equals(VoiceRouteClass.carPlay);
      check(of(['AirPlay'])).equals(VoiceRouteClass.airPlay);
      check(of(['HDMI'])).equals(VoiceRouteClass.other);
      check(of([])).equals(VoiceRouteClass.other);
    });

    test('A2DP with the headset microphone is hands-free', () {
      check(
        of(['BluetoothA2DPOutput'], ['BluetoothHFP']),
      ).equals(VoiceRouteClass.bluetoothHFP);
    });
  });

  group('VoiceRouteProfile', () {
    test('open rooms are stricter than headphones', () {
      for (final open in [
        VoiceRouteClass.builtInSpeaker,
        VoiceRouteClass.bluetoothHFP,
        VoiceRouteClass.carPlay,
        VoiceRouteClass.airPlay,
        VoiceRouteClass.other,
      ]) {
        final p = VoiceRouteProfile.forClass(open);
        check(p.routeClass).equals(open);
        check(p.minWordsWithConfidence).equals(3);
        check(p.maxNoSpeechProb).equals(0.4);
        check(p.echoShare).equals(0.6);
        check(p.echoCancel).isTrue();
      }
      for (final contained in [
        VoiceRouteClass.builtInReceiver,
        VoiceRouteClass.wiredHeadphones,
        VoiceRouteClass.bluetoothA2DP,
      ]) {
        final p = VoiceRouteProfile.forClass(contained);
        check(p.minWordsWithConfidence).equals(2);
        check(p.maxNoSpeechProb).equals(0.5);
        check(p.echoCancel).isTrue();
      }
    });

    test('the route changes what a barge-in take needs', () {
      const sure = TranscriptionConfidence(avgLogprob: -0.2, noSpeechProb: 0);
      const take = 'next question';
      check(
        isBargeInEcho(
          take,
          '',
          confidence: sure,
          profile: VoiceRouteProfile.forClass(VoiceRouteClass.bluetoothA2DP),
        ),
      ).isFalse();
      check(
        isBargeInEcho(
          take,
          '',
          confidence: sure,
          profile: VoiceRouteProfile.forClass(VoiceRouteClass.carPlay),
        ),
      ).isTrue();
      // A borderline transcription passes in AirPods, not in the car.
      const borderline = TranscriptionConfidence(
        avgLogprob: -0.9,
        noSpeechProb: 0.45,
      );
      const longer = 'what about the weather tomorrow';
      check(
        isBargeInEcho(
          longer,
          '',
          confidence: borderline,
          profile: VoiceRouteProfile.forClass(VoiceRouteClass.bluetoothA2DP),
        ),
      ).isFalse();
      check(
        isBargeInEcho(
          longer,
          '',
          confidence: borderline,
          profile: VoiceRouteProfile.forClass(VoiceRouteClass.bluetoothHFP),
        ),
      ).isTrue();
    });
  });
}
