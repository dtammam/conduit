import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/context_usage_providers.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide expect;
import 'package:shared_preferences/shared_preferences.dart';

final _at = DateTime.utc(2024, 1, 1);

/// A context window size used throughout; any valid size would do.
const _sampleWindow = 32768;

const _sampleModel = Model(id: 'sample-model', name: 'Sample model');

ChatMessage _user(String content) => ChatMessage(
  id: 'u-$content',
  role: 'user',
  content: content,
  timestamp: _at,
);

ChatMessage _reply(
  String content, {
  Map<String, dynamic>? usage,
  bool streaming = false,
}) => ChatMessage(
  id: 'a-$content',
  role: 'assistant',
  content: content,
  timestamp: _at,
  usage: usage,
  isStreaming: streaming,
);

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

  void put(List<ChatMessage> messages) => state = messages;
}

class _Account extends SettledActiveAccountId {
  @override
  String? build() => null;

  void put(String? accountId) => state = accountId;
}

void main() {
  group('contextUsageLevel', () {
    test('is neutral up to 80%, warning above it, critical above 95%', () {
      check(contextUsageLevel(0)).equals(ContextUsageLevel.normal);
      check(contextUsageLevel(0.8)).equals(ContextUsageLevel.normal);
      check(contextUsageLevel(0.81)).equals(ContextUsageLevel.warning);
      check(contextUsageLevel(0.95)).equals(ContextUsageLevel.warning);
      check(contextUsageLevel(0.951)).equals(ContextUsageLevel.critical);
      check(contextUsageLevel(1)).equals(ContextUsageLevel.critical);
    });
  });

  group('ContextUsage.fraction', () {
    const tokens = ContextTokenCount(
      usedTokens: _sampleWindow ~/ 4,
      estimated: false,
    );

    test('is the used share of the window', () {
      const usage = ContextUsage(
        modelId: 'm',
        tokens: tokens,
        contextWindow: _sampleWindow,
        windowSource: ContextWindowSource.user,
      );
      check(usage.fraction).equals(0.25);
    });

    test('clamps at a full window', () {
      const usage = ContextUsage(
        modelId: 'm',
        tokens: ContextTokenCount(usedTokens: 9000, estimated: false),
        contextWindow: 4096,
      );
      check(usage.fraction).equals(1.0);
    });

    test('is null while the window is unknown', () {
      const usage = ContextUsage(modelId: 'm', tokens: tokens);
      check(usage.fraction).isNull();
    });
  });

  group('reportedContextTokens', () {
    test('adds prompt and completion of the latest finished reply', () {
      final count = reportedContextTokens([
        _user('hi'),
        _reply('old', usage: {'prompt_tokens': 10, 'completion_tokens': 5}),
        _user('again'),
        _reply(
          'new',
          usage: {
            'prompt_tokens': 1200,
            'completion_tokens': 300,
            'total_tokens': 1500,
          },
        ),
      ]);
      check(count).isNotNull()
        ..has((c) => c.usedTokens, 'usedTokens').equals(1500)
        ..has((c) => c.promptTokens, 'promptTokens').equals(1200)
        ..has((c) => c.completionTokens, 'completionTokens').equals(300)
        ..has((c) => c.estimated, 'estimated').isFalse();
    });

    test('reads Ollama counts', () {
      final count = reportedContextTokens([
        _reply('a', usage: {'prompt_eval_count': 700, 'eval_count': 42}),
      ]);
      check(count).isNotNull()
        ..has((c) => c.usedTokens, 'usedTokens').equals(742)
        ..has((c) => c.promptTokens, 'promptTokens').equals(700)
        ..has((c) => c.completionTokens, 'completionTokens').equals(42);
    });

    test('falls back to total_tokens when the parts are missing', () {
      final count = reportedContextTokens([
        _reply('a', usage: {'total_tokens': 900}),
      ]);
      check(count).isNotNull()
        ..has((c) => c.usedTokens, 'usedTokens').equals(900)
        ..has((c) => c.promptTokens, 'promptTokens').isNull();
    });

    test('skips a reply that is still streaming', () {
      final count = reportedContextTokens([
        _reply('done', usage: {'prompt_tokens': 50, 'completion_tokens': 5}),
        _user('next'),
        _reply('typing', streaming: true),
      ]);
      check(count?.usedTokens).equals(55);
    });

    test('gives up when the latest reply has no usage or only zeros', () {
      check(
        reportedContextTokens([
          _reply('a', usage: {'prompt_tokens': 50, 'completion_tokens': 5}),
          _reply('b'),
        ]),
      ).isNull();
      check(
        reportedContextTokens([
          _reply(
            'a',
            usage: {
              'prompt_tokens': 0,
              'completion_tokens': 0,
              'total_tokens': 0,
            },
          ),
        ]),
      ).isNull();
    });
  });

  group('estimatedContextTokens', () {
    test('counts about four characters per token and says so', () {
      final count = estimatedContextTokens([_user('a' * 10), _reply('b' * 7)]);
      check(count).isNotNull()
        ..has((c) => c.usedTokens, 'usedTokens').equals(5)
        ..has((c) => c.estimated, 'estimated').isTrue();
    });

    test('has nothing to say about an empty transcript', () {
      check(estimatedContextTokens([_user('')])).isNull();
    });
  });

  group('countContextTokens', () {
    test('prefers the reported count and falls back to the estimate', () {
      check(
        countContextTokens([
          _user('a' * 400),
          _reply('b', usage: {'prompt_tokens': 30, 'completion_tokens': 2}),
        ]),
      ).isNotNull().has((c) => c.estimated, 'estimated').isFalse();
      check(countContextTokens([_user('a' * 400), _reply('b')]))
          .isNotNull()
          .has((c) => c.estimated, 'estimated')
          .isTrue();
    });
  });

  group('resolveContextWindow', () {
    test('reads a context_length capability', () {
      final model = Model.fromJson({
        'id': 'm',
        'name': 'M',
        'context_length': _sampleWindow,
      });
      final window = resolveContextWindow(
        model: model,
        overrides: const {},
        directOverrides: const {},
      );
      check(window.tokens).equals(_sampleWindow);
      check(window.source).equals(ContextWindowSource.model);
    });

    test("reads Open WebUI's num_ctx model parameter", () {
      final model = Model.fromJson({
        'id': 'm',
        'name': 'M',
        'info': {
          'params': {'num_ctx': 65536},
        },
      });
      check(modelAdvertisedContextWindow(model)).equals(65536);
    });

    test('prefers a value the person set, and is unknown otherwise', () {
      check(
        resolveContextWindow(
          model: _sampleModel,
          overrides: const {},
          directOverrides: const {},
        ).tokens,
      ).isNull();
      final set = resolveContextWindow(
        model: _sampleModel,
        overrides: {_sampleModel.id: _sampleWindow},
        directOverrides: const {},
      );
      check(set.tokens).equals(_sampleWindow);
      check(set.source).equals(ContextWindowSource.user);
    });

    test('a Direct model follows the Direct compaction setting', () {
      final id = DirectModelId.encode('profile', 'remote-model');
      final model = Model(id: id, name: 'Remote');
      final unset = resolveContextWindow(
        model: model,
        overrides: const {},
        directOverrides: const {},
      );
      check(unset.tokens).equals(kDefaultDirectContextLength);
      check(unset.source).equals(ContextWindowSource.directDefault);
      final set = resolveContextWindow(
        model: model,
        overrides: {id: 4096 * 4},
        directOverrides: {id: 8192},
      );
      check(set.tokens).equals(8192);
      check(set.source).equals(ContextWindowSource.user);
    });
  });

  group('providers', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugReset();
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });
    tearDown(PreferencesStore.debugReset);

    ({ProviderContainer container, _Messages messages}) containerFor({
      required Model? model,
      required List<ChatMessage> messages,
      bool enabled = true,
    }) {
      final notifier = _Messages(messages);
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AppSettings(showContextUsage: enabled),
          ),
          settledActiveAccountIdProvider.overrideWith(_Account.new),
          selectedModelProvider.overrideWith(() => _FixedModel(model)),
          chatMessagesProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, messages: notifier);
    }

    test('nothing to show without messages or a model', () {
      check(
        containerFor(
          model: _sampleModel,
          messages: const [],
        ).container.read(chatContextUsageProvider),
      ).isNull();
      check(
        containerFor(
          model: null,
          messages: [_user('hello')],
        ).container.read(chatContextUsageProvider),
      ).isNull();
    });

    test('nothing to show while the setting is off', () {
      check(
        containerFor(
          model: _sampleModel,
          messages: [_user('hello')],
          enabled: false,
        ).container.read(chatContextUsageProvider),
      ).isNull();
    });

    test('reported usage wins over the estimate', () {
      final usage = containerFor(
        model: _sampleModel,
        messages: [
          _user('hello'),
          _reply('hi', usage: {'prompt_tokens': 800, 'completion_tokens': 20}),
        ],
      ).container.read(chatContextUsageProvider);
      check(usage).isNotNull()
        ..has((u) => u.usedTokens, 'usedTokens').equals(820)
        ..has((u) => u.tokens.estimated, 'estimated').isFalse()
        ..has((u) => u.contextWindow, 'contextWindow').isNull()
        ..has((u) => u.fraction, 'fraction').isNull();
    });

    test('streamed chunks do not recount; a finished reply does', () {
      final question = _user('a' * 400);
      final setup = containerFor(model: _sampleModel, messages: [question]);
      final container = setup.container;
      final subscription = container.listen(
        chatContextUsageProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      final before = container.read(chatContextUsageProvider);
      check(before?.usedTokens).equals(100);

      setup.messages.put([question, _reply('partial', streaming: true)]);
      setup.messages.put([question, _reply('partial text', streaming: true)]);
      // Same instance: the count was not run again for the chunks.
      check(identical(container.read(chatContextUsageProvider), before))
          .isTrue();

      setup.messages.put([
        question,
        _reply('done', usage: {'prompt_tokens': 120, 'completion_tokens': 8}),
      ]);
      final after = container.read(chatContextUsageProvider);
      check(after).isNotNull()
        ..has((u) => u.usedTokens, 'usedTokens').equals(128)
        ..has((u) => u.tokens.estimated, 'estimated').isFalse();
    });

    test('a set window persists per model id and can be cleared', () async {
      final container = containerFor(
        model: _sampleModel,
        messages: [_user('a' * 400)],
      ).container;
      check(container.read(chatContextUsageProvider)?.contextWindow).isNull();

      await container
          .read(contextWindowOverridesProvider.notifier)
          .set(_sampleModel.id, _sampleWindow);
      check(container.read(chatContextUsageProvider)).isNotNull()
        ..has((u) => u.contextWindow, 'contextWindow').equals(_sampleWindow)
        ..has(
          (u) => u.windowSource,
          'windowSource',
        ).equals(ContextWindowSource.user)
        ..has((u) => u.tokens.estimated, 'estimated').isTrue();
      check(
        jsonDecode(
          PreferencesStore.getString(PreferenceKeys.contextWindowOverrides)!,
        ),
      ).isA<Map<String, dynamic>>().deepEquals({
        _sampleModel.id: _sampleWindow,
      });

      // A fresh container reads the stored value back.
      final reread = containerFor(
        model: _sampleModel,
        messages: [_user('a' * 400)],
      ).container;
      check(reread.read(contextWindowOverridesProvider))
          .deepEquals({_sampleModel.id: _sampleWindow});

      await container
          .read(contextWindowOverridesProvider.notifier)
          .clear(_sampleModel.id);
      check(container.read(contextWindowOverridesProvider)).isEmpty();
      check(container.read(chatContextUsageProvider)?.contextWindow).isNull();
    });

    test('a set window belongs to the account it was set on', () async {
      check(accountScopedPreferenceKeys)
          .contains(PreferenceKeys.contextWindowOverrides);
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'account-a');
      final container = containerFor(
        model: _sampleModel,
        messages: [_user('a' * 400)],
      ).container;
      await container
          .read(contextWindowOverridesProvider.notifier)
          .set(_sampleModel.id, _sampleWindow);
      check(PreferencesStore.getString(PreferenceKeys.contextWindowOverrides))
          .isNull();

      final account =
          container.read(settledActiveAccountIdProvider.notifier) as _Account;
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'account-b');
      account.put('account-b');
      check(container.read(contextWindowOverridesProvider)).isEmpty();

      await PreferencesStore.put(PreferenceKeys.activeServerId, 'account-a');
      account.put('account-a');
      check(container.read(contextWindowOverridesProvider))
          .deepEquals({_sampleModel.id: _sampleWindow});
    });

    test('an account with no windows of its own reads the device-wide ones '
        'set before they were stored per account', () async {
      await PreferencesStore.put(
        PreferenceKeys.contextWindowOverrides,
        jsonEncode({_sampleModel.id: _sampleWindow}),
      );
      await PreferencesStore.put(
        PreferenceKeys.accountScopedSettingsMigrated,
        true,
      );
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'account-a');
      final container = containerFor(
        model: _sampleModel,
        messages: [_user('a' * 400)],
      ).container;
      check(container.read(contextWindowOverridesProvider))
          .deepEquals({_sampleModel.id: _sampleWindow});

      await container
          .read(contextWindowOverridesProvider.notifier)
          .clear(_sampleModel.id);
      check(container.read(contextWindowOverridesProvider)).isEmpty();
    });

    test('rejects a window outside the supported range', () {
      final container = containerFor(model: null, messages: const []).container;
      check(
        () => container
            .read(contextWindowOverridesProvider.notifier)
            .set(_sampleModel.id, 100),
      ).throws<ArgumentError>();
    });

    test('ignores stored entries that are out of range', () async {
      await PreferencesStore.put(
        PreferenceKeys.contextWindowOverrides,
        jsonEncode({'ok': 8192, 'tiny': 12, 'junk': 'x'}),
      );
      final container = containerFor(model: null, messages: const []).container;
      check(container.read(contextWindowOverridesProvider))
          .deepEquals({'ok': 8192});
    });
  });
}
