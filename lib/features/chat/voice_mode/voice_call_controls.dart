import 'dart:io' show Platform;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'chat_voice_mode_controller.dart';

/// The top-right controls of the call-style voice mode (the Muse call
/// screen): a vertical pill with a red hang-up button over a mic button.
///
/// Hang up ends voice mode through the same `stop` the bottom panel's end
/// button uses. The mic button is the panel's mute toggle ([toggleMute]), so
/// both stay in step.
class VoiceCallControls extends ConsumerWidget {
  const VoiceCallControls({super.key});

  /// Width of the pill and of each round button inside it.
  static const double buttonSize = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final muted = ref.watch(
      chatVoiceModeControllerProvider.select((voice) => voice.isMuted),
    );
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);
    final danger = Theme.of(context).colorScheme.error;

    return DecoratedBox(
      key: const ValueKey('voice-call-controls'),
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(buttonSize),
        border: Border.all(color: theme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoundButton(
              key: const ValueKey('voice-call-hangup'),
              tooltip: l10n.voiceCallEnd,
              background: danger,
              icon: Platform.isIOS
                  ? CupertinoIcons.phone_down_fill
                  : Icons.call_end_rounded,
              iconColor: Theme.of(context).colorScheme.onError,
              onPressed: () => controller.stop(reason: 'call-hangup'),
            ),
            const SizedBox(height: 3),
            _RoundButton(
              key: const ValueKey('voice-call-mute'),
              tooltip: muted ? l10n.unmute : l10n.mute,
              background: muted ? theme.warning : const Color(0x00000000),
              icon: muted
                  ? (Platform.isIOS
                        ? CupertinoIcons.mic_slash_fill
                        : Icons.mic_off_rounded)
                  : (Platform.isIOS
                        ? CupertinoIcons.mic_fill
                        : Icons.mic_rounded),
              iconColor: theme.textPrimary,
              onPressed: controller.toggleMute,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.tooltip,
    required this.background,
    required this.icon,
    required this.iconColor,
    required this.onPressed,
  });

  final String tooltip;
  final Color background;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: VoiceCallControls.buttonSize,
          height: VoiceCallControls.buttonSize,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: Icon(icon, size: 22, color: iconColor),
        ),
      ),
    );
  }
}
