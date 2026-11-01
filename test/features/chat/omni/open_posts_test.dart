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

  for (final dark in [false, true]) {
    group(dark ? 'dark theme' : 'light theme', () {
      Widget harness(Set<String> glowing, {required String id}) {
        return ProviderScope(
          overrides: [
            openPostsProvider.overrideWith(() => _FixedPosts(glowing)),
            messageBubbleAccentProvider.overrideWithValue(_accent),
          ],
          child: MaterialApp(
            theme: dark
                ? AppTheme.dark(TweakcnThemes.t3Chat)
                : AppTheme.light(TweakcnThemes.t3Chat),
            home: Scaffold(
              body: OpenPostHighlight(
                messageId: id,
                child: const SizedBox(width: 200, height: 60),
              ),
            ),
          ),
        );
      }

      double? tintOpacity(WidgetTester tester) {
        final fades = tester
            .widgetList<AnimatedOpacity>(
              find.descendant(
                of: find.byType(OpenPostHighlight),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .toList();
        return fades.isEmpty ? null : fades.first.opacity;
      }

      testWidgets('an open post is tinted with the persona color', (
        tester,
      ) async {
        await tester.pumpWidget(harness({'m'}, id: 'm'));
        check(tintOpacity(tester)).equals(1);
        final boxes = tester
            .widgetList<DecoratedBox>(
              find.descendant(
                of: find.byType(OpenPostHighlight),
                matching: find.byType(DecoratedBox),
              ),
            )
            .map((b) => (b.decoration as BoxDecoration).color)
            .toList();
        final alpha = dark ? kOpenPostTintDark : kOpenPostTintLight;
        check(boxes.first).equals(_accent.withValues(alpha: alpha));
        check(boxes.last).equals(_accent.withValues(alpha: kOpenPostEdgeAlpha));
      });

      testWidgets('a message that is not in the set is not tinted', (
        tester,
      ) async {
        await tester.pumpWidget(harness({'other'}, id: 'm'));
        check(tintOpacity(tester)).equals(0);
      });

      testWidgets('text keeps AA contrast on the tint', (tester) async {
        await tester.pumpWidget(harness({'m'}, id: 'm'));
        final context = tester.element(find.byType(OpenPostHighlight));
        final theme = context.conduitTheme;
        final alpha = dark ? kOpenPostTintDark : kOpenPostTintLight;
        final bg = Color.alphaBlend(
          _accent.withValues(alpha: alpha),
          theme.surfaceBackground,
        );
        check(contrastRatio(bg, theme.textPrimary)).isGreaterOrEqual(4.5);
      });
    });
  }

  testWidgets('the tint fades out when the post closes', (tester) async {
    final container = ProviderContainer(
      overrides: [
        openPostsProvider.overrideWith(() => _FixedPosts({'m'})),
        messageBubbleAccentProvider.overrideWithValue(_accent),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: const Scaffold(
            body: OpenPostHighlight(
              messageId: 'm',
              child: SizedBox(height: 40),
            ),
          ),
        ),
      ),
    );
    double opacity() => tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .first
        .opacity;
    check(opacity()).equals(1);
    // ignore: invalid_use_of_protected_member
    container.read(openPostsProvider.notifier).state = <String>{};
    await tester.pump();
    check(opacity()).equals(0);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
