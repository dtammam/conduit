import 'package:checks/checks.dart';
import 'package:conduit/features/chat/omni/open_posts.dart';
import 'package:conduit/features/chat/widgets/message_bubble_colors.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart' show contrastRatio;
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _accent = Color(0xFF8E5CD8);

Map<String, Object?> _post(
  String id,
  String slug,
  String at, {
  bool expects = true,
  bool open = true,
}) => {
  'message_id': id,
  'chat_id': 'c',
  'slug': slug,
  'title': 'T',
  'posted_at': at,
  'expects_reply': expects,
  'open': open,
  'closed_at': null,
  'closed_by': null,
};

class _FixedPosts extends OpenPostsNotifier {
  _FixedPosts(this.ids);
  final Set<String> ids;
  @override
  Set<String> build() => ids;
}

void main() {
  group('parseOpenPosts', () {
    test('reads the relay response', () {
      final posts = parseOpenPosts({
        'posts': [_post('m1', 'a-b', '2026-11-01T10:00:00.000Z')],
      });
      check(posts).length.equals(1);
      check(posts.single.messageId).equals('m1');
      check(posts.single.slug).equals('a-b');
      check(posts.single.expectsReply).isTrue();
      check(posts.single.open).isTrue();
      check(posts.single.postedAt)
          .equals(DateTime.parse('2026-11-01T10:00:00.000Z'));
    });

    test('skips malformed entries and tolerates a wrong shape', () {
      final posts = parseOpenPosts({
        'posts': [
          'x',
          {'slug': 's'},
          _post('', 's', '2026-11-01T10:00:00Z'),
          _post('m2', 's', 'not a date'),
          _post('m3', 's', '2026-11-01T10:00:00Z', open: false),
        ],
      });
      check(posts.map((p) => p.messageId)).deepEquals(['m3']);
      check(parseOpenPosts(null)).isEmpty();
      check(parseOpenPosts({'posts': 'no'})).isEmpty();
      check(parseOpenPosts([1, 2])).isEmpty();
    });
  });

  group('highlightedPostIds', () {
    Set<String> ids(List<Map<String, Object?>> posts) =>
        highlightedPostIds(parseOpenPosts({'posts': posts}));

    test('only the newest open post per slug', () {
      check(
        ids([
          _post('new', 'j', '2026-11-01T10:00:00Z'),
          _post('old', 'j', '2026-10-31T10:00:00Z'),
        ]),
      ).unorderedEquals({'new'});
    });

    test('order of the list does not matter', () {
      check(
        ids([
          _post('old', 'j', '2026-10-31T10:00:00Z'),
          _post('new', 'j', '2026-11-01T10:00:00Z'),
        ]),
      ).unorderedEquals({'new'});
    });

    test('a closed newest post means no older one glows either', () {
      check(
        ids([
          _post('new', 'j', '2026-11-01T10:00:00Z', open: false),
          _post('old', 'j', '2026-10-31T10:00:00Z'),
        ]),
      ).isEmpty();
    });

    test('a post that expects no reply never glows', () {
      check(ids([_post('a', 'j', '2026-11-01T10:00:00Z', expects: false)]))
          .isEmpty();
    });

    test('different routines each glow', () {
      check(
        ids([
          _post('a', 'one', '2026-11-01T10:00:00Z'),
          _post('b', 'two', '2026-11-01T09:00:00Z'),
        ]),
      ).unorderedEquals({'a', 'b'});
    });
  });

  group('open post glow', () {
    Widget app(
      ProviderContainer container,
      Widget body, {
      bool dark = false,
      bool reduceMotion = false,
    }) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: dark
              ? AppTheme.dark(TweakcnThemes.t3Chat)
              : AppTheme.light(TweakcnThemes.t3Chat),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      );
    }

    ProviderContainer containerWith(Set<String> ids) {
      final c = ProviderContainer(
        overrides: [
          openPostsProvider.overrideWith(() => _FixedPosts(ids)),
          messageBubbleAccentProvider.overrideWithValue(_accent),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    bool glowPainted(WidgetTester tester) => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(OpenPostGlow),
            matching: find.byType(CustomPaint),
          ),
        )
        .any((c) => c.foregroundPainter != null);

    const body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OpenPostGlow(
          messageId: 'm',
          radius: 12,
          hug: true,
          child: Text('A short routine post'),
        ),
      ],
    );

    for (final dark in [false, true]) {
      testWidgets('glows on an open post and not on another (dark=$dark)', (
        tester,
      ) async {
        await tester.pumpWidget(app(containerWith({'m'}), body, dark: dark));
        await tester.pump(const Duration(milliseconds: 500));
        check(glowPainted(tester)).isTrue();
        await tester.pumpWidget(app(containerWith({'x'}), body, dark: dark));
        await tester.pump(const Duration(milliseconds: 500));
        check(glowPainted(tester)).isFalse();
      });
    }

    testWidgets('goes out once the post is answered', (tester) async {
      final container = containerWith({'m'});
      await tester.pumpWidget(app(container, body));
      await tester.pump(const Duration(milliseconds: 500));
      check(glowPainted(tester)).isTrue();
      // ignore: invalid_use_of_protected_member
      container.read(openPostsProvider.notifier).state = <String>{};
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      check(glowPainted(tester)).isFalse();
      check(tester.hasRunningAnimations).isFalse();
    });

    testWidgets('breathes slowly, and not at all with Reduce Motion', (
      tester,
    ) async {
      await tester.pumpWidget(app(containerWith({'m'}), body));
      await tester.pump(const Duration(milliseconds: 500));
      check(tester.hasRunningAnimations).isTrue();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(containerWith({'m'}), body, reduceMotion: true),
      );
      await tester.pump();
      check(glowPainted(tester)).isTrue();
      check(tester.hasRunningAnimations).isFalse();
    });

    testWidgets('the glow is as wide as the message, not the screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(containerWith({'m'}), body));
      await tester.pump(const Duration(milliseconds: 500));
      final glow = tester.getSize(find.byType(OpenPostGlow));
      final text = tester.getSize(find.text('A short routine post'));
      check(glow.width).equals(text.width);
      check(glow.width).isLessThan(400);
    });
  });
}
