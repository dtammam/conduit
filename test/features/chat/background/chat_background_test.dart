import 'dart:io';

import 'package:conduit/features/chat/background/chat_background.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container(Directory dir) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  addTearDown(PreferencesStore.debugReset);
  final c = ProviderContainer(
    overrides: [chatBackgroundDirectoryProvider.overrideWith((_) => dir)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bg_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('settings', () {
    test('default is gradient with no color or image', () async {
      final c = await _container(tmp);
      final s = c.read(chatBackgroundProvider);
      expect(s.mode, ChatBackgroundMode.gradient);
      expect(s.colorValue, isNull);
      expect(s.imageName, isNull);
    });

    test('mode and color persist across a fresh container', () async {
      final c = await _container(tmp);
      c.read(chatBackgroundProvider.notifier).setColor(0xFF3B82F6);
      expect(c.read(chatBackgroundProvider).mode, ChatBackgroundMode.color);
      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      final s = c2.read(chatBackgroundProvider);
      expect(s.mode, ChatBackgroundMode.color);
      expect(s.colorValue, 0xFF3B82F6);
      c2.read(chatBackgroundProvider.notifier).setMode(ChatBackgroundMode.none);
      final c3 = ProviderContainer();
      addTearDown(c3.dispose);
      expect(c3.read(chatBackgroundProvider).mode, ChatBackgroundMode.none);
    });

    test(
      'image is copied into the documents folder and can be removed',
      () async {
        final c = await _container(tmp);
        final src = File(p.join(tmp.path, 'photo.png'))
          ..writeAsBytesSync([1, 2, 3]);
        final n = c.read(chatBackgroundProvider.notifier);
        expect(await n.setImageFrom(src), isTrue);
        final s = c.read(chatBackgroundProvider);
        expect(s.mode, ChatBackgroundMode.image);
        final copy = File(
          p.join(tmp.path, kChatBackgroundFolder, s.imageName!),
        );
        expect(copy.existsSync(), isTrue);
        expect(s.imageName, isNot(contains('/')));
        await n.removeImage();
        expect(copy.existsSync(), isFalse);
        expect(
          c.read(chatBackgroundProvider).mode,
          ChatBackgroundMode.gradient,
        );
        expect(c.read(chatBackgroundProvider).imageName, isNull);
      },
    );

    test('an unknown stored mode falls back to gradient', () async {
      SharedPreferences.setMockInitialValues({kChatBackgroundModeKey: 'zzz'});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      addTearDown(PreferencesStore.debugReset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(chatBackgroundProvider).mode, ChatBackgroundMode.gradient);
    });
  });

  group('gradient derivation', () {
    for (final palette in TweakcnThemes.all) {
      for (final b in Brightness.values) {
        final isDark = b == Brightness.dark;
        test('${palette.id} ${b.name}: distinct from page, 4.5:1 text', () {
          final v = palette.variantFor(b);
          final colors = chatBackgroundGradientColors(v, isDark);
          expect(colors.last, isNot(v.background));
          for (final c in colors) {
            expect(
              contrastRatio(v.foreground, c),
              greaterThanOrEqualTo(kChatBackgroundMinContrast),
            );
            if (contrastRatio(v.mutedForeground, v.background) >=
                kChatBackgroundMinContrast) {
              expect(
                contrastRatio(v.mutedForeground, c),
                greaterThanOrEqualTo(kChatBackgroundMinContrast),
              );
            }
          }
          // Gentle: the bottom stop stays close to the page in luminance.
          expect(
            (colors.last.computeLuminance() - v.background.computeLuminance())
                .abs(),
            lessThan(0.2),
          );
        });
      }
    }

    test('follows the accent: other palettes give other gradients', () {
      final a = chatBackgroundGradientColors(
        TweakcnThemes.claude.variantFor(Brightness.light),
        false,
      );
      final b = chatBackgroundGradientColors(
        TweakcnThemes.catppuccin.variantFor(Brightness.light),
        false,
      );
      expect(a.last, isNot(b.last));
    });

    test('light and dark differ for the same palette', () {
      final l = chatBackgroundGradientColors(
        TweakcnThemes.conduit.variantFor(Brightness.light),
        false,
      );
      final d = chatBackgroundGradientColors(
        TweakcnThemes.conduit.variantFor(Brightness.dark),
        true,
      );
      expect(l.last, isNot(d.last));
    });

    test('contrast numbers (printed for the report)', () {
      for (final pal in TweakcnThemes.all) {
        for (final b in Brightness.values) {
          final v = pal.variantFor(b);
          final c = chatBackgroundGradientColors(v, b == Brightness.dark);
          debugPrint(
            '${pal.id} ${b.name}: page ${v.background.toARGB32().toRadixString(16)}'
            ' top ${c.first.toARGB32().toRadixString(16)}'
            ' (${contrastRatio(v.foreground, c.first).toStringAsFixed(2)})'
            ' bottom ${c.last.toARGB32().toRadixString(16)}'
            ' (${contrastRatio(v.foreground, c.last).toStringAsFixed(2)})'
            ' muted ${contrastRatio(v.mutedForeground, c.last).toStringAsFixed(2)}'
            ' vs plain ${contrastRatio(v.mutedForeground, v.background).toStringAsFixed(2)}',
          );
        }
      }
    });
  });

  group('contrast guard', () {
    test('every swatch keeps text at 4.5:1 in both themes', () {
      for (final palette in TweakcnThemes.all) {
        for (final b in Brightness.values) {
          final v = palette.variantFor(b);
          for (final sw in [null, ...kChatBackgroundSwatches]) {
            final c = chatBackgroundFlatColor(v, b == Brightness.dark, sw);
            expect(
              contrastRatio(v.foreground, c),
              greaterThanOrEqualTo(kChatBackgroundMinContrast),
            );
          }
        }
      }
    });

    test('a too-loud color is pulled back toward the page', () {
      const page = Color(0xFFFFFFFF);
      const text = Color(0xFF111111);
      final out = chatBackgroundReadable(
        const Color(0xFF202020),
        page: page,
        foreground: text,
      );
      expect(contrastRatio(text, out), greaterThanOrEqualTo(4.5));
    });

    test('photo scrim is strong enough per theme', () {
      expect(chatBackgroundImageScrim(true), greaterThanOrEqualTo(0.6));
      expect(chatBackgroundImageScrim(false), greaterThanOrEqualTo(0.7));
    });
  });

  group('layer', () {
    Future<void> pump(WidgetTester tester, ProviderContainer c) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.conduit),
            home: const Scaffold(
              body: Stack(
                children: [Positioned.fill(child: ChatBackgroundLayer())],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('missing image file falls back to the gradient', (t) async {
      SharedPreferences.setMockInitialValues({
        kChatBackgroundModeKey: 'image',
        kChatBackgroundImageKey: 'gone.jpg',
      });
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      addTearDown(PreferencesStore.debugReset);
      final c = ProviderContainer(
        overrides: [chatBackgroundDirectoryProvider.overrideWith((_) => tmp)],
      );
      addTearDown(c.dispose);
      await pump(t, c);
      expect(t.takeException(), isNull);
      expect(find.byType(Image), findsNothing);
      final box = t.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(ChatBackgroundLayer),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((box.decoration as BoxDecoration).gradient, isNotNull);
    });

    testWidgets('corrupt image file shows the gradient, no crash', (t) async {
      final folder = Directory(p.join(tmp.path, kChatBackgroundFolder))
        ..createSync();
      File(p.join(folder.path, 'bad.jpg')).writeAsBytesSync([0, 1, 2]);
      SharedPreferences.setMockInitialValues({
        kChatBackgroundModeKey: 'image',
        kChatBackgroundImageKey: 'bad.jpg',
      });
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      addTearDown(PreferencesStore.debugReset);
      final c = ProviderContainer(
        overrides: [chatBackgroundDirectoryProvider.overrideWith((_) => tmp)],
      );
      addTearDown(c.dispose);
      await pump(t, c);
      await t.pump(const Duration(milliseconds: 200));
      expect(t.takeException(), isNull);
    });

    testWidgets('None paints nothing', (t) async {
      SharedPreferences.setMockInitialValues({kChatBackgroundModeKey: 'none'});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      addTearDown(PreferencesStore.debugReset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await pump(t, c);
      expect(
        find.descendant(
          of: find.byType(ChatBackgroundLayer),
          matching: find.byType(RepaintBoundary),
        ),
        findsNothing,
      );
    });
  });
}
