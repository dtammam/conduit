/// Where a voice call's audio is going, and how barge-in behaves there.
///
/// How much of the assistant's own voice reaches the microphone depends on
/// the route: a phone on the loudspeaker or a car's hands-free system plays
/// it into the room the microphone is in, AirPods and wired headphones keep
/// it at the ear. Each route class gets a [VoiceRouteProfile] with the
/// barge-in thresholds that suit it.
library;

/// The kind of output a voice call plays through.
enum VoiceRouteClass {
  builtInSpeaker,
  builtInReceiver,
  wiredHeadphones,
  bluetoothA2DP,
  bluetoothHFP,
  carPlay,
  airPlay,
  other,
}

/// Classifies a route from iOS's port types (`AVAudioSession.Port` raw
/// values, such as "Speaker", "BluetoothHFP" or "CarAudio") of its outputs,
/// with its inputs as a hint for Bluetooth.
VoiceRouteClass classifyVoiceRoute({
  required List<String> outputPortTypes,
  List<String> inputPortTypes = const [],
}) {
  final outputs = outputPortTypes.toSet();
  if (outputs.contains('CarAudio')) return VoiceRouteClass.carPlay;
  if (outputs.contains('BluetoothHFP')) return VoiceRouteClass.bluetoothHFP;
  if (outputs.contains('BluetoothA2DPOutput') ||
      outputs.contains('BluetoothLE')) {
    // A2DP plays music-style; with the headset's microphone in use the call
    // is really hands-free.
    return inputPortTypes.contains('BluetoothHFP')
        ? VoiceRouteClass.bluetoothHFP
        : VoiceRouteClass.bluetoothA2DP;
  }
  if (outputs.contains('AirPlay')) return VoiceRouteClass.airPlay;
  if (outputs.contains('Headphones') ||
      outputs.contains('USBAudio') ||
      outputs.contains('LineOut')) {
    return VoiceRouteClass.wiredHeadphones;
  }
  if (outputs.contains('Speaker')) return VoiceRouteClass.builtInSpeaker;
  if (outputs.contains('Receiver')) return VoiceRouteClass.builtInReceiver;
  return VoiceRouteClass.other;
}

/// How a voice call behaves on one route class.
class VoiceRouteProfile {
  const VoiceRouteProfile({
    required this.routeClass,
    this.bargeInAllowed = true,
    this.echoCancel = true,
    required this.minWords,
    required this.minWordsWithConfidence,
    required this.maxNoSpeechProb,
    required this.minAvgLogprob,
    required this.echoShare,
  });

  final VoiceRouteClass routeClass;

  /// Whether barge-in may interrupt the assistant on this route.
  final bool bargeInAllowed;

  /// Whether the capture runs through the platform's echo canceller.
  final bool echoCancel;

  /// Words a barge-in take needs, without and with recognizer confidence.
  final int minWords;
  final int minWordsWithConfidence;

  /// Whisper confidence a barge-in take must meet.
  final double maxNoSpeechProb;
  final double minAvgLogprob;

  /// Share of a take's words that, when they are the assistant's, make it
  /// echo; lower is stricter.
  final double echoShare;

  /// Earpiece, AirPods and wired headphones: little of the assistant reaches
  /// the microphone.
  static const VoiceRouteProfile _contained = VoiceRouteProfile(
    routeClass: VoiceRouteClass.other,
    minWords: 3,
    minWordsWithConfidence: 2,
    maxNoSpeechProb: 0.5,
    minAvgLogprob: -1.0,
    echoShare: 0.8,
  );

  /// Loudspeaker, car, AirPlay and unknown routes: the assistant plays into
  /// the microphone's room.
  static const VoiceRouteProfile _open = VoiceRouteProfile(
    routeClass: VoiceRouteClass.other,
    minWords: 3,
    minWordsWithConfidence: 3,
    maxNoSpeechProb: 0.4,
    minAvgLogprob: -0.8,
    echoShare: 0.6,
  );

  /// The profile for [routeClass].
  static VoiceRouteProfile forClass(VoiceRouteClass routeClass) {
    final base = switch (routeClass) {
      VoiceRouteClass.builtInReceiver ||
      VoiceRouteClass.wiredHeadphones ||
      VoiceRouteClass.bluetoothA2DP => _contained,
      VoiceRouteClass.builtInSpeaker ||
      VoiceRouteClass.bluetoothHFP ||
      VoiceRouteClass.carPlay ||
      VoiceRouteClass.airPlay ||
      VoiceRouteClass.other => _open,
    };
    return VoiceRouteProfile(
      routeClass: routeClass,
      bargeInAllowed: base.bargeInAllowed,
      echoCancel: base.echoCancel,
      minWords: base.minWords,
      minWordsWithConfidence: base.minWordsWithConfidence,
      maxNoSpeechProb: base.maxNoSpeechProb,
      minAvgLogprob: base.minAvgLogprob,
      echoShare: base.echoShare,
    );
  }

  /// When the route is not known: the strict one.
  static VoiceRouteProfile get fallback => forClass(VoiceRouteClass.other);
}
