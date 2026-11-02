import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'musey_api.dart';

const String _cacheKey = 'musey_actions_cache_v1';

/// What the wrench menu shows: the last good list (cached on disk), whether a
/// refresh is running, and the error of the last refresh when nothing is
/// cached to show instead.
@immutable
class MuseyActionsState {
  const MuseyActionsState({
    this.actions,
    this.loading = false,
    this.error,
  });

  /// Null until a list has loaded or been read from the cache.
  final List<MuseyAction>? actions;
  final bool loading;
  final String? error;

  MuseyActionsState copyWith({
    List<MuseyAction>? actions,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => MuseyActionsState(
    actions: actions ?? this.actions,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

Map<String, Object?> _actionToJson(MuseyAction a) => <String, Object?>{
  'id': a.id,
  'label': a.label,
  'icon': ?a.icon,
  'fields': [
    for (final f in a.fields)
      <String, Object?>{
        'key': f.key,
        'label': f.label,
        'type': f.type.name,
        'required': f.required,
        if (f.options.isNotEmpty)
          'options': [
            for (final o in f.options)
              <String, Object?>{'value': o.value, 'label': o.label},
          ],
        'default': ?f.defaultValue,
        if (f.showWhenKey != null)
          'show_when': {'key': f.showWhenKey, 'value': f.showWhenValue},
        'note': ?f.note,
      },
  ],
};

final museyActionsProvider =
    NotifierProvider<MuseyActionsNotifier, MuseyActionsState>(
      MuseyActionsNotifier.new,
    );

class MuseyActionsNotifier extends Notifier<MuseyActionsState> {
  Future<void>? _inFlight;

  @override
  MuseyActionsState build() => const MuseyActionsState();

  /// Shows the cached list at once (when there is one), then asks the relay.
  /// A failed ask keeps the cached list and says nothing; with no list at all
  /// it leaves a plain error for the menu to show with a retry.
  Future<void> load() {
    final running = _inFlight;
    if (running != null) return running;
    return _inFlight = _run().whenComplete(() => _inFlight = null);
  }

  Future<void> _run() async {
    if (state.actions == null) {
      final cached = await _readCache();
      if (!ref.mounted) return;
      if (cached != null) state = state.copyWith(actions: cached);
    }
    final api = ref.read(museyApiProvider);
    if (api == null) {
      state = state.copyWith(
        loading: false,
        error: state.actions == null ? 'No relay is set up.' : null,
      );
      return;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final fresh = await api.fetchActions();
      if (!ref.mounted) return;
      state = MuseyActionsState(actions: fresh);
      unawaited(_writeCache(fresh));
    } on MuseyApiException catch (e) {
      if (!ref.mounted) return;
      state = MuseyActionsState(
        actions: state.actions,
        error: state.actions == null ? e.message : null,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = MuseyActionsState(
        actions: state.actions,
        error: state.actions == null ? 'Could not load the actions.' : null,
      );
    }
  }

  Future<List<MuseyAction>?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final list = parseMuseyActions(jsonDecode(raw));
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(List<MuseyAction> actions) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({'actions': actions.map(_actionToJson).toList()}),
      );
    } catch (_) {
      // The cache is a convenience.
    }
  }
}
