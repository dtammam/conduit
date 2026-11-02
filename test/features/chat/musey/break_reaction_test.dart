import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/message_menu.dart';

class _Tts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

Widget _app({VoidCallback? onBreak, bool flagged = false}) => ProviderScope(
  overrides: [
    textToSpeechControllerProvider.overrideWith(_Tts.new),
    streamingHapticsEnabledProvider.overrideWithValue(false),
  ],
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.only(top: 200),
        child: AssistantMessageWidget(
          message: ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: 'Logged 12.50 for lunch.',
            timestamp: DateTime.utc(2026),
            model: 'Assistant',
            metadata: const {'responseDone': true},
          ),
          showFollowUps: false,
          animateOnMount: false,
          modelName: 'Assistant',
          onCopy: () {},
          onDelete: () {},
          onQuickReply: (_) {},
          onBreak: onBreak,
          breakFlagged: flagged,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('the menu offers the break reaction and tapping it calls back', (
    tester,
  ) async {
    var broke = 0;
    await tester.pumpWidget(_app(onBreak: () => broke++));
    await tester.pumpAndSettle();
    await openMessageMenu(tester);
    expect(find.byKey(const ValueKey('quick-reply-break')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-reply-break')));
    await tester.pumpAndSettle();
    expect(broke, 1);
  });

  testWidgets('without a handler the break reaction is not offered', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await openMessageMenu(tester);
    expect(find.byKey(const ValueKey('quick-reply-break')), findsNothing);
  });

  testWidgets('a flagged reply carries the break badge', (tester) async {
    await tester.pumpWidget(_app(onBreak: () {}, flagged: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-break-badge')), findsOneWidget);
  });
}
