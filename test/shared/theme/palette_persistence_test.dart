import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends Mock implements OptimizedStorageService {}

ProviderContainer _app() {
  final storage = _Storage();
  when(
    storage.getThemePaletteId,
  ).thenAnswer((_) => PreferencesStore.getString(PreferenceKeys.themePalette));
  when(() => storage.setThemePaletteId(any())).thenAnswer(
    (i) => PreferencesStore.put(
      PreferenceKeys.themePalette,
      i.positionalArguments.first as String,
    ),
  );
  final c = ProviderContainer(
    overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  for (final id in ['claude', 'catppuccin']) {
    test(
      '$id sticks, survives a restart, and a second pick replaces it',
      () async {
        final first = _app();
        await first.read(appThemePaletteProvider.notifier).setPalette(id);
        expect(first.read(appThemePaletteProvider).id, id);
        expect(PreferencesStore.getString(PreferenceKeys.themePalette), id);

        final restarted = _app();
        expect(restarted.read(appThemePaletteProvider).id, id);

        await restarted
            .read(appThemePaletteProvider.notifier)
            .setPalette('conduit');
        expect(_app().read(appThemePaletteProvider).id, 'conduit');
      },
    );
  }
}
