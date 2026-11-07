import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/chat/musey/musey_api.dart';

/// What a Musey home-widget tap asks for. Every one of them happens in the
/// Omni chat, never in a new chat.
enum MuseyWidgetAction { actions, voice, camera, photos, clipboard, open }

/// Whether a tap moves the app to the Omni chat. `open` (the M and the
/// widget's empty background) does not: the app opens as it was.
bool museyWidgetActionUsesOmni(MuseyWidgetAction action) =>
    action != MuseyWidgetAction.open;

/// The action a widget link (`musey://actions?homeWidget=true`) asks for.
/// The main pill and anything unknown (including the old `new_chat` link a
/// stale widget on the home screen still sends) open the action menu.
MuseyWidgetAction museyWidgetActionOf(Uri uri) {
  final name = uri.host.isNotEmpty ? uri.host : uri.pathSegments.firstOrNull;
  switch (name) {
    case 'open':
      return MuseyWidgetAction.open;
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

/// The only shape of a catalog id accepted from a widget URL.
final RegExp _museyActionIdPattern = RegExp(r'^[a-z_]{1,40}$');

/// The catalog id a "Musey Actions" tile carries
/// (`musey://actions?homeWidget=true&id=chore_log`), or null when the link has
/// none or it is not `[a-z_]+`. The id comes from a URL, so nothing else gets
/// through.
String? museyWidgetActionIdOf(Uri uri) {
  if (museyWidgetActionOf(uri) != MuseyWidgetAction.actions) return null;
  final id = uri.queryParameters['id'];
  if (id == null || !_museyActionIdPattern.hasMatch(id)) return null;
  return id;
}

/// The catalog action a tile asks for, or null (open the normal wrench menu).
/// [loadCatalog] refreshes the catalog (it may throw or time out); [readCatalog]
/// returns what is known afterwards. An unknown id (the relay leaves out
/// `home_control` when the house switch is off) or a catalog that cannot be had
/// is null, never an error.
Future<MuseyAction?> resolveWidgetAction({
  required String? id,
  required Future<void> Function() loadCatalog,
  required List<MuseyAction>? Function() readCatalog,
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (id == null) return null;
  try {
    await loadCatalog().timeout(timeout);
  } catch (_) {
    // Fall through: a cached list may still be there.
  }
  final catalog = readCatalog();
  if (catalog == null) return null;
  for (final a in catalog) {
    if (a.id == id) return a;
  }
  return null;
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
  String? _actionId;

  @override
  DateTime? build() => null;

  /// Asks for the menu, or with [actionId] for that one action's form. A new
  /// ask replaces any older one, id included.
  void request({DateTime? now, String? actionId}) {
    _actionId = actionId;
    state = now ?? DateTime.now();
  }

  /// True once when a live ask was waiting; an expired one is dropped.
  bool consume({DateTime? now}) => take(now: now) != null;

  /// Like [consume], but returns the ask (null when none or expired). The id
  /// is cleared with it, so a served or expired ask never comes back.
  MuseyMenuAsk? take({DateTime? now}) {
    final at = state;
    final id = _actionId;
    _actionId = null;
    if (at == null) return null;
    state = null;
    if ((now ?? DateTime.now()).difference(at) > kMuseyMenuIntentLife) {
      return null;
    }
    return MuseyMenuAsk(id);
  }

  bool isPending({DateTime? now}) {
    final at = state;
    return at != null &&
        (now ?? DateTime.now()).difference(at) <= kMuseyMenuIntentLife;
  }
}

/// A live ask for the wrench menu; [actionId] set means "open that action".
class MuseyMenuAsk {
  const MuseyMenuAsk(this.actionId);
  final String? actionId;
}
