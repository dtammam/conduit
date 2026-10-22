import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_accent.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_strip.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/reactions/quick_reply_reactions.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/message_badge.dart';
import 'package:conduit/features/chat/widgets/message_bubble_colors.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/chat_action_button.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart' show contrastRatio;
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_prose_bubble.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _FixedAccent extends AssistantAvatarAutoAccent {
  _FixedAccent(this.color);

  final Color? color;

  @override
  Color? build() => color;
}

class _FakeStore extends AssistantAvatarMediaStore {
  @override
  Future<AssistantAvatarMediaSet> load() async => AssistantAvatarMediaSet.empty;
}

class _NoMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

final _at = DateTime.utc(2024, 1, 1, 12);

const double _screenWidth = 400;
const Color _yellow = Color(0xFFF2C230);
const Color _navy = Color(0xFF1C2A6B);

final _segment = find.byType(MarkdownProseBubbleSegment);
final _quickReplyBadge = find.byKey(
  const ValueKey('assistant-quick-reply-badge'),
);

Widget _app(
  Widget child, {
  AppSettings settings = const AppSettings(),
  bool dark = true,
  Color? autoAccent,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWithValue(settings),
      assistantAvatarAutoAccentProvider.overrideWith(
        () => _FixedAccent(autoAccent),
      ),
      textToSpeechControllerProvider.overrideWith(
        _TestTextToSpeechController.new,
      ),
      streamingHapticsEnabledProvider.overrideWithValue(false),
      ...overrides,
    ],
    child: MaterialApp(
      theme: dark
          ? AppTheme.dark(TweakcnThemes.t3Chat)
          : AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: _screenWidth, child: child),
        ),
      ),
    ),
  );
}

ChatMessage _reply(String content) => ChatMessage(
  id: 'assistant-bubble',
  role: 'assistant',
  content: content,
  timestamp: _at,
  model: 'Assistant',
);

Widget _assistant(
  String content, {
  QuickReplyReaction? badge,
  bool quickReplies = true,
}) => AssistantMessageWidget(
  message: _reply(content),
  isStreaming: false,
  showFollowUps: false,
  animateOnMount: false,
  modelName: 'Assistant',
  onCopy: () {},
  onDelete: () {},
  onQuickReply: quickReplies ? (_) {} : null,
  quickReplyBadge: badge,
);

final _actionButtons = find.byType(ChatActionButton);

/// The rects of the action row's buttons under a reply.
List<Rect> _actionRects(WidgetTester tester) => [
  for (var i = 0; i < _actionButtons.evaluate().length; i++)
    tester.getRect(_actionButtons.at(i)),
];

/// The top of the marker laid out right after [message], standing in for the
/// next message in the transcript.
const _nextKey = Key('next-message');

Widget _thenNext(Widget message) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    message,
    const SizedBox(key: _nextKey, height: 1),
  ],
);

Widget _user(String content, {MessageReceipt receipt = MessageReceipt.none}) =>
    UserMessageBubble(
      message: ChatMessage(
        id: 'user-bubble',
        role: 'user',
        content: content,
        timestamp: _at,
      ),
      isUser: true,
      onDelete: () {},
      receipt: receipt,
    );

const _bubblesOn = AppSettings(messageBubbles: true);
const _bubblesAndAvatarOn = AppSettings(
  messageBubbles: true,
  assistantAvatarEnabled: true,
);

/// The rect of the first bubble slice's painted fill.
Rect _bubbleRect(WidgetTester tester, {int index = 0}) => tester.getRect(
  find
      .descendant(of: _segment.at(index), matching: find.byType(DecoratedBox))
      .first,
);

Color _bubbleFill(WidgetTester tester, {int index = 0}) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(of: _segment.at(index), matching: find.byType(DecoratedBox))
        .first,
  );
  return (box.decoration as BoxDecoration).color!;
}

Color _userFill(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.byKey(const Key('user-message-bubble-surface')),
  );
  return (container.decoration! as BoxDecoration).color!;
}

/// RGBA pixels of a [size] square: [background] with a [figure] block over
/// [figureShare] of the rows and a thin [trim] band, like a character on a
/// white card.
Uint8List _pixels({
  required int size,
  required Color background,
  Color? figure,
  double figureShare = 0.3,
  Color? trim,
}) {
  final bytes = Uint8List(size * size * 4);
  final figureRows = (size * figureShare).round();
  for (var y = 0; y < size; y += 1) {
    for (var x = 0; x < size; x += 1) {
      var color = background;
      if (figure != null && y >= 10 && y < 10 + figureRows && x > 16) {
        color = figure;
      }
      if (trim != null && y >= size - 4) color = trim;
      final i = (y * size + x) * 4;
      bytes[i] = (color.r * 255).round();
      bytes[i + 1] = (color.g * 255).round();
      bytes[i + 2] = (color.b * 255).round();
      bytes[i + 3] = 255;
    }
  }
  return bytes;
}

void main() {
  group('reply bubble', () {
    testWidgets('off: replies render without bubbles, as before', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_assistant('Short answer.')));
      await tester.pumpAndSettle();

      check(find.text('Short answer.').evaluate()).isNotEmpty();
      check(_segment.evaluate()).isEmpty();
      check(
        tester
            .widget<StreamingMarkdownWidget>(
              find.byType(StreamingMarkdownWidget),
            )
            .proseBubble,
      ).isNull();
    });

    testWidgets('the sender line shows only with bubbles off', (tester) async {
      await tester.pumpWidget(_app(_assistant('Short answer.')));
      await tester.pumpAndSettle();
      check(find.text('Assistant').evaluate()).isNotEmpty();

      await tester.pumpWidget(
        _app(_assistant('Short answer.'), settings: _bubblesOn),
      );
      await tester.pumpAndSettle();
      check(find.text('Assistant').evaluate()).isEmpty();
    });

    testWidgets('on: a short reply hugs its text in a dark gray bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(_assistant('Short answer.'), settings: _bubblesOn),
      );
      await tester.pumpAndSettle();

      check(_segment.evaluate()).length.equals(1);
      final bubble = _bubbleRect(tester);
      final column = tester.getRect(find.byType(AssistantMessageWidget));
      check(bubble.left).equals(column.left);
      // The test font draws every glyph a square, so the text is about
      // 13 x 17 px; the bubble hugs it instead of taking its 85%.
      check(bubble.width).isLessThan(column.width * 0.7);
      final theme = tester
          .element(find.byType(AssistantMessageWidget))
          .conduitTheme;
      check(_bubbleFill(tester))
          .equals(resolveMessageBubbleColors(theme, null).assistantFill);
    });

    testWidgets('on: a parent rebuild hands the markdown the same bubble', (
      tester,
    ) async {
      MarkdownProseBubble? bubble() => tester
          .widget<StreamingMarkdownWidget>(find.byType(StreamingMarkdownWidget))
          .proseBubble;

      await tester.pumpWidget(
        _app(_assistant('Short answer.'), settings: _bubblesOn),
      );
      await tester.pumpAndSettle();
      final first = bubble();
      check(first).isNotNull();

      await tester.pumpWidget(
        _app(_assistant('Short answer.'), settings: _bubblesOn),
      );
      await tester.pump();
      check(identical(bubble(), first)).isTrue();
    });

    testWidgets('on: a long reply fills to 85% of the column, never more', (
      tester,
    ) async {
      final long = List.filled(40, 'word').join(' ');
      await tester.pumpWidget(
        _app(_assistant('$long\n\nSecond paragraph.'), settings: _bubblesOn),
      );
      await tester.pumpAndSettle();

      check(_segment.evaluate()).length.equals(2);
      final column = tester.getRect(find.byType(AssistantMessageWidget));
      final first = _bubbleRect(tester);
      final second = _bubbleRect(tester, index: 1);
      check(first.width).isLessOrEqual(column.width * 0.85 + 0.01);
      check(first.width).isGreaterThan(column.width * 0.8);
      // Slices of one bubble line up and touch.
      check(second.width).equals(first.width);
      check(second.top).equals(first.bottom);
    });

    testWidgets('on: wide code and tables stay inside the bubble', (
      tester,
    ) async {
      final wideLine = List.filled(30, 'abcdefgh').join('_');
      await tester.pumpWidget(
        _app(
          _assistant(
            'Here:\n\n```\n$wideLine\n```\n\n'
            '| a | b | c | d | e | f |\n|---|---|---|---|---|---|\n'
            '| $wideLine | 2 | 3 | 4 | 5 | 6 |',
          ),
          settings: _bubblesOn,
        ),
      );
      await tester.pumpAndSettle();

      check(tester.takeException()).isNull();
      final column = tester.getRect(find.byType(AssistantMessageWidget));
      for (var i = 0; i < _segment.evaluate().length; i += 1) {
        check(_bubbleRect(tester, index: i).right)
            .isLessOrEqual(column.left + column.width * 0.85 + 0.01);
      }
    });

    testWidgets('on: tool rows sit outside, between bubbles', (tester) async {
      await tester.pumpWidget(
        _app(
          _assistant(
            'On it.\n\n'
            '<details type="tool_calls" done="true" id="t1" '
            'name="web_search" arguments="{}" result="[]">\n'
            '<summary>Tool Executed</summary>\n</details>\n\n'
            'Here is what I found.',
          ),
          settings: _bubblesOn,
        ),
      );
      await tester.pumpAndSettle();

      check(_segment.evaluate()).length.equals(2);
      final firstBubble = _bubbleRect(tester);
      final secondBubble = _bubbleRect(tester, index: 1);
      check(secondBubble.top).isGreaterThan(firstBubble.bottom + 16);
      // Neither bubble holds the other's text: the tool row splits them.
      check(
        find
            .descendant(
              of: _segment.at(0),
              matching: find.textContaining('Here is what I found'),
            )
            .evaluate(),
      ).isEmpty();
    });

    testWidgets('on: the quick-reply badge sits on the bubble corner', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          _assistant('Send the draft?', badge: quickReplyReactions.first),
          settings: _bubblesOn,
        ),
      );
      await tester.pumpAndSettle();

      check(_quickReplyBadge.evaluate()).length.equals(1);
      final bubble = _bubbleRect(tester);
      final badge = tester.getRect(_quickReplyBadge);
      // Just inside the trailing edge, overlapping the bottom edge.
      check(badge.right).isLessThan(bubble.right);
      check(badge.left).isGreaterThan(bubble.left);
      check(badge.top).isLessThan(bubble.bottom);
      check(badge.bottom).isGreaterThan(bubble.bottom);
    });

    for (final (name, text) in [
      ('a one-word', 'Saved.'),
      (
        'a long',
        'Done: the report is saved to the shared folder and the team '
            'has been told it is ready for review.',
      ),
    ]) {
      testWidgets('on: a reaction on $name reply moves nothing below it', (
        tester,
      ) async {
        Future<(Rect, double, double)> layout(QuickReplyReaction? badge) async {
          await tester.pumpWidget(
            _app(
              _thenNext(_assistant(text, badge: badge)),
              settings: _bubblesOn,
            ),
          );
          await tester.pumpAndSettle();
          final rects = _actionRects(tester);
          check(rects).isNotEmpty();
          return (
            _bubbleRect(tester),
            rects.first.top,
            tester.getRect(find.byKey(_nextKey)).top,
          );
        }

        final (bubble, rowTop, nextTop) = await layout(null);
        final (badgedBubble, badgedRowTop, badgedNextTop) = await layout(
          quickReplyReactions.first,
        );
        check(badgedBubble).equals(bubble);
        check(badgedRowTop).equals(rowTop);
        check(badgedNextTop).equals(nextTop);

        // The badge overlaps the bubble, hangs into the gap and never
        // reaches an action button, even where a short bubble's corner sits
        // right above them.
        final badge = tester.getRect(_quickReplyBadge);
        check(badge.top).isLessThan(bubble.bottom);
        check(badge.bottom).isGreaterThan(bubble.bottom);
        for (final button in _actionRects(tester)) {
          check(because: '$button', badge.overlaps(button)).isFalse();
        }
        check(rowTop).isGreaterOrEqual(badge.bottom);
      });
    }

    testWidgets('on: the short badge sits over the buttons, not beside them', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          _assistant('Saved.', badge: quickReplyReactions.first),
          settings: _bubblesOn,
        ),
      );
      await tester.pumpAndSettle();
      final badge = tester.getRect(_quickReplyBadge);
      final rects = _actionRects(tester);
      // The case this guards: the badge shares the buttons' columns.
      check(rects.any((r) => r.left < badge.right && badge.left < r.right))
          .isTrue();
    });

    testWidgets(
      'on: a reply that cannot carry a reaction keeps the plain gap',
      (tester) async {
        Future<double> gap({required bool quickReplies}) async {
          await tester.pumpWidget(
            _app(
              _assistant('Saved.', quickReplies: quickReplies),
              settings: _bubblesOn,
            ),
          );
          await tester.pumpAndSettle();
          return _actionRects(tester).first.top - _bubbleRect(tester).bottom;
        }

        final plain = await gap(quickReplies: false);
        final withRoom = await gap(quickReplies: true);
        check(withRoom).isGreaterThan(plain);
      },
    );

    testWidgets('off: a reaction still makes room below the reply, as before', (
      tester,
    ) async {
      Future<double> rowTop(QuickReplyReaction? badge) async {
        await tester.pumpWidget(_app(_assistant('Saved.', badge: badge)));
        await tester.pumpAndSettle();
        return _actionRects(tester).first.top;
      }

      final plain = await rowTop(null);
      check(await rowTop(quickReplyReactions.first)).isGreaterThan(plain);
    });
  });

  group('user bubble', () {
    for (final settings in [_bubblesOn, _bubblesAndAvatarOn]) {
      testWidgets('on: the next message stays put as the receipt changes '
          '(avatar ${settings.assistantAvatarEnabled})', (tester) async {
        Future<double> nextTop(MessageReceipt receipt) async {
          await tester.pumpWidget(
            _app(
              _thenNext(_user('Hi', receipt: receipt)),
              settings: settings,
              autoAccent: _yellow,
            ),
          );
          await tester.pumpAndSettle();
          return tester.getRect(find.byKey(_nextKey)).top;
        }

        final none = await nextTop(MessageReceipt.none);
        for (final receipt in MessageReceipt.values) {
          check(because: '$receipt', await nextTop(receipt)).equals(none);
        }
      });
    }

    testWidgets('off: keeps the theme color and the outside receipt', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          _user('Hello there', receipt: MessageReceipt.delivered),
          settings: const AppSettings(assistantAvatarEnabled: true),
          autoAccent: _yellow,
        ),
      );
      await tester.pumpAndSettle();
      final theme = tester.element(find.byType(UserMessageBubble)).conduitTheme;
      check(_userFill(tester)).equals(theme.chatBubbleUser);
      final bubble = tester.getRect(
        find.byKey(const Key('user-message-bubble-surface')),
      );
      // Straddling the bubble's trailing edge, not inside it.
      final badge = tester.getRect(find.byType(MessageBadge));
      check(badge.left).isLessThan(bubble.right);
      check(badge.right).isGreaterThan(bubble.right);
    });

    testWidgets('on without avatar media: lighter gray than the reply', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(_user('Hello there'), settings: _bubblesAndAvatarOn),
      );
      await tester.pumpAndSettle();
      final theme = tester.element(find.byType(UserMessageBubble)).conduitTheme;
      final colors = resolveMessageBubbleColors(theme, null);
      check(_userFill(tester)).equals(colors.userFill);
      check(colors.userFill.computeLuminance())
          .isGreaterThan(colors.assistantFill.computeLuminance());
    });

    testWidgets('on with an avatar color: toned fill and black text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          // Laid out like the transcript, at its own height.
          _thenNext(
            _user('Change your avatar!', receipt: MessageReceipt.delivered),
          ),
          settings: _bubblesAndAvatarOn,
          autoAccent: _yellow,
        ),
      );
      await tester.pumpAndSettle();

      check(_userFill(tester)).equals(toneBubbleAccent(_yellow, dark: true));
      final text = tester.widget<Text>(find.text('Change your avatar!'));
      check(text.style!.color).equals(const Color(0xFF000000));

      // The receipt sits just inside the trailing corner, like a tapback.
      final bubble = tester.getRect(
        find.byKey(const Key('user-message-bubble-surface')),
      );
      final badge = tester.getRect(find.byType(MessageBadge));
      check(badge.right).isLessThan(bubble.right);
      check(badge.top).isLessThan(bubble.bottom);
      check(badge.bottom).isGreaterThan(bubble.bottom);
    });

    testWidgets('the avatar off falls back to gray even with a color', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(_user('Hi'), settings: _bubblesOn, autoAccent: _yellow),
      );
      await tester.pumpAndSettle();
      final theme = tester.element(find.byType(UserMessageBubble)).conduitTheme;
      check(_userFill(tester))
          .equals(resolveMessageBubbleColors(theme, null).userFill);
    });
  });

  group('colors', () {
    test('a bright yellow tones to a darkish gold with black text', () {
      final fill = toneBubbleAccent(_yellow, dark: true);
      final hsl = HSLColor.fromColor(fill);
      check(hsl.hue).isGreaterThan(35);
      check(hsl.hue).isLessThan(55);
      check(hsl.lightness).isCloseTo(0.40, 0.01);
      check(bubbleTextColorOn(fill)).equals(const Color(0xFF000000));
    });

    test('dark fills get white text', () {
      check(bubbleTextColorOn(toneBubbleAccent(_navy, dark: true)))
          .equals(const Color(0xFFFFFFFF));
      check(bubbleTextColorOn(const Color(0xFF202020)))
          .equals(const Color(0xFFFFFFFF));
    });

    test('every hue reaches WCAG AA on both themes', () {
      for (var hue = 0; hue < 360; hue += 5) {
        for (final dark in [true, false]) {
          final fill = toneBubbleAccent(
            HSLColor.fromAHSL(1, hue.toDouble(), 0.9, 0.5).toColor(),
            dark: dark,
          );
          check(
            because: 'hue $hue dark $dark',
            contrastRatio(fill, bubbleTextColorOn(fill)),
          ).isGreaterOrEqual(4.5);
        }
      }
    });

    test('gray defaults: dark reply, lighter user, theme text', () {
      const black = Color(0xFF000000);
      const white = Color(0xFFFFFFFF);
      final dark = computeMessageBubbleColors(
        background: black,
        foreground: white,
        dark: true,
      );
      check(dark.assistantFill.r).equals(dark.assistantFill.g);
      check(dark.userFill.r).equals(dark.userFill.b);
      check(dark.userFill.computeLuminance())
          .isGreaterThan(dark.assistantFill.computeLuminance());
      check(dark.assistantFill).not((it) => it.equals(black));
      check(dark.userText).equals(white);

      final light = computeMessageBubbleColors(
        background: white,
        foreground: black,
        dark: false,
      );
      check(light.userFill.computeLuminance())
          .isLessThan(light.assistantFill.computeLuminance());
      check(light.assistantFill).not((it) => it.equals(white));
      check(light.userText).equals(black);
    });

    test('stored choices round-trip', () {
      for (final swatch in MessageBubbleSwatch.values) {
        check(parseBubbleColor(swatch.storageValue)!.toARGB32())
            .equals(swatch.color.toARGB32());
      }
      check(parseBubbleColor(assistantAvatarBubbleColorAuto)).isNull();
      check(parseBubbleColor(assistantAvatarBubbleColorGray)).isNull();
      check(parseBubbleColor('#zzzzzz')).isNull();
    });

    test('the accent follows the avatar setting and the choice', () {
      Color? accent(AppSettings settings, {Color? auto = _yellow}) {
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWithValue(settings),
            assistantAvatarAutoAccentProvider.overrideWith(
              () => _FixedAccent(auto),
            ),
          ],
        );
        addTearDown(container.dispose);
        return container.read(messageBubbleAccentProvider);
      }

      check(accent(const AppSettings(messageBubbles: true))).isNull();
      check(accent(_bubblesAndAvatarOn)).equals(_yellow);
      check(accent(_bubblesAndAvatarOn, auto: null)).isNull();
      check(
        accent(
          const AppSettings(
            assistantAvatarEnabled: true,
            assistantAvatarBubbleColor: assistantAvatarBubbleColorGray,
          ),
        ),
      ).isNull();
      check(
        accent(
          AppSettings(
            assistantAvatarEnabled: true,
            assistantAvatarBubbleColor: MessageBubbleSwatch.blue.storageValue,
          ),
        )?.toARGB32(),
      ).equals(MessageBubbleSwatch.blue.color.toARGB32());
    });
  });

  group('dominant color', () {
    test('a yellow figure on white yields yellow, not white', () {
      final color = dominantVividColor(
        _pixels(
          size: 64,
          background: const Color(0xFFFFFFFF),
          figure: _yellow,
          trim: _navy,
        ),
      );
      check(color).isNotNull();
      final hsl = HSLColor.fromColor(color!);
      check(hsl.hue).isGreaterThan(40);
      check(hsl.hue).isLessThan(50);
      check(hsl.saturation).isGreaterThan(0.6);
    });

    test('white, gray and black images have no vivid color', () {
      for (final background in const [
        Color(0xFFFFFFFF),
        Color(0xFF808080),
        Color(0xFF000000),
      ]) {
        check(dominantVividColor(_pixels(size: 32, background: background)))
            .isNull();
      }
      // A speck of color is not enough.
      check(
        dominantVividColor(
          _pixels(
            size: 64,
            background: const Color(0xFFFFFFFF),
            figure: _yellow,
            figureShare: 0.02,
          ),
        ),
      ).isNull();
    });

    testWidgets('decoded images go through the same picker', (tester) async {
      final color = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 64, 64),
          Paint()..color = const Color(0xFFFFFFFF),
        );
        canvas.drawRect(
          const Rect.fromLTWH(20, 8, 30, 40),
          Paint()..color = _yellow,
        );
        final image = await recorder.endRecording().toImage(64, 64);
        try {
          return await dominantVividColorOfImage(image);
        } finally {
          image.dispose();
        }
      });
      check(color).isNotNull();
      check(HSLColor.fromColor(color!).hue).isGreaterThan(40);
    });
  });

  group('persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });
    tearDown(PreferencesStore.debugReset);

    test('bubbles default off and the color defaults to auto', () async {
      final settings = await SettingsService.loadSettings();
      check(settings.messageBubbles).isFalse();
      check(settings.assistantAvatarBubbleColor)
          .equals(assistantAvatarBubbleColorAuto);
    });

    test('the derived color is cached per media key', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(assistantAvatarAutoAccentProvider.notifier)
          .record('file:/idle.png|1|2', _yellow);
      check(
        PreferencesStore.getString(PreferenceKeys.assistantAvatarAccentCache),
      ).equals('file:/idle.png|1|2|#F2C230');

      final next = ProviderContainer();
      addTearDown(next.dispose);
      check(next.read(assistantAvatarAutoAccentProvider)?.toARGB32())
          .equals(_yellow.toARGB32());
      check(next.read(assistantAvatarAutoAccentProvider.notifier).cachedKey)
          .equals('file:/idle.png|1|2');
    });

    test('a blank video sample holds for the session only', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(
        assistantAvatarAutoAccentProvider.notifier,
      );
      await notifier.record('file:/idle.mp4|1|2', null, persist: false);
      check(notifier.cachedKey).equals('file:/idle.mp4|1|2');
      check(
        PreferencesStore.getString(PreferenceKeys.assistantAvatarAccentCache),
      ).isNull();

      // The next launch has nothing cached, so it samples again.
      final next = ProviderContainer();
      addTearDown(next.dispose);
      check(next.read(assistantAvatarAutoAccentProvider.notifier).cachedKey)
          .isNull();
    });

    testWidgets('the avatar sheet offers and persists a bubble color', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatMessagesProvider.overrideWith(_NoMessages.new),
            automationsAvailableProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantAvatarStrip(
                modelName: 'Assistant',
                mediaStore: _FakeStore(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('assistant-avatar-circle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      // Hidden while message bubbles are off.
      check(find.byKey(const ValueKey('bubble-color-auto')).evaluate())
          .isEmpty();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AssistantAvatarStrip)),
      );
      await tester.runAsync(
        () => container
            .read(appSettingsProvider.notifier)
            .setMessageBubbles(true),
      );
      await tester.pumpAndSettle();

      for (final key in [
        'bubble-color-auto',
        'bubble-color-gray',
        'bubble-color-gold',
      ]) {
        check(find.byKey(ValueKey(key)).evaluate()).length.equals(1);
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('bubble-color-blue')),
      );
      await tester.tap(find.byKey(const ValueKey('bubble-color-blue')));
      await tester.pumpAndSettle();
      check(
        PreferencesStore.get<String>(PreferenceKeys.assistantAvatarBubbleColor),
      ).equals(MessageBubbleSwatch.blue.storageValue);
    });
  });
}
