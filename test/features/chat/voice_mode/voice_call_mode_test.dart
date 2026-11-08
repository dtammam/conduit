import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart';
import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_strip.dart';
import 'package:conduit/features/chat/avatar/lip_sync.dart';
import 'package:conduit/features/chat/avatar/mouth_still_view.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/features/chat/voice_mode/voice_call_controls.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _NoMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

class _EmptyStore extends AssistantAvatarMediaStore {
  @override
  Future<AssistantAvatarMediaSet> load({String? personaId}) async =>
      AssistantAvatarMediaSet.empty;
}

class _Voice extends ChatVoiceModeController {
  _Voice(this.initial);

  final ChatVoiceModeSnapshot initial;
  final List<String> stops = [];
  int mutes = 0;

  @override
  ChatVoiceModeSnapshot build() => initial;

  void set(ChatVoiceModeSnapshot next) => state = next;

  @override
  Future<void> stop({String reason = 'stop'}) async {
    stops.add(reason);
    state = const ChatVoiceModeSnapshot();
  }

  @override
  Future<void> toggleMute() async {
    mutes++;
    state = ChatVoiceModeSnapshot(
      phase: ChatVoiceModePhase.listening,
      isMuted: !state.isMuted,
    );
  }
}

const _listening = ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);

/// The same composition the chat page makes: the strip in call mode while
/// voice mode is on in its expanded view, with the hang-up and mic pill.
class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(chatVoiceModeControllerProvider);
    final call = voice.isActive && !voice.isCollapsed;
    return Align(
      alignment: Alignment.topCenter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AssistantAvatarStrip(
            modelName: 'Assistant',
            mediaStore: _EmptyStore(),
            callMode: call,
          ),
          if (call)
            const Positioned(top: 0, right: 16, child: VoiceCallControls()),
        ],
      ),
    );
  }
}

void main() {
  late _Voice voice;

  Future<void> mount(WidgetTester tester, ChatVoiceModeSnapshot start) async {
    voice = _Voice(start);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatMessagesProvider.overrideWith(_NoMessages.new),
          automationsAvailableProvider.overrideWithValue(false),
          chatVoiceModeControllerProvider.overrideWith(() => voice),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: _Host()),
        ),
      ),
    );
    await tester.pump();
  }

  final circle = find.byKey(const ValueKey('assistant-avatar-circle'));
  final hangup = find.byKey(const ValueKey('voice-call-hangup'));
  final mute = find.byKey(const ValueKey('voice-call-mute'));

  testWidgets('the circle is normal size outside voice mode', (tester) async {
    await mount(tester, const ChatVoiceModeSnapshot());
    check(tester.getSize(circle).width).equals(AssistantAvatarStrip.avatarSize);
    check(hangup.evaluate()).isEmpty();
  });

  testWidgets('entering voice mode grows the circle 2.2 times, smoothly', (
    tester,
  ) async {
    await mount(tester, const ChatVoiceModeSnapshot());
    voice.set(_listening);
    await tester.pump();
    await tester.pump(AssistantAvatarStrip.callResize ~/ 2);
    final mid = tester.getSize(circle).width;
    check(mid).isGreaterThan(AssistantAvatarStrip.avatarSize);
    check(mid).isLessThan(AssistantAvatarStrip.callAvatarSize);
    await tester.pumpAndSettle();
    check(tester.getSize(circle).width).isCloseTo(72 * 2.2, 0.01);
    check(hangup.evaluate()).length.equals(1);
    check(mute.evaluate()).length.equals(1);
    // The strip grows to hold the overhang; the chat page's transcript inset
    // uses the static height, so the transcript stays put.
    check(
      tester
          .getSize(find.byKey(const ValueKey('assistant-avatar-strip')))
          .height,
    ).isCloseTo(AssistantAvatarStrip.callHeight, 0.01);
    // The name pill hangs under the bigger circle.
    final pillTop = tester.getTopLeft(
      find.byKey(const ValueKey('assistant-avatar-pill')),
    );
    final circleBottom = tester.getBottomLeft(circle);
    check(pillTop.dy).isGreaterThan(circleBottom.dy - 8);
  });

  testWidgets('the circle is square at rest, mid-animation and big, and '
      'fully visible', (tester) async {
    await mount(tester, const ChatVoiceModeSnapshot());
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    void expectRound() {
      final r = tester.getRect(circle);
      check(r.width).isCloseTo(r.height, 0.001);
      // Not clipped: the whole rect is on screen.
      check(r.left).isGreaterOrEqual(0);
      check(r.top).isGreaterOrEqual(0);
      check(r.right).isLessOrEqual(screen.width);
      check(r.bottom).isLessOrEqual(screen.height);
      // And inside the strip's own bounds, so it paints and takes taps.
      final strip = tester.getRect(
        find.byKey(const ValueKey('assistant-avatar-strip')),
      );
      check(strip.top).isLessOrEqual(r.top);
      check(strip.bottom).isGreaterOrEqual(r.bottom);
      // Centered at the top.
      check(r.center.dx).isCloseTo(screen.width / 2, 0.5);
    }

    expectRound();
    check(tester.getSize(circle).width).equals(72);
    voice.set(_listening);
    await tester.pump();
    await tester.pump(AssistantAvatarStrip.callResize ~/ 2);
    expectRound();
    final mid = tester.getSize(circle).width;
    check(mid).isGreaterThan(72);
    check(mid).isLessThan(AssistantAvatarStrip.callAvatarSize);
    await tester.pumpAndSettle();
    expectRound();
    check(tester.getSize(circle).width).isCloseTo(158.4, 0.01);
  });

  testWidgets('the big circle takes taps over its whole area', (tester) async {
    await mount(tester, _listening);
    await tester.pumpAndSettle();
    final r = tester.getRect(circle);
    // A point near the bottom edge, beyond the normal 72 pt strip height.
    final hits = tester.hitTestOnBinding(Offset(r.center.dx, r.bottom - 6));
    final target = tester.renderObject(circle);
    check(hits.path.any((h) => identical(h.target, target))).isTrue();
  });

  testWidgets('hang up ends voice mode and the circle shrinks back', (
    tester,
  ) async {
    await mount(tester, _listening);
    await tester.pumpAndSettle();
    check(tester.getSize(circle).width).isCloseTo(72 * 2.2, 0.01);
    await tester.tap(hangup);
    await tester.pumpAndSettle();
    check(voice.stops).deepEquals(['call-hangup']);
    check(tester.getSize(circle).width).equals(AssistantAvatarStrip.avatarSize);
    check(hangup.evaluate()).isEmpty();
  });

  testWidgets('the mic button is the mute toggle', (tester) async {
    await mount(tester, _listening);
    await tester.pumpAndSettle();
    await tester.tap(mute);
    await tester.pump();
    check(voice.mutes).equals(1);
    check(voice.state.isMuted).isTrue();
    // Muting leaves the call and the big circle in place.
    check(tester.getSize(circle).width).isCloseTo(72 * 2.2, 0.01);
  });

  testWidgets('the minimal view keeps the normal circle and no call pill', (
    tester,
  ) async {
    await mount(
      tester,
      const ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.listening,
        isCollapsed: true,
      ),
    );
    await tester.pumpAndSettle();
    check(tester.getSize(circle).width).equals(AssistantAvatarStrip.avatarSize);
    check(hangup.evaluate()).isEmpty();
    // Expanding (the stored preference flips) brings the big circle.
    voice.set(_listening);
    await tester.pumpAndSettle();
    check(tester.getSize(circle).width).isCloseTo(72 * 2.2, 0.01);
  });

  group('MouthStillView cross-fade', () {
    final a = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
      ),
    );
    final b = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC',
      ),
    );

    Widget host(ImageProvider image) => Directionality(
      textDirection: TextDirection.ltr,
      child: MouthStillView(image: image, size: 100),
    );

    double opacity(WidgetTester tester) => tester
        .widget<FadeTransition>(find.byKey(const ValueKey('mouth-still-fade')))
        .opacity
        .value;

    testWidgets('a new still fades in over the fade time, old one under it', (
      tester,
    ) async {
      await tester.pumpWidget(host(a));
      check(opacity(tester)).equals(1);
      check(find.byType(Image).evaluate()).length.equals(1);
      await tester.pumpWidget(host(b));
      check(opacity(tester)).equals(0);
      check(find.byType(Image).evaluate()).length.equals(2);
      await tester.pump(const Duration(milliseconds: kMouthFadeMs ~/ 2));
      check(opacity(tester)).isCloseTo(0.5, 0.1);
      await tester.pump(const Duration(milliseconds: kMouthFadeMs));
      check(opacity(tester)).equals(1);
      await tester.pump();
      check(find.byType(Image).evaluate()).length.equals(1);
    });

    testWidgets('the same still does not restart the fade', (tester) async {
      await tester.pumpWidget(host(a));
      await tester.pumpWidget(host(a));
      check(opacity(tester)).equals(1);
      check(find.byType(Image).evaluate()).length.equals(1);
    });
  });
}
