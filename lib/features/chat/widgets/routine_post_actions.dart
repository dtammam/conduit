import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _heartsKey = 'musey_post_hearts_v1';

/// Ids of the routine posts Dean hearted, kept on the phone per message id so
/// the hearts survive a restart and a chat reload.
final routinePostHeartsProvider =
    NotifierProvider<RoutinePostHearts, Set<String>>(RoutinePostHearts.new);

class RoutinePostHearts extends Notifier<Set<String>> {
  bool _loaded = false;

  @override
  Set<String> build() {
    unawaited(_load());
    return const <String>{};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_heartsKey) ?? const <String>[];
      if (!ref.mounted) return;
      _loaded = true;
      if (stored.isNotEmpty) state = {...stored, ...state};
    } catch (_) {
      _loaded = true;
    }
  }

  void toggle(String id) {
    state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
    unawaited(_save());
  }

  Future<void> _save() async {
    if (!_loaded) await _load();
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = state.toList();
      // The newest few hundred, so the list cannot grow without bound.
      await prefs.setStringList(
        _heartsKey,
        ids.length > 500 ? ids.sublist(ids.length - 500) : ids,
      );
    } catch (_) {}
  }
}

/// Whether the assistant message at [index] is a routine or check-in post
/// and not a reply: in the Omni chat a reply always follows a message of
/// Dean's, while the relay posts a routine's message with no user turn right
/// before it. The relay marks no post in the message itself, so this is the
/// only mark there is; a post that lands straight after Dean's own message
/// reads as a reply and gets no heart, which only leaves a button out.
bool isRoutinePostAt(List<ChatMessage> messages, int index) {
  if (index < 0 || index >= messages.length) return false;
  if (messages[index].role != 'assistant') return false;
  return index == 0 || messages[index - 1].role != 'user';
}

/// What Discuss sends for a post: its first line, without markdown marks.
String routinePostDiscussText(String content) {
  for (final raw in content.split('\n')) {
    var line = raw.trim();
    line = line.replaceFirst(RegExp(r'^(#{1,6}\s+|[-*>]\s+)+'), '');
    line = line.replaceAll(RegExp(r'[*_`]+'), '').trim();
    if (line.isEmpty) continue;
    if (line.length > 160) line = '${line.substring(0, 160).trimRight()}…';
    return "Let's discuss this: $line";
  }
  return "Let's discuss this";
}

/// A heart and a Discuss button under a routine post.
class RoutinePostActions extends ConsumerWidget {
  const RoutinePostActions({
    super.key,
    required this.messageId,
    required this.content,
    required this.onDiscuss,
  });

  final String messageId;
  final String content;
  final void Function(String text) onDiscuss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final liked = ref.watch(
      routinePostHeartsProvider.select((ids) => ids.contains(messageId)),
    );
    return Padding(
      key: const ValueKey('routine-post-actions'),
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Row(
        children: [
          GestureDetector(
            key: const ValueKey('routine-post-heart'),
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                ref.read(routinePostHeartsProvider.notifier).toggle(messageId),
            child: Semantics(
              button: true,
              label: l10n.museyLike,
              selected: liked,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xs),
                child: Icon(
                  cupertinoIconForSFSymbol(liked ? 'heart.fill' : 'heart'),
                  size: IconSize.md,
                  color: liked ? theme.error : theme.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: Spacing.xs),
          AdaptiveButton(
            key: const ValueKey('routine-post-discuss'),
            onPressed: () => onDiscuss(routinePostDiscussText(content)),
            label: l10n.museyDiscuss,
            style: AdaptiveButtonStyle.tinted,
            size: AdaptiveButtonSize.small,
            useNative: false,
          ),
        ],
      ),
    );
  }
}
