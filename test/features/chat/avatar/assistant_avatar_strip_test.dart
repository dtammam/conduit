import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_activity.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_strip.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;

  void replace(List<ChatMessage> messages) => state = messages;
}

/// A store that never touches the disk or the bundle.
class _FakeStore extends AssistantAvatarMediaStore {
  _FakeStore([this.media = AssistantAvatarMediaSet.empty]);

  final AssistantAvatarMediaSet media;
  int loads = 0;

  @override
  Future<AssistantAvatarMediaSet> load({String? personaId}) async {
    loads += 1;
    return media;
  }
}

final _at = DateTime.utc(2024, 1, 1, 12);

ChatMessage _user() =>
    ChatMessage(id: 'u', role: 'user', content: 'hi', timestamp: _at);

ChatMessage _reply({String content = '', bool isStreaming = true}) =>
    ChatMessage(
      id: 'a',
      role: 'assistant',
      content: content,
      timestamp: _at,
      isStreaming: isStreaming,
    );

/// The circle's semantics label, which carries the state now that the pill
/// shows the assistant's name.
Finder _circleLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

void _expectState(String word) {
  check(
    because: word,
    _circleLabel('Assistant, $word').evaluate(),
  ).length.equals(1);
}

void main() {
  late _Messages messages;

  Future<void> mount(
    WidgetTester tester, {
    List<ChatMessage>? initial,
    _FakeStore? store,
    VoidCallback? onNamePressed,
    VoidCallback? onActivityPressed,
  }) async {
    messages = _Messages(initial ?? [_user()]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatMessagesProvider.overrideWith(() => messages),
          automationsAvailableProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: AssistantAvatarStrip(
                modelName: 'Assistant',
                mediaStore: store ?? _FakeStore(),
                onNamePressed: onNamePressed,
                onActivityPressed: onActivityPressed,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final pill = find.byKey(const ValueKey('assistant-avatar-pill'));
  // The pill draws no icon: no chevron, just the name.
  final chevron = find.descendant(of: pill, matching: find.byType(Icon));
  final pickerButton = find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.label == 'Assistant' &&
        w.properties.button == true &&
        w.properties.hint == 'Opens the model picker',
  );
  final stateLine = find.byKey(const ValueKey('assistant-avatar-pill-state'));

  testWidgets('shows the name pill, the initial and Idle in semantics', (
    tester,
  ) async {
    await mount(tester);

    _expectState('Idle');
    check(
      find.descendant(of: pill, matching: find.text('Assistant')).evaluate(),
    ).length.equals(1);
    // Idle shows no state line; the state is only announced.
    check(find.text('Idle').evaluate()).isEmpty();
    check(stateLine.evaluate()).isEmpty();
    // No picker callback, no chevron.
    check(chevron.evaluate()).isEmpty();
    check(find.text('A').evaluate()).length.equals(1);
    check(tester.getSize(find.byKey(const ValueKey('assistant-avatar-circle'))))
        .equals(const Size.square(AssistantAvatarStrip.avatarSize));
    check(AssistantAvatarStrip.avatarSize).equals(72);
    check(
      tester
          .getSize(find.byKey(const ValueKey('assistant-avatar-strip')))
          .height,
    ).equals(AssistantAvatarStrip.height);
  });

  test('the strip hangs below the toolbar by its height less the toolbar', () {
    const toolbar = 48.0;
    check(AssistantAvatarStrip.insetBelowToolbar(toolbar))
        .equals(AssistantAvatarStrip.height - toolbar);
    check(AssistantAvatarStrip.insetBelowToolbar(1000)).equals(0);
  });

  testWidgets('idle, the name alone is the model picker', (tester) async {
    var picks = 0;
    var jumps = 0;
    await mount(
      tester,
      onNamePressed: () => picks++,
      onActivityPressed: () => jumps++,
    );

    check(chevron.evaluate()).isEmpty();
    check(pickerButton.evaluate()).length.equals(1);
    // With no icon beside it the name sits in the middle of the pill.
    final name = find.byKey(const ValueKey('assistant-avatar-pill-name'));
    check(tester.getCenter(name).dx).equals(tester.getCenter(pill).dx);
    await tester.tap(pill);
    await tester.pump();
    check(picks).equals(1);
    check(jumps).equals(0);
  });

  testWidgets('busy, the pill shows the state and jumps to the reply', (
    tester,
  ) async {
    var picks = 0;
    var jumps = 0;
    await mount(
      tester,
      onNamePressed: () => picks++,
      onActivityPressed: () => jumps++,
    );

    messages.replace([_user(), _reply()]);
    await tester.pump();
    check(
      find.descendant(of: pill, matching: find.text('Assistant')).evaluate(),
    ).length.equals(1);
    check(tester.widget<Text>(stateLine).data).equals('Working');
    check(chevron.evaluate()).isEmpty();
    check(pickerButton.evaluate()).isEmpty();
    check(tester.takeException()).isNull();
    await tester.tap(pill);
    await tester.pump();
    check(jumps).equals(1);
    check(picks).equals(0);

    // Back to idle: the state line goes and the picker returns.
    messages.replace([_user(), _reply(content: 'Hi.', isStreaming: false)]);
    await tester.pump();
    await tester.pump(kAssistantActivityDoneHold + const Duration(seconds: 1));
    check(stateLine.evaluate()).isEmpty();
    check(chevron.evaluate()).isEmpty();
    check(pickerButton.evaluate()).length.equals(1);
  });

  testWidgets('a running tool call names itself under the name', (
    tester,
  ) async {
    await mount(tester, onActivityPressed: () {});

    messages.replace([
      _user(),
      _reply(
        content:
            'One moment.\n'
            '<details type="tool_calls" done="false" id="c1" '
            'name="search_web" arguments="{}">\n'
            '<summary>Executing...</summary>\n</details>\n',
      ),
    ]);
    await tester.pump();
    check(tester.widget<Text>(stateLine).data).equals('Search web');
    // The circle keeps announcing the state word; the pill reads the step.
    _expectState('Working');
    check(
      find
          .byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.label == 'Search web' &&
                w.properties.button == true,
          )
          .evaluate(),
    ).length.equals(1);

    // A tool block with no name falls back to the state word.
    messages.replace([
      _user(),
      _reply(content: '<details type="tool_calls" done="false">\n<summary>'),
    ]);
    await tester.pump();
    check(tester.widget<Text>(stateLine).data).equals('Working');
  });

  testWidgets('an image tool call shows Making and names its step', (
    tester,
  ) async {
    await mount(tester, onActivityPressed: () {});

    messages.replace([
      _user(),
      _reply(
        content:
            '<details type="tool_calls" done="false" id="c1" '
            'name="generate_image" arguments="{}">\n'
            '<summary>Executing...</summary>\n</details>\n',
      ),
    ]);
    await tester.pump();
    _expectState('Making');
    check(tester.widget<Text>(stateLine).data).equals('Generate image');

    // Open WebUI's own image generation reports a status line instead.
    messages.replace([
      _user(),
      _reply().copyWith(
        statusHistory: const [
          ChatStatusUpdate(description: 'Creating image', done: false),
        ],
      ),
    ]);
    await tester.pump();
    _expectState('Making');
    check(tester.widget<Text>(stateLine).data).equals('Creating image');
  });

  testWidgets('follows the reply, then holds Done for the hold only', (
    tester,
  ) async {
    await mount(tester);

    messages.replace([_user(), _reply()]);
    await tester.pump();
    _expectState('Working');

    messages.replace([_user(), _reply(content: 'Hello')]);
    await tester.pump();
    _expectState('Working');

    messages.replace([_user(), _reply(content: 'Hello.', isStreaming: false)]);
    await tester.pump();
    _expectState('Done');

    await tester.pump(
      kAssistantActivityDoneHold - const Duration(milliseconds: 1),
    );
    _expectState('Done');

    await tester.pump(const Duration(milliseconds: 2));
    _expectState('Idle');
  });

  testWidgets('an errored reply goes straight back to Idle', (tester) async {
    await mount(tester);
    messages.replace([_user(), _reply(content: 'Hel')]);
    await tester.pump();

    messages.replace([
      _user(),
      _reply(
        content: 'Hel',
        isStreaming: false,
      ).copyWith(error: const ChatMessageError(content: 'boom')),
    ]);
    await tester.pump();
    check(_circleLabel('Assistant, Done').evaluate()).isEmpty();
    _expectState('Idle');
  });

  testWidgets('tapping the circle opens the sheet with four state rows', (
    tester,
  ) async {
    final store = _FakeStore(
      const AssistantAvatarMediaSet(
        userFiles: {
          AssistantActivity.done: AssistantAvatarMedia.file(
            '/nowhere/done.png',
            AssistantAvatarMediaKind.image,
          ),
        },
        bundled: {AssistantActivity.idle},
      ),
    );
    await mount(tester, store: store);

    await tester.tap(find.byKey(const ValueKey('assistant-avatar-circle')));
    await tester.pumpAndSettle();

    // The sheet opens on Activity; the state rows live under Appearance.
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    // Exactly four slots, top to bottom: Idle, Working, Making, Done.
    check(AssistantActivity.values.map((state) => state.name).toList())
        .deepEquals(['idle', 'working', 'making', 'done']);
    double? previousTop;
    for (final (state, label) in [
      (AssistantActivity.idle, 'Idle'),
      (AssistantActivity.working, 'Working'),
      (AssistantActivity.making, 'Making'),
      (AssistantActivity.done, 'Done'),
    ]) {
      final row = find.byKey(ValueKey('assistant-avatar-row-${state.name}'));
      check(because: state.name, row.evaluate()).length.equals(1);
      check(
        because: state.name,
        find.descendant(of: row, matching: find.text(label)).evaluate(),
      ).length.equals(1);
      final top = tester.getTopLeft(row).dy;
      if (previousTop != null) check(top).isGreaterThan(previousTop);
      previousTop = top;
    }
    final idleRow = find.byKey(const ValueKey('assistant-avatar-row-idle'));
    check(
      find.descendant(of: idleRow, matching: find.text('Default')).evaluate(),
    ).length.equals(1);
    final doneRow = find.byKey(const ValueKey('assistant-avatar-row-done'));
    check(find.descendant(of: doneRow, matching: find.text('Image')).evaluate())
        .length
        .equals(1);
    check(find.text('None').evaluate()).length.equals(2);
    check(find.text('Choose').evaluate()).length.equals(4);
    check(find.text('Remove').evaluate()).length.equals(4);
  });

  final pillSurface = find.byKey(
    const ValueKey('assistant-avatar-pill-surface'),
  );
  final pillGlass = find.descendant(
    of: pill,
    matching: find.byType(LiquidGlassContainer),
  );

  void useNativeGlass() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  }

  testWidgets('on iOS 26 the pill is a Liquid Glass capsule around its text', (
    tester,
  ) async {
    useNativeGlass();
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    await mount(tester, onNamePressed: () {});

    // The toolbar's regular system glass, as a capsule behind the text.
    final glass = tester.widget<LiquidGlassContainer>(pillGlass);
    check(glass.config.effect).equals(CNGlassEffect.regular);
    check(glass.config.interactive).isFalse();
    final size = tester.getSize(pillSurface);
    check(glass.config.cornerRadius).equals(size.height / 2);
    check(tester.getSize(find.byType(LiquidGlassContainer))).equals(size);
    // The name plus the padding and a one point border, at least the
    // minimum height, and no hand-drawn fill over the glass.
    final nameSize = tester.getSize(
      find.byKey(const ValueKey('assistant-avatar-pill-name')),
    );
    check(size.width).equals(nameSize.width + 2 * Spacing.md + 2);
    check(size.height).equals(Spacing.xl + Spacing.xs);
    final decoration =
        tester.widget<Container>(pillSurface).decoration! as BoxDecoration;
    check(decoration.color).isNull();
    check(decoration.border).equals(Border.all(color: const Color(0x00000000)));
    // Still the picker, named for VoiceOver, and still tappable.
    check(pickerButton.evaluate()).length.equals(1);

    // Busy, the two-line pill stays a capsule at its new height.
    messages.replace([_user(), _reply()]);
    await tester.pump();
    check(tester.widget<Text>(stateLine).data).equals('Working');
    final busySize = tester.getSize(pillSurface);
    check(busySize.height).isGreaterThan(size.height);
    check(tester.widget<LiquidGlassContainer>(pillGlass).config.cornerRadius)
        .equals(busySize.height / 2);
    // Let the native glass container's startup timer finish.
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('on iOS 26 the pill glass steps aside under a sheet', (
    tester,
  ) async {
    useNativeGlass();
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    await mount(tester);
    check(pillGlass.evaluate()).length.equals(1);
    final size = tester.getSize(pillSurface);

    // Any tracked Conduit sheet over the strip, as the avatar sheet is.
    unawaited(
      ThemedSheets.showAdaptive<void>(
        context: tester.element(pill),
        builder: (_) => const Text('Covering sheet'),
      ),
    );
    await tester.pumpAndSettle();
    check(find.text('Covering sheet').evaluate()).length.equals(1);
    check(pillGlass.evaluate()).isEmpty();
    // The pill keeps its place while its glass is hidden.
    check(tester.getSize(pillSurface)).equals(size);

    Navigator.of(tester.element(find.text('Covering sheet'))).pop();
    await tester.pumpAndSettle();
    check(pillGlass.evaluate()).length.equals(1);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('without native glass the pill is the opaque toolbar pill', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    await mount(tester);
    check(pillGlass.evaluate()).isEmpty();
    final theme = tester.element(pill).conduitTheme;
    final decoration =
        tester.widget<Container>(pillSurface).decoration! as BoxDecoration;
    check(decoration.color).equals(theme.surfaceContainerHighest);
    check(decoration.border).equals(Border.all(color: theme.cardBorder));
  });
}
