import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_strip.dart';
import 'package:conduit/features/chat/musey/musey_feed_api.dart';
import 'package:conduit/features/chat/musey/musey_feed_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Only `react` is used; every other call is a test bug.
class _ReactApi implements MuseyFeedApi {
  final List<String> texts = [];
  final List<Completer<TurnHint?>> gates = [];

  @override
  Future<TurnHint?> react(String text) {
    texts.add(text);
    final gate = Completer<TurnHint?>();
    gates.add(gate);
    return gate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);
  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;

  void replace(List<ChatMessage> messages) => state = messages;
}

class _Store extends AssistantAvatarMediaStore {
  @override
  Future<AssistantAvatarMediaSet> load({String? personaId}) async =>
      AssistantAvatarMediaSet.empty;
}

final _at = DateTime.utc(2024, 1, 1, 12);
ChatMessage _user() =>
    ChatMessage(id: 'u', role: 'user', content: 'hi', timestamp: _at);
ChatMessage _reply({String content = '', bool streaming = true}) => ChatMessage(
  id: 'a',
  role: 'assistant',
  content: content,
  timestamp: _at,
  isStreaming: streaming,
);

void main() {
  late _ReactApi api;
  late _Messages messages;
  late ProviderContainer container;

  Future<void> mount(WidgetTester tester, {String name = 'Assistant'}) async {
    api = _ReactApi();
    messages = _Messages([_user()]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatMessagesProvider.overrideWith(() => messages),
          automationsAvailableProvider.overrideWithValue(false),
          museyFeedApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: AssistantAvatarStrip(
                modelName: name,
                mediaStore: _Store(),
                onActivityPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(AssistantAvatarStrip)),
    );
  }

  final pill = find.byKey(const ValueKey('assistant-avatar-pill-surface'));
  final stateLine = find.byKey(const ValueKey('assistant-avatar-pill-state'));
  final emoji = find.text('🎮');

  testWidgets('the emoji fades in beside Working and nothing else moves', (
    tester,
  ) async {
    await mount(tester);
    messages.replace([_user(), _reply()]);
    container.read(turnReactionProvider.notifier).request('play games');
    await tester.pump();
    check(api.texts).deepEquals(['play games']);
    check(emoji.evaluate()).isEmpty();
    final before = tester.getSize(pill);
    final nameBefore = tester.getTopLeft(
      find.byKey(const ValueKey('assistant-avatar-pill-name')),
    );

    api.gates.single.complete(const TurnHint(emoji: '🎮'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    check(emoji.evaluate()).length.equals(1);
    check(
      find
          .byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'Reaction: 🎮',
          )
          .evaluate(),
    ).length.equals(1);
    // Same height; the name stays centered in a pill that may only grow in
    // width.
    check(tester.getSize(pill).height).equals(before.height);
    final after = tester.getRect(pill);
    check(after.center.dx).isCloseTo(
      tester
          .getRect(find.byKey(const ValueKey('assistant-avatar-circle')))
          .center
          .dx,
      0.5,
    );
    check(
      tester
          .getTopLeft(find.byKey(const ValueKey('assistant-avatar-pill-name')))
          .dy,
    ).equals(nameBefore.dy);
    check(tester.widget<Text>(stateLine).data).equals('Working');

    // The turn ends: the emoji goes with the state line.
    messages.replace([_user(), _reply(content: 'ok', streaming: false)]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    check(emoji.evaluate()).isEmpty();
  });

  testWidgets(
    'null, error and a late answer for an older message show nothing',
    (tester) async {
      await mount(tester);
      messages.replace([_user(), _reply()]);
      final notifier = container.read(turnReactionProvider.notifier);

      notifier.request('one');
      api.gates[0].complete(null);
      await tester.pump();
      check(container.read(turnReactionProvider).emoji).isNull();

      notifier.request('two');
      api.gates[1].completeError(StateError('boom'));
      await tester.pump();
      check(container.read(turnReactionProvider).emoji).isNull();

      // A slow answer for message three arrives after message four started.
      notifier.request('three');
      notifier.request('four');
      api.gates[2].complete(const TurnHint(emoji: '🎮'));
      await tester.pump();
      check(container.read(turnReactionProvider).emoji).isNull();
      check(emoji.evaluate()).isEmpty();
      api.gates[3].complete(const TurnHint(emoji: '🎮'));
      await tester.pump(const Duration(milliseconds: 400));
      check(container.read(turnReactionProvider).emoji).equals('🎮');

      // A send that never went out clears it.
      notifier.cancel();
      check(container.read(turnReactionProvider).emoji).isNull();
    },
  );

  Future<void> startTurn(WidgetTester tester) async {
    await mount(tester);
    messages.replace([_user(), _reply()]);
    container.read(turnReactionProvider.notifier).request('what is on friday');
    await tester.pump();
  }

  final holding = find.byKey(const ValueKey('assistant-avatar-pill-holding'));
  final nameKey = find.byKey(const ValueKey('assistant-avatar-pill-name'));

  testWidgets('the status replaces Working with a quiet hold, nothing shifts', (
    tester,
  ) async {
    await startTurn(tester);
    // Waiting: the bar holds the line, the word Working never flashes.
    check(holding.evaluate()).length.equals(1);
    check(find.text('Working').evaluate()).isEmpty();
    final pillBefore = tester.getSize(pill);
    final nameBefore = tester.getCenter(nameKey);

    api.gates.single.complete(
      const TurnHint(status: 'Checking Friday', emoji: '📅'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    check(holding.evaluate()).isEmpty();
    check(tester.widget<Text>(stateLine).data).equals('Checking Friday');
    check(find.text('Working').evaluate()).isEmpty();
    // The name does not move sideways or up and down; the pill keeps its height.
    check(tester.getCenter(nameKey).dx).isCloseTo(nameBefore.dx, 0.5);
    check(tester.getCenter(nameKey).dy).isCloseTo(nameBefore.dy, 0.5);
    check(tester.getSize(pill).height).equals(pillBefore.height);
    // The emoji comes after the sentence, on the same line.
    final text = tester.getRect(stateLine);
    final e = tester.getRect(find.text('📅'));
    check(e.left).isGreaterOrEqual(text.right - 0.5);
    check((e.center.dy - text.center.dy).abs()).isLessThan(4);
  });

  testWidgets(
    'no status inside the wait falls back to Working, late answer dropped',
    (tester) async {
      await startTurn(tester);
      await tester.pump(kTurnReactionWait + const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      check(holding.evaluate()).isEmpty();
      check(tester.widget<Text>(stateLine).data).equals('Working');
      api.gates.single.complete(
        const TurnHint(status: 'Checking Friday', emoji: '📅'),
      );
      await tester.pump(const Duration(milliseconds: 400));
      check(tester.widget<Text>(stateLine).data).equals('Working');
      check(find.text('📅').evaluate()).isEmpty();
    },
  );

  testWidgets('a failed route falls back to Working at once', (tester) async {
    await startTurn(tester);
    api.gates.single.completeError(StateError('down'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    check(tester.widget<Text>(stateLine).data).equals('Working');
  });

  testWidgets('an old relay (emoji, no status) shows Working then the emoji', (
    tester,
  ) async {
    await startTurn(tester);
    api.gates.single.complete(const TurnHint(emoji: '🎮'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    check(tester.widget<Text>(stateLine).data).equals('Working');
    check(find.text('🎮').evaluate()).length.equals(1);
  });

  testWidgets('a status the app cannot trust is ignored', (tester) async {
    await startTurn(tester);
    api.gates.single.complete(
      const TurnHint(status: 'Checking your whole calendar for Friday'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    check(tester.widget<Text>(stateLine).data).equals('Working');
  });

  testWidgets('a reply nobody asked a guess for shows Working, no hold', (
    tester,
  ) async {
    await mount(tester);
    messages.replace([_user(), _reply()]);
    await tester.pump();
    check(holding.evaluate()).isEmpty();
    check(tester.widget<Text>(stateLine).data).equals('Working');
  });

  testWidgets('real tool progress beats the guess', (tester) async {
    await mount(tester);
    messages.replace([
      _user(),
      _reply(
        content:
            '<details type="tool_calls" done="false" id="c1" '
            'name="web_search" arguments="{}">\n'
            '<summary>Executing...</summary>\n</details>\n',
      ),
    ]);
    container.read(turnReactionProvider.notifier).request('news');
    await tester.pump();
    final line = tester.widget<Text>(stateLine).data;
    check(line).isNotNull();
    check(line!).not((it) => it.equals('Working'));
    api.gates.single.complete(const TurnHint(status: 'Reading news'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    check(tester.widget<Text>(stateLine).data).equals(line);
    check(holding.evaluate()).isEmpty();
  });

  testWidgets('a long name and a long step keep the pill inside its width', (
    tester,
  ) async {
    await mount(
      tester,
      name: 'An extremely long assistant name that cannot possibly fit here',
    );
    messages.replace([
      _user(),
      _reply(
        content:
            '<details type="tool_calls" done="false" id="c1" '
            'name="search_the_whole_internet_for_something_very_long" '
            'arguments="{}">\n<summary>Executing...</summary>\n</details>\n',
      ),
    ]);
    container.read(turnReactionProvider.notifier).request('x');
    await tester.pump();
    final plain = tester.getSize(pill);
    api.gates.single.complete(const TurnHint(emoji: '🎮'));
    await tester.pump(const Duration(milliseconds: 400));
    check(tester.takeException()).isNull();
    check(emoji.evaluate()).length.equals(1);
    final size = tester.getSize(pill);
    check(size.width).isLessOrEqual(240);
    check(size.height).equals(plain.height);
    // The emoji sits inside the pill.
    final pillRect = tester.getRect(pill);
    final e = tester.getRect(emoji);
    check(e.right).isLessOrEqual(pillRect.right);
    check(e.left).isGreaterOrEqual(pillRect.left);
  });
}
