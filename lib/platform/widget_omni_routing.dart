import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What a Musey home-widget tap asks for. Every one of them happens in the
/// Omni chat, never in a new chat.
enum MuseyWidgetAction { actions, voice, camera, photos, clipboard }

/// The action a widget link (`musey://actions?homeWidget=true`) asks for.
/// The main pill and anything unknown (including the old `new_chat` link a
/// stale widget on the home screen still sends) open the action menu.
MuseyWidgetAction museyWidgetActionOf(Uri uri) {
  final name = uri.host.isNotEmpty ? uri.host : uri.pathSegments.firstOrNull;
  switch (name) {
    case 'mic':
      return MuseyWidgetAction.voice;
    case 'camera':
      return MuseyWidgetAction.camera;
    case 'photos':
      return MuseyWidgetAction.photos;
    case 'clipboard':
      return MuseyWidgetAction.clipboard;
    default:
      return MuseyWidgetAction.actions;
  }
}

/// Moves the app to the Omni chat for a widget tap. Returns the Omni chat id
/// once it was opened, or null when the id is not known or opening failed:
/// the caller then just leaves the app open (never a new chat, never a throw).
Future<String?> openOmniForWidget({
  required Future<String?> Function() resolveId,
  required Future<void> Function(String chatId) open,
}) async {
  try {
    final id = await resolveId();
    if (id == null || id.isEmpty) return null;
    await open(id);
    return id;
  } catch (_) {
    return null;
  }
}

/// Waits until [currentId] reports [chatId] as the open chat, polling every
/// [step] up to [timeout]. False when the chat did not come up in time.
Future<bool> waitForOpenChat({
  required String chatId,
  required String? Function() currentId,
  Duration timeout = const Duration(seconds: 6),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (currentId() == chatId) return true;
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(step);
  }
}

/// How long a request for the action menu stays valid. A tap that could not
/// be served by then (no relay, Omni never opened) is dropped, so the menu
/// never pops up later on its own.
const Duration kMuseyMenuIntentLife = Duration(seconds: 20);

/// An ask to open the wrench menu in the Omni chat, raised by the home widget.
/// The composer serves it once Omni is open and the launch has settled.
final museyMenuIntentProvider =
    NotifierProvider<MuseyMenuIntent, DateTime?>(MuseyMenuIntent.new);

class MuseyMenuIntent extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void request({DateTime? now}) => state = now ?? DateTime.now();

  /// True once when a live ask was waiting; an expired one is dropped.
  bool consume({DateTime? now}) {
    final at = state;
    if (at == null) return false;
    state = null;
    return (now ?? DateTime.now()).difference(at) <= kMuseyMenuIntentLife;
  }

  bool isPending({DateTime? now}) {
    final at = state;
    return at != null &&
        (now ?? DateTime.now()).difference(at) <= kMuseyMenuIntentLife;
  }
}
