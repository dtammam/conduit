import 'dart:math' as math;

import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A preset answer to an assistant reply: picking its emoji sends its text
/// as an ordinary user message.
enum QuickReplyReaction {
  yes('\u{1F44D}', 'Yes'),
  no('\u{1F44E}', 'No'),
  confirm('\u2705', 'Yes, do it.'),
  cancel('\u274C', 'Cancel.');

  const QuickReplyReaction(this.emoji, this.text);

  final String emoji;

  /// The English message, which earlier versions sent in every language.
  /// Kept short and literal so a model asking for a confirmation reads it
  /// as one.
  final String text;

  /// The message this reaction sends in the app's language.
  String localizedText(AppLocalizations l10n) => switch (this) {
    yes => l10n.quickReplyTextYes,
    no => l10n.quickReplyTextNo,
    confirm => l10n.quickReplyTextConfirm,
    cancel => l10n.quickReplyTextCancel,
  };
}

/// The reactions offered on an assistant reply, in display order.
const List<QuickReplyReaction> quickReplyReactions = QuickReplyReaction.values;

/// Every text a reaction may have been sent as: its English [text] and its
/// message in each supported language, so a reaction keeps its badge after
/// the app language changes.
final Map<String, QuickReplyReaction> _reactionsByText = {
  for (final reaction in quickReplyReactions) reaction.text: reaction,
  for (final locale in AppLocalizations.supportedLocales)
    for (final reaction in quickReplyReactions)
      reaction.localizedText(lookupAppLocalizations(locale)): reaction,
};

final int _longestReactionText = _reactionsByText.keys.fold(
  0,
  (longest, text) => math.max(longest, text.length),
);

/// The reaction whose text, in any supported language, is exactly
/// [content], if any.
QuickReplyReaction? quickReplyReactionForText(String content) =>
    content.length > _longestReactionText ? null : _reactionsByText[content];

/// Whether `messages[index]` is a reaction turn: a user message with nothing
/// but a reaction's text, sent right after an assistant reply. It shows as a
/// badge on that reply instead of a bubble of its own. A turn that failed to
/// send ([failedSendMessageId]) stays a bubble so its failure shows.
bool isQuickReplyTurn(
  List<ChatMessage> messages,
  int index, {
  String? failedSendMessageId,
}) {
  if (index <= 0 || index >= messages.length) return false;
  final message = messages[index];
  return message.role == 'user' &&
      message.id != failedSendMessageId &&
      quickReplyReactionForText(message.content) != null &&
      (message.attachmentIds?.isEmpty ?? true) &&
      (message.files?.isEmpty ?? true) &&
      messages[index - 1].role == 'assistant';
}

/// The reaction turn answering an assistant message: the reaction and the
/// id of the user turn that carries it.
typedef QuickReplyAnswer = ({QuickReplyReaction reaction, String turnId});

/// The reaction turns of one message list, found in a single pass so each
/// transcript row looks its own up instead of scanning the list.
class QuickReplyAnswers {
  QuickReplyAnswers.of(List<ChatMessage> messages) {
    for (var i = 1; i < messages.length; i++) {
      if (!isQuickReplyTurn(messages, i)) continue;
      final turn = messages[i];
      _byReplyId[messages[i - 1].id] = (
        reaction: quickReplyReactionForText(turn.content)!,
        turnId: turn.id,
      );
      _turnIds.add(turn.id);
    }
  }

  final Map<String, QuickReplyAnswer> _byReplyId = {};
  final Set<String> _turnIds = {};

  /// The reaction turn answering the assistant message [messageId], if any.
  QuickReplyAnswer? answerFor(String messageId) => _byReplyId[messageId];

  /// Whether the user message [messageId] is a reaction turn.
  bool isTurn(String messageId) => _turnIds.contains(messageId);
}

/// The reaction turns of the current chat, computed once per change of the
/// message list. Rows select their own entry.
final quickReplyAnswersProvider = Provider.autoDispose<QuickReplyAnswers>(
  (ref) => QuickReplyAnswers.of(ref.watch(chatMessagesProvider)),
);

/// The reaction turn answering the assistant message [messageId], if any.
QuickReplyAnswer? quickReplyAnswerFor(
  List<ChatMessage> messages,
  String messageId,
) => QuickReplyAnswers.of(messages).answerFor(messageId);

/// The reaction badge for the assistant message [messageId]: none when its
/// reaction turn failed to send ([failedSendMessageId]).
QuickReplyReaction? quickReplyBadgeFor(
  List<ChatMessage> messages,
  String messageId, {
  String? failedSendMessageId,
}) {
  final answer = quickReplyAnswerFor(messages, messageId);
  if (answer == null || answer.turnId == failedSendMessageId) return null;
  return answer.reaction;
}

/// Opens the reaction picker on a long press of [child], an assistant reply's
/// content.
///
/// The press is claimed at 400 ms, before text selection's own long press, so
/// while [enabled] a long press no longer selects a word. The detector stays
/// in the tree when disabled so the reply's content keeps its state.
class QuickReplyLongPress extends StatelessWidget {
  const QuickReplyLongPress({
    super.key,
    required this.enabled,
    required this.onSelected,
    required this.child,
  });

  static const Duration pressDuration = Duration(milliseconds: 400);

  final bool enabled;
  final ValueChanged<QuickReplyReaction> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The text under the press takes focus on touch down (selection does),
    // which would unfocus the composer. A press that becomes a reaction
    // hands focus back to whatever held it before.
    FocusNode? focusBeforePress;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: enabled
          ? <Type, GestureRecognizerFactory>{
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(duration: pressDuration),
                    (recognizer) => recognizer
                      ..onLongPressDown = (_) {
                        focusBeforePress = FocusManager.instance.primaryFocus;
                      }
                      ..onLongPressStart = (_) {
                        final previous = focusBeforePress;
                        if (previous != null &&
                            previous.context != null &&
                            !previous.hasPrimaryFocus) {
                          previous.requestFocus();
                        }
                        _open(context);
                      },
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: child,
    );
  }

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    ConduitHaptics.selectionClick();
    final picked = await showQuickReplyPicker(context, anchor: anchor);
    if (picked == null) return;
    ConduitHaptics.selectionClick();
    onSelected(picked);
  }
}

/// Shows the floating reaction pill just above [anchor] (global coordinates),
/// kept inside the screen. Resolves to the picked reaction, or null when the
/// user taps outside.
Future<QuickReplyReaction?> showQuickReplyPicker(
  BuildContext context, {
  required Rect anchor,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showGeneralDialog<QuickReplyReaction>(
    context: context,
    barrierDismissible: true,
    // The picker must not take focus: that would close the keyboard and move
    // the transcript under it.
    requestFocus: false,
    barrierLabel: l10n.close,
    barrierColor: const Color(0x00000000),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (dialogContext, _, _) => CustomSingleChildLayout(
      delegate: _PillLayout(
        anchor: anchor,
        padding: MediaQuery.paddingOf(dialogContext),
      ),
      child: _QuickReplyPill(
        onSelected: (reaction) => Navigator.of(dialogContext).pop(reaction),
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(curved),
          alignment: Alignment.bottomLeft,
          child: child,
        ),
      );
    },
  );
}

class _PillLayout extends SingleChildLayoutDelegate {
  const _PillLayout({required this.anchor, required this.padding});

  static const double _gap = Spacing.xs;
  static const double _margin = Spacing.sm;

  final Rect anchor;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = size.width - padding.right - childSize.width - _margin;
    final minLeft = padding.left + _margin;
    final maxTop = size.height - padding.bottom - childSize.height - _margin;
    final minTop = padding.top + _margin;
    final left = anchor.left.clamp(
      minLeft,
      maxLeft < minLeft ? minLeft : maxLeft,
    );
    final top = (anchor.top - childSize.height - _gap).clamp(
      minTop,
      maxTop < minTop ? minTop : maxTop,
    );
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_PillLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

class _QuickReplyPill extends StatelessWidget {
  const _QuickReplyPill({required this.onSelected});

  static const double _itemExtent = 44;

  final ValueChanged<QuickReplyReaction> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Container(
      key: const ValueKey<String>('quick-reply-picker'),
      padding: const EdgeInsets.all(Spacing.xxs),
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: BorderRadius.circular(_itemExtent),
        border: Border.all(
          color: theme.textPrimary.withValues(alpha: 0.12),
          width: BorderWidth.thin,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final reaction in quickReplyReactions)
            Semantics(
              button: true,
              label: l10n.quickReplyReactionLabel(reaction.localizedText(l10n)),
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelected(reaction),
                child: SizedBox(
                  width: _itemExtent,
                  height: _itemExtent,
                  child: Center(
                    child: Text(
                      reaction.emoji,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
