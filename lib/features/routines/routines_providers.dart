import 'dart:async';

import 'package:conduit/features/chat/avatar/persona_appearance_service.dart'
    show switchboardTokenProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routines_service.dart';

final routinesServiceProvider = Provider<RoutinesService>(
  (ref) => RoutinesService(),
);

/// The routines server's address and the token for it.
typedef RoutinesServer = ({String base, String token});

/// Reads the routines server settings. Null while the address or the token
/// is not set.
Future<RoutinesServer?> readRoutinesServer(Ref ref) async {
  final base = normalizeRoutinesUrl(
    ref.read(appSettingsProvider).routinesServerUrl,
  );
  if (base == null) return null;
  final token = await ref.read(switchboardTokenProvider.notifier).read();
  if (token == null || token.trim().isEmpty) return null;
  return (base: base, token: token.trim());
}

/// The routines server to use, or null when not set up. Follows the address
/// setting and the stored token.
final routinesServerProvider = FutureProvider.autoDispose<RoutinesServer?>((
  ref,
) {
  ref.watch(appSettingsProvider.select((s) => s.routinesServerUrl));
  ref.watch(switchboardTokenProvider);
  return readRoutinesServer(ref);
});

/// The last result of each routine by slug, or null when the server could not
/// be reached (or is not set up).
final routinesLastProvider =
    FutureProvider.autoDispose<Map<String, RoutineLast>?>((ref) async {
      final server = await ref.watch(routinesServerProvider.future);
      if (server == null) return null;
      return ref
          .read(routinesServiceProvider)
          .last(base: server.base, token: server.token);
    });

/// The server's push settings (quiet hours), or null when unreachable.
final pushSettingsProvider =
    AsyncNotifierProvider.autoDispose<PushSettingsController, PushSettings?>(
      PushSettingsController.new,
    );

class PushSettingsController extends AsyncNotifier<PushSettings?> {
  @override
  Future<PushSettings?> build() async {
    final server = await ref.watch(routinesServerProvider.future);
    if (server == null) return null;
    return ref
        .read(routinesServiceProvider)
        .settings(base: server.base, token: server.token);
  }

  /// Changes the settings on the server. The switch and times show the
  /// change at once and go back when the server refuses it. Returns whether
  /// the server took it.
  Future<bool> change({
    bool? quiet,
    String? quietStart,
    String? quietEnd,
  }) async {
    final before = state.asData?.value;
    final server = await ref.read(routinesServerProvider.future);
    if (before == null || server == null) return false;
    state = AsyncData(
      before.copyWith(quiet: quiet, quietStart: quietStart, quietEnd: quietEnd),
    );
    final updated = await ref
        .read(routinesServiceProvider)
        .updateSettings(
          base: server.base,
          token: server.token,
          quiet: quiet,
          quietStart: quietStart,
          quietEnd: quietEnd,
        );
    if (!ref.mounted) return updated != null;
    state = AsyncData(updated ?? before);
    return updated != null;
  }
}
