import 'dart:io';

import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_overlay.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Voice extends ChatVoiceModeController {
  _Voice(this.initial);

  final ChatVoiceModeSnapshot initial;
  int speakerToggles = 0;
  int stops = 0;
  int mutes = 0;

  @override
  ChatVoiceModeSnapshot build() => initial;

  @override
  Future<void> toggleSpeakerphone() async {
    speakerToggles++;
  }

  @override
  Future<void> stop({String reason = 'stop'}) async {
    stops++;
  }

  @override
  Future<void> toggleMute() async {
    mutes++;
  }
}

const _strip = ChatVoiceModeSnapshot(
  phase: ChatVoiceModePhase.speaking,
  isCollapsed: true,
  spokenResponse: 'Boy, you are late.',
);

Future<_Voice> _mount(WidgetTester tester, ChatVoiceModeSnapshot start) async {
  final voice = _Voice(start);
  final container = ProviderContainer(
    overrides: [chatVoiceModeControllerProvider.overrideWith(() => voice)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SizedBox(
            width: 402,
            height: 874,
            child: Stack(children: [ChatVoiceModeOverlay(bottomOffset: 0)]),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return voice;
}

bool _hasHangupOrMute(WidgetTester tester) {
  final l10n = AppLocalizations.of(
    tester.element(find.byType(ChatVoiceModeOverlay)),
  )!;
  final bad = {l10n.voiceCallEnd, l10n.mute, l10n.unmute};
  return find
      .byWidgetPredicate(
        (w) =>
            (w is Semantics && bad.contains(w.properties.label)) ||
            (w is Tooltip && bad.contains(w.message)),
      )
      .evaluate()
      .isNotEmpty ||
      find.byIcon(CupertinoIconsHangup.phoneDown).evaluate().isNotEmpty;
}

/// Stand-in so the check above reads clearly; the phone-down glyph is the
/// Cupertino one on iOS and the Material one elsewhere (tests run on Android).
class CupertinoIconsHangup {
  static const phoneDown = Icons.call_end_rounded;
}

void main() {
  testWidgets('the text strip shows the live text and a speaker toggle only', (
    tester,
  ) async {
    final voice = await _mount(tester, _strip);
    expect(
      find.byKey(const ValueKey('voice-overlay-collapsed')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice-overlay-expanded')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == 'Boy, you are late.',
      ),
      findsOneWidget,
    );
    expect(_hasHangupOrMute(tester), isFalse);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(find.byIcon(Icons.mic_off_rounded), findsNothing);
    // The speaker toggle is the one control.
    final speaker = find.byIcon(Icons.volume_down_rounded);
    expect(speaker, findsOneWidget);
    await tester.tap(speaker);
    await tester.pump();
    expect(voice.speakerToggles, 1);
    expect(voice.stops, 0);
    expect(voice.mutes, 0);
  });

  testWidgets('with no text the strip shows the phase, not a blank', (
    tester,
  ) async {
    await _mount(
      tester,
      const ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.listening,
        isCollapsed: true,
      ),
    );
    expect(find.byKey(const ValueKey('voice-strip-status')), findsOneWidget);
  });

  testWidgets('a tap on the strip opens the panel; it has no hang-up or mute', (
    tester,
  ) async {
    await _mount(tester, _strip);
    await tester.tap(find.byKey(const ValueKey('voice-overlay-collapsed')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-overlay-expanded')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-overlay-collapsed')), findsNothing);
    expect(_hasHangupOrMute(tester), isFalse);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.volume_down_rounded), findsOneWidget);
    // And the chevron folds it back to the strip.
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('voice-overlay-collapsed')),
      findsOneWidget,
    );
  });

  test('no composer call button is left in the chat or folder composer', () {
    for (final path in const [
      'lib/features/chat/widgets/modern_chat_input.dart',
      'lib/features/chat/views/chat_page.dart',
      'lib/features/navigation/views/folder_page.dart',
    ]) {
      final text = File(path).readAsStringSync();
      expect(text.contains('onVoiceCall'), isFalse, reason: path);
      expect(text.contains('primary-btn-voice-call'), isFalse, reason: path);
    }
  });
}
