import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart' show ScaffoldMessenger, SnackBar;

import '../../../shared/services/navigation_service.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../chat/background/chat_background.dart';
import 'adaptive_segmented_selector.dart';

/// Appearance > Chat background. Musey only; see docs/MUSEY-BACKGROUND.md.
class ChatBackgroundSection extends ConsumerWidget {
  const ChatBackgroundSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(chatBackgroundProvider);
    final notifier = ref.read(chatBackgroundProvider.notifier);
    final theme = context.conduitTheme;
    final v = theme.variant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Chat background',
          style: theme.bodyMedium?.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.xxs),
        Text(switch (settings.mode) {
          ChatBackgroundMode.gradient =>
            'A soft gradient from your theme and accent.',
          ChatBackgroundMode.color => 'A flat tint behind the messages.',
          ChatBackgroundMode.image => 'A photo, dimmed so text stays clear.',
          ChatBackgroundMode.none => 'The plain chat color.',
        }, style: theme.bodySmall?.copyWith(color: theme.textSecondary)),
        const SizedBox(height: Spacing.sm),
        AdaptiveSegmentedSelector<ChatBackgroundMode>(
          value: settings.mode,
          showIcons: false,
          onChanged: notifier.setMode,
          options: [
            for (final entry in const {
              ChatBackgroundMode.gradient: 'Gradient',
              ChatBackgroundMode.color: 'Color',
              ChatBackgroundMode.image: 'Image',
              ChatBackgroundMode.none: 'None',
            }.entries)
              (
                value: entry.key,
                label: entry.value,
                cupertinoIcon: Icons.circle,
                materialIcon: Icons.circle,
                enabled: true,
              ),
          ],
        ),
        if (settings.mode == ChatBackgroundMode.color) ...[
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              _Swatch(
                label: 'Theme default',
                color: chatBackgroundFlatColor(v, theme.isDark, null),
                selected: settings.colorValue == null,
                onTap: () => notifier.setColor(null),
              ),
              for (final value in kChatBackgroundSwatches)
                _Swatch(
                  label: 'Color',
                  color: Color(value),
                  selected: settings.colorValue == value,
                  onTap: () => notifier.setColor(value),
                ),
            ],
          ),
        ],
        if (settings.mode == ChatBackgroundMode.image) ...[
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              _TextAction(
                label: settings.imageName == null
                    ? 'Choose photo'
                    : 'Change photo',
                onTap: () => _pick(context, notifier),
              ),
              if (settings.imageName != null) ...[
                const SizedBox(width: Spacing.lg),
                _TextAction(
                  label: 'Remove',
                  onTap: () => notifier.removeImage(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pick(BuildContext context, ChatBackgroundNotifier notifier) =>
      pickChatBackgroundPhoto(notifier);
}

/// How a photo pick ended.
enum ChatBackgroundPickOutcome { chosen, cancelled, failed }

/// Opens the photo library and sets the chosen photo as the chat background.
/// Shared by the Flutter page and the iOS native Appearance sheet.
///
/// [beforePick] runs first: the native sheet passes its dismiss here, because
/// the photo library cannot present over a sheet that is still on screen (it
/// never answers, so nothing happens). A cancelled pick changes nothing. Any
/// failure is logged and shown through [onMessage], never swallowed.
Future<ChatBackgroundPickOutcome> pickChatBackgroundPhoto(
  ChatBackgroundNotifier notifier, {
  Future<void> Function()? beforePick,
  Future<XFile?> Function()? pick,
  void Function(String message)? onMessage,
}) async {
  final say = onMessage ?? showChatBackgroundMessage;
  try {
    await beforePick?.call();
    final picked = await (pick ?? _pickFromGallery)();
    if (picked == null) return ChatBackgroundPickOutcome.cancelled;
    if (await notifier.setImageFrom(File(picked.path))) {
      return ChatBackgroundPickOutcome.chosen;
    }
    DebugLogger.error(
      'chat-background-save-failed',
      scope: 'chat/background',
      error: 'setImageFrom returned false',
    );
    say("Couldn't save that photo. Your background is unchanged.");
  } catch (error, stackTrace) {
    DebugLogger.error(
      'chat-background-pick-failed',
      scope: 'chat/background',
      error: error,
      stackTrace: stackTrace,
    );
    final denied =
        error is PlatformException && error.code.contains('access_denied');
    say(
      denied
          ? 'Photo access is off. Turn it on in Settings > Conduit > Photos.'
          : "Couldn't open your photos. Your background is unchanged.",
    );
  }
  return ChatBackgroundPickOutcome.failed;
}

Future<XFile?> _pickFromGallery() => ImagePicker().pickImage(
  source: ImageSource.gallery,
  maxWidth: 2400,
  maxHeight: 2400,
  imageQuality: 88,
);

/// Shows [message] in a snack bar on the app's root navigator.
void showChatBackgroundMessage(String message) {
  final context = NavigationService.context;
  if (context == null) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? theme.textPrimary : theme.dividerColor,
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Text(
            label,
            style: theme.bodyMedium?.copyWith(
              color: theme.buttonPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
