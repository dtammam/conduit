import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/features/chat/reply/reply_to.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The bar above the composer while a message is being replied to: its first
/// line, cut short, and an X that cancels the reply.
class ReplyToBar extends ConsumerWidget {
  const ReplyToBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(replyTargetProvider);
    if (target == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      key: const ValueKey<String>('reply-to-bar'),
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.xs),
      child: Container(
        padding: const EdgeInsetsDirectional.only(start: Spacing.sm),
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
        ),
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
                color: theme.buttonPrimary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.replyingToLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.buttonPrimary,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      Text(
                        replyPreview(target.content),
                        key: const ValueKey<String>('reply-to-preview'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.textPrimary.withValues(alpha: 0.75),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: l10n.cancel,
                excludeSemantics: true,
                child: GestureDetector(
                  key: const ValueKey<String>('reply-to-cancel'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => ref.read(replyTargetProvider.notifier).clear(),
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
      ),
    );
  }
}
