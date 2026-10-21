import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/context_usage_providers.dart';
import 'package:conduit/features/chat/widgets/context_usage_ring.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _en = AppLocalizationsEn();
final _at = DateTime.utc(2024, 1, 1);

/// A context window size used throughout; any valid size would do.
const _sampleWindow = 32768;

const _sampleModel = Model(id: 'sample-model', name: 'Sample model');

class _FixedModel extends SelectedModel {
  _FixedModel(this.model);

  final Model? model;

  @override
  Model? build() => model;
}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

ChatMessage _user(String content) =>
    ChatMessage(id: 'u', role: 'user', content: content, timestamp: _at);

ChatMessage _reply({Map<String, dynamic>? usage}) => ChatMessage(
  id: 'a',
  role: 'assistant',
  content: 'reply',
  timestamp: _at,
  usage: usage,
);

ContextUsageRingPainter _painter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(ContextUsageRing).first,
      matching: find.byType(CustomPaint),
    ),
  );
  return paint.painter! as ContextUsageRingPainter;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required List<ChatMessage> messages,
    Model? model = _sampleModel,
    Map<String, int> overrides = const {},
    bool enabled = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          AppSettings(showContextUsage: enabled),
        ),
        selectedModelProvider.overrideWith(() => _FixedModel(model)),
        chatMessagesProvider.overrideWith(() => _Messages(messages)),
      ],
    );
    addTearDown(container.dispose);
    for (final entry in overrides.entries) {
      await container
          .read(contextWindowOverridesProvider.notifier)
          .set(entry.key, entry.value);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Center(child: ContextUsageRingButton())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('hidden while there is nothing to count', (tester) async {
    await pump(tester, messages: const []);
    expect(find.byType(ContextUsageRing), findsNothing);
  });

  testWidgets('hidden while the setting is off', (tester) async {
    await pump(tester, messages: [_user('a' * 400)], enabled: false);
    expect(find.byType(ContextUsageRing), findsNothing);
  });

  testWidgets('fills with the used share and keeps the neutral tint', (
    tester,
  ) async {
    await pump(
      tester,
      messages: [
        _user('hi'),
        _reply(usage: {'prompt_tokens': 6000, 'completion_tokens': 2192}),
      ],
      overrides: {_sampleModel.id: _sampleWindow},
    );
    final theme = tester.element(find.byType(ContextUsageRing)).conduitTheme;
    final painter = _painter(tester);
    check(painter.fraction).equals(0.25);
    check(painter.arcColor).equals(theme.textSecondary);
    expect(find.text('?'), findsNothing);
    expect(
      find.bySemanticsLabel(_en.contextUsageRingLabel('25%')),
      findsOneWidget,
    );
  });

  testWidgets('warning tint above 80%, critical above 95%', (tester) async {
    await pump(
      tester,
      messages: [
        _reply(usage: {'prompt_tokens': 3400, 'completion_tokens': 0}),
      ],
      overrides: {_sampleModel.id: 4096},
    );
    final theme = tester.element(find.byType(ContextUsageRing)).conduitTheme;
    check(_painter(tester).arcColor).equals(theme.warning);

    await pump(
      tester,
      messages: [
        _reply(usage: {'prompt_tokens': 3950, 'completion_tokens': 10}),
      ],
      overrides: {_sampleModel.id: 4096},
    );
    check(_painter(tester).arcColor).equals(theme.error);
  });

  testWidgets('on iOS 26 the ring sits in a toolbar glass circle', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);

    await pump(
      tester,
      messages: [
        _reply(usage: {'prompt_tokens': 1000, 'completion_tokens': 0}),
      ],
      overrides: {_sampleModel.id: 4096},
    );
    final button = find.byType(ContextUsageRingButton);
    final extent = conduitScaledControlExtent(tester.element(button));
    check(tester.getSize(button)).equals(Size.square(extent));

    // The toolbar's shared Liquid Glass surface, drawn as a full circle,
    // rather than a tinted Flutter button.
    final glass = tester.widget<LiquidGlassContainer>(
      find.descendant(of: button, matching: find.byType(LiquidGlassContainer)),
    );
    check(glass.config.effect).equals(CNGlassEffect.regular);
    check(glass.config.cornerRadius).equals(extent / 2);
    expect(
      find.descendant(of: button, matching: find.byType(AdaptiveButton)),
      findsNothing,
    );

    // The ring is icon sized and centered in the circle.
    final ring = find.byType(ContextUsageRing);
    check(tester.getSize(ring).width).isLessThan(extent);
    check(tester.getCenter(ring)).equals(tester.getCenter(button));
    // Let the native glass container's startup timer finish.
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('an unknown window shows an empty ring with a question mark', (
    tester,
  ) async {
    await pump(tester, messages: [_user('a' * 40)]);
    check(_painter(tester).fraction).equals(0);
    expect(find.text('?'), findsOneWidget);
    expect(
      find.bySemanticsLabel(_en.contextUsageRingUnknownLabel),
      findsOneWidget,
    );
  });

  testWidgets('the sheet shows the reported split and the window source', (
    tester,
  ) async {
    await pump(
      tester,
      messages: [
        _user('hi'),
        _reply(usage: {'prompt_tokens': 6000, 'completion_tokens': 2192}),
      ],
      overrides: {_sampleModel.id: _sampleWindow},
    );
    await tester.tap(find.byType(ContextUsageRingButton));
    await tester.pumpAndSettle();

    expect(find.text(_en.contextUsageTitle), findsOneWidget);
    expect(find.text(_en.contextUsageTokens(8192)), findsOneWidget);
    expect(find.text(_en.contextUsageTokens(_sampleWindow)), findsOneWidget);
    expect(find.text('32,768 tokens'), findsOneWidget);
    expect(find.text(_en.contextUsageSourceUser), findsOneWidget);
    expect(find.text('25%'), findsWidgets);
    expect(find.text(_en.contextUsageTokens(6000)), findsOneWidget);
    expect(find.text(_en.contextUsageTokens(2192)), findsOneWidget);
    expect(find.text(_en.contextUsageReportedNote), findsOneWidget);
    expect(find.text(_en.contextUsageEstimateNote), findsNothing);
    expect(find.text(_en.edit), findsOneWidget);
  });

  testWidgets('with no window the sheet says so, estimates, and sets one', (
    tester,
  ) async {
    final container = await pump(tester, messages: [_user('a' * 400)]);
    await tester.tap(find.byType(ContextUsageRingButton));
    await tester.pumpAndSettle();

    expect(find.text(_en.contextUsageAboutTokens(100)), findsOneWidget);
    expect(find.text(_en.contextUsageWindowNotSet), findsOneWidget);
    expect(find.text(_en.contextUsageFilled), findsNothing);
    expect(find.text(_en.contextUsageLastPrompt), findsNothing);
    expect(find.text(_en.contextUsageEstimateNote), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('context-usage-edit-window')));
    await tester.pumpAndSettle();
    expect(find.text(_en.contextUsagePickerDescription), findsOneWidget);
    final option = find.byKey(
      const ValueKey('context-window-option-$_sampleWindow'),
    );
    await tester.scrollUntilVisible(
      option,
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(option);
    await tester.pumpAndSettle();

    check(container.read(contextWindowOverridesProvider))
        .deepEquals({_sampleModel.id: _sampleWindow});
    expect(find.text(_en.contextUsageSourceUser), findsOneWidget);
    expect(find.text(_en.contextUsageWindowNotSet), findsNothing);
  });
}
