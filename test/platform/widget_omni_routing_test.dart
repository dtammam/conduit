import 'package:conduit/platform/widget_omni_routing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('museyWidgetActionOf', () {
    test('maps each widget link to its action', () {
      expect(
        museyWidgetActionOf(Uri.parse('conduit://actions?homeWidget=true')),
        MuseyWidgetAction.actions,
      );
      expect(
        museyWidgetActionOf(Uri.parse('conduit://mic?homeWidget=true')),
        MuseyWidgetAction.voice,
      );
      expect(
        museyWidgetActionOf(Uri.parse('conduit://camera?homeWidget=true')),
        MuseyWidgetAction.camera,
      );
      expect(
        museyWidgetActionOf(Uri.parse('conduit://photos?homeWidget=true')),
        MuseyWidgetAction.photos,
      );
      expect(
        museyWidgetActionOf(Uri.parse('conduit://clipboard?homeWidget=true')),
        MuseyWidgetAction.clipboard,
      );
    });

    test('the old new_chat link, unknown links and bare links open the menu', () {
      for (final raw in [
        'conduit://new_chat?homeWidget=true',
        'conduit://bogus',
        'conduit:///',
        'conduit://',
      ]) {
        expect(
          museyWidgetActionOf(Uri.parse(raw)),
          MuseyWidgetAction.actions,
          reason: raw,
        );
      }
    });

    test('reads the action from the path when there is no host', () {
      expect(
        museyWidgetActionOf(Uri.parse('conduit:///mic')),
        MuseyWidgetAction.voice,
      );
    });
  });

  group('openOmniForWidget', () {
    test('opens the resolved Omni chat and returns its id', () async {
      final opened = <String>[];
      final id = await openOmniForWidget(
        resolveId: () async => 'omni-1',
        open: (chatId) async => opened.add(chatId),
      );
      expect(id, 'omni-1');
      expect(opened, ['omni-1']);
    });

    test('an unknown or empty id opens nothing and returns null', () async {
      var opens = 0;
      for (final resolved in <String?>[null, '']) {
        final id = await openOmniForWidget(
          resolveId: () async => resolved,
          open: (_) async => opens++,
        );
        expect(id, isNull);
      }
      expect(opens, 0);
    });

    test('a failure while resolving or opening never throws', () async {
      expect(
        await openOmniForWidget(
          resolveId: () async => throw StateError('offline'),
          open: (_) async {},
        ),
        isNull,
      );
      expect(
        await openOmniForWidget(
          resolveId: () async => 'omni-1',
          open: (_) async => throw StateError('not ready'),
        ),
        isNull,
      );
    });
  });

  group('waitForOpenChat', () {
    test('true at once when Omni is already open (the app was on Omni)', () async {
      expect(
        await waitForOpenChat(chatId: 'omni', currentId: () => 'omni'),
        isTrue,
      );
    });

    test('true once the chat switches from another chat to Omni', () async {
      var polls = 0;
      final ok = await waitForOpenChat(
        chatId: 'omni',
        currentId: () => ++polls < 3 ? 'other' : 'omni',
        step: const Duration(milliseconds: 5),
      );
      expect(ok, isTrue);
    });

    test('false when Omni never opens', () async {
      final ok = await waitForOpenChat(
        chatId: 'omni',
        currentId: () => 'other',
        timeout: const Duration(milliseconds: 40),
        step: const Duration(milliseconds: 10),
      );
      expect(ok, isFalse);
    });
  });

  group('museyMenuIntentProvider', () {
    test('a fresh ask is consumed once', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(museyMenuIntentProvider.notifier);
      expect(notifier.consume(), isFalse);
      notifier.request();
      expect(notifier.isPending(), isTrue);
      expect(notifier.consume(), isTrue);
      expect(notifier.consume(), isFalse);
    });

    test('an expired ask is dropped, never served late', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(museyMenuIntentProvider.notifier);
      final then = DateTime(2026, 11, 6, 9);
      notifier.request(now: then);
      final late = then.add(kMuseyMenuIntentLife + const Duration(seconds: 1));
      expect(notifier.isPending(now: late), isFalse);
      expect(notifier.consume(now: late), isFalse);
      expect(container.read(museyMenuIntentProvider), isNull);
    });
  });
}
