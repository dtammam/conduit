import 'package:checks/checks.dart';
import 'package:conduit/features/chat/omni/message_jump.dart';
import 'package:conduit/features/chat/omni/open_posts.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/message_bubble_colors.dart';
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

class _Tts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _Posts extends OpenPostsNotifier {
  _Posts(this.ids);
  final Set<String> ids;
  @override
  Set<String> build() => ids;
}

void main() {
  testWidgets('a real reply glows around its own block, not the screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(_Tts.new),
          streamingHapticsEnabledProvider.overrideWithValue(false),
          openPostsProvider.overrideWith(() => _Posts({'a1'})),
          messageBubbleAccentProvider.overrideWithValue(
            const Color(0xFF8E5CD8),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: ChatMessage(
                id: 'a1',
                role: 'assistant',
                content: 'Hi',
                timestamp: DateTime.utc(2026),
                model: 'Assistant',
                metadata: const {'responseDone': true},
              ),
              showFollowUps: false,
              animateOnMount: false,
              modelName: 'Assistant',
              onCopy: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final glows = find.byType(OpenPostGlow);
    check(glows.evaluate()).isNotEmpty();
    for (final e in glows.evaluate()) {
      check(tester.getSize(find.byWidget(e.widget)).width).isLessThan(380);
    }
  });

  testWidgets('a message a tap jumped to glows, then the glow goes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        textToSpeechControllerProvider.overrideWith(_Tts.new),
        streamingHapticsEnabledProvider.overrideWithValue(false),
        openPostsProvider.overrideWith(() => _Posts(const {})),
        messageBubbleAccentProvider.overrideWithValue(const Color(0xFF8E5CD8)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: ChatMessage(
                id: 'a1',
                role: 'assistant',
                content: 'Hi',
                timestamp: DateTime.utc(2026),
                model: 'Assistant',
                metadata: const {'responseDone': true},
              ),
              showFollowUps: false,
              animateOnMount: false,
              modelName: 'Assistant',
              onCopy: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    bool glowing() => tester
        .widgetList<OpenPostGlowFrame>(find.byType(OpenPostGlowFrame))
        .any((f) => f.glowing);
    await tester.pump(const Duration(milliseconds: 500));
    check(glowing()).isFalse();
    container.read(highlightedMessageProvider.notifier).flash('a1');
    await tester.pump(const Duration(milliseconds: 500));
    check(glowing()).isTrue();
    await tester.pump(kMessageJumpHighlight + const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    check(glowing()).isFalse();
  });
}
