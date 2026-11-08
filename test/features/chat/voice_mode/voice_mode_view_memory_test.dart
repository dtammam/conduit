import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A controller that is already in a call, so the view toggles work.
class _ActiveController extends ChatVoiceModeController {
  @override
  ChatVoiceModeSnapshot build() =>
      const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);
}

final _provider =
    NotifierProvider<ChatVoiceModeController, ChatVoiceModeSnapshot>(
      _ActiveController.new,
    );

Future<void> pumpWrites() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  test('a fresh install opens on the text strip', () {
    expect(storedVoiceModeCollapsed(), isTrue);
  });

  test('values saved before build 191 (no version) open on the text strip', () async {
    // Old meaning: false was the full panel, the default for most installs.
    await PreferencesStore.put(PreferenceKeys.voiceModeCollapsed, false);
    expect(storedVoiceModeCollapsed(), isTrue);
    await PreferencesStore.put(PreferenceKeys.voiceModeCollapsed, true);
    expect(storedVoiceModeCollapsed(), isTrue);
  });

  test('collapse, expand and toggle are saved', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(_provider.notifier);
    n.collapse();
    await pumpWrites();
    expect(storedVoiceModeCollapsed(), isTrue);
    expect(PreferencesStore.getBool(PreferenceKeys.voiceModeCollapsed), isTrue);
    n.expand();
    await pumpWrites();
    expect(storedVoiceModeCollapsed(), isFalse);
    n.toggleCollapsed();
    await pumpWrites();
    expect(storedVoiceModeCollapsed(), isTrue);
    expect(c.read(_provider).isCollapsed, isTrue);
  });

  test('the saved view survives a new session (restore)', () async {
    await PreferencesStore.put(PreferenceKeys.voiceModeViewVersion, 2);
    await PreferencesStore.put(PreferenceKeys.voiceModeCollapsed, true);
    expect(storedVoiceModeCollapsed(), isTrue);
    await PreferencesStore.put(PreferenceKeys.voiceModeCollapsed, false);
    expect(storedVoiceModeCollapsed(), isFalse);
  });
}
