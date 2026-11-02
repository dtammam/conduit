import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'musey_flags.dart';

/// The line above the composer while a 💥 break note is pending: "What
/// broke?" and an x that returns to normal sending. The next message goes to
/// the relay's flag log, never to the model.
class BreakPromptBar extends ConsumerWidget {
  const BreakPromptBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(breakPromptProvider);
    if (target == null) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    return Padding(
      key: const ValueKey<String>('break-prompt-bar'),
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.xs),
      child: Container(
        padding: const EdgeInsetsDirectional.only(start: Spacing.sm),
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
        ),
        child: Row(
          children: [
            const Text(
              '\u{1F4A5}',
              style: TextStyle(fontSize: 16, decoration: TextDecoration.none),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'What broke?',
                key: const ValueKey<String>('break-prompt-text'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.textPrimary.withValues(alpha: 0.85),
                  decoration: TextDecoration.none,
                ),
              ),
            ),
            Semantics(
              button: true,
              label: 'Cancel',
              excludeSemantics: true,
              child: GestureDetector(
                key: const ValueKey<String>('break-prompt-cancel'),
                behavior: HitTestBehavior.opaque,
                onTap: () => ref.read(breakPromptProvider.notifier).cancel(),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Text(
                      '✕',
                      style: TextStyle(
                        fontSize: 16,
                        color: theme.textPrimary.withValues(alpha: 0.6),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
