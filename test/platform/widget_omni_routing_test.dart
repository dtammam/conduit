import 'dart:async';

import 'package:conduit/features/chat/musey/musey_api.dart';
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

    test('the Ask Musey text link types in Omni, no menu', () {
      final uri = Uri.parse('conduit://type?homeWidget=true');
      expect(museyWidgetActionOf(uri), MuseyWidgetAction.type);
      expect(museyWidgetActionUsesOmni(MuseyWidgetAction.type), isTrue);
      expect(museyWidgetActionIdOf(uri), isNull);
      expect(
        museyWidgetActionOf(Uri.parse('conduit:///type')),
        MuseyWidgetAction.type,
      );
    });

    test('the background link only opens the app', () {
      final action =
          museyWidgetActionOf(Uri.parse('conduit://open?homeWidget=true'));
      expect(action, MuseyWidgetAction.open);
      expect(museyWidgetActionUsesOmni(action), isFalse);
      for (final other in MuseyWidgetAction.values.where(
        (a) => a != MuseyWidgetAction.open,
      )) {
        expect(museyWidgetActionUsesOmni(other), isTrue, reason: other.name);
      }
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

  group('museyWidgetActionIdOf', () {
    test('reads a catalog id from an actions link', () {
      expect(
        museyWidgetActionIdOf(
          Uri.parse('conduit://actions?homeWidget=true&id=home_control'),
        ),
        'home_control',
      );
      expect(
        museyWidgetActionOf(
          Uri.parse('conduit://actions?homeWidget=true&id=chore_log'),
        ),
        MuseyWidgetAction.actions,
      );
    });

    test('no id, or an id that is not [a-z_]+, is null (plain menu)', () {
      for (final raw in [
        'conduit://actions?homeWidget=true',
        'conduit://actions?homeWidget=true&id=',
        'conduit://actions?homeWidget=true&id=Chore',
        'conduit://actions?homeWidget=true&id=chore-log',
        'conduit://actions?homeWidget=true&id=chore2',
        'conduit://actions?homeWidget=true&id=a%20b',
        'conduit://actions?homeWidget=true&id=..%2Fx',
        'conduit://actions?homeWidget=true&id=${'a' * 41}',
      ]) {
        expect(museyWidgetActionIdOf(Uri.parse(raw)), isNull, reason: raw);
      }
    });

    test('other widget links never carry an action id', () {
      expect(
        museyWidgetActionIdOf(Uri.parse('conduit://mic?homeWidget=true&id=x')),
        isNull,
      );
    });
  });

  group('resolveWidgetAction', () {
    const chore = MuseyAction(id: 'chore_log', label: 'Log a chore');
    const house = MuseyAction(id: 'home_control', label: 'Control the house');

    test('a known id opens that action', () async {
      final got = await resolveWidgetAction(
        id: 'chore_log',
        loadCatalog: () async {},
        readCatalog: () => const [house, chore],
      );
      expect(got, chore);
    });

    test('an unknown id (house switch off) falls back to the menu', () async {
      final got = await resolveWidgetAction(
        id: 'home_control',
        loadCatalog: () async {},
        readCatalog: () => const [chore],
      );
      expect(got, isNull);
    });

    test('a catalog that fails to load falls back, unless a cache is there',
        () async {
      final none = await resolveWidgetAction(
        id: 'chore_log',
        loadCatalog: () async => throw Exception('relay down'),
        readCatalog: () => null,
      );
      expect(none, isNull);
      final cached = await resolveWidgetAction(
        id: 'chore_log',
        loadCatalog: () async => throw Exception('relay down'),
        readCatalog: () => const [chore],
      );
      expect(cached, chore);
    });

    test('a catalog that hangs times out and falls back', () async {
      final got = await resolveWidgetAction(
        id: 'chore_log',
        loadCatalog: () => Completer<void>().future,
        readCatalog: () => null,
        timeout: const Duration(milliseconds: 20),
      );
      expect(got, isNull);
    });

    test('no id is the plain menu without touching the catalog', () async {
      var loaded = false;
      final got = await resolveWidgetAction(
        id: null,
        loadCatalog: () async => loaded = true,
        readCatalog: () => const [chore],
      );
      expect(got, isNull);
      expect(loaded, isFalse);
    });
  });

  group('museyMenuIntent action id', () {
    test('the id rides the ask and is served once', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(museyMenuIntentProvider.notifier);
      n.request(actionId: 'chore_log');
      expect(n.take()?.actionId, 'chore_log');
      expect(n.take(), isNull);
    });

    test('an expired ask never reopens a stale action', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(museyMenuIntentProvider.notifier);
      final then = DateTime(2026, 11, 6, 9);
      n.request(now: then, actionId: 'chore_log');
      final late = then.add(kMuseyMenuIntentLife + const Duration(seconds: 1));
      expect(n.take(now: late), isNull);
      // A later plain ask has no id left over.
      n.request();
      expect(n.take()?.actionId, isNull);
    });

    test('a newer plain ask replaces an older tile ask', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(museyMenuIntentProvider.notifier);
      n.request(actionId: 'chore_log');
      n.request();
      expect(n.take()?.actionId, isNull);
    });
  });
}
