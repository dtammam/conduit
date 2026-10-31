import 'dart:async';

import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How long the name request may take before the last known name stays.
const Duration kAssistantNameTimeout = Duration(seconds: 3);

/// The name in a `GET persona` answer (`{"name": "..."}`), or null when the
/// answer has none.
String? parseAssistantName(Object? json) {
  if (json is! Map) return null;
  final name = json['name'];
  if (name is! String) return null;
  final trimmed = name.trim();
  if (trimmed.isEmpty || trimmed.length > 40) return null;
  return trimmed;
}

/// The name of the assistant the Voice provider's server is playing, for the
/// composer hint. Asked from `persona` on the Voice provider's address at
/// start, on resume and when the Voice provider changes. Null until a name
/// arrives, and left as it was when a request fails.
final assistantNameProvider =
    NotifierProvider<AssistantNameController, String?>(
      AssistantNameController.new,
    );

class AssistantNameController extends Notifier<String?>
    with WidgetsBindingObserver {
  Future<void>? _inFlight;

  @override
  String? build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    ref.listen(directVoiceProviderProvider, (previous, next) {
      if (previous?.profile.id != next?.profile.id ||
          previous?.profile.baseUrl != next?.profile.baseUrl) {
        if (next == null) state = null;
        unawaited(refresh());
      }
    });
    Future<void>.microtask(refresh);
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  /// Asks the server now. Does nothing without a Voice provider or while an
  /// earlier ask is running.
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) return running;
    return _inFlight = _run().whenComplete(() => _inFlight = null);
  }

  Future<void> _run() async {
    final voice = ref.read(directVoiceProviderProvider);
    if (voice == null) return;
    final lease = ref.read(directHttpClientPoolProvider).acquire(voice.profile);
    try {
      final response = await lease.dio.get<Object?>(
        'persona',
        options: Options(
          sendTimeout: kAssistantNameTimeout,
          receiveTimeout: kAssistantNameTimeout,
        ),
      );
      final name = parseAssistantName(response.data);
      if (name != null && ref.mounted) state = name;
    } catch (_) {
      // Keep the last known name.
    } finally {
      lease.release();
    }
  }
}
