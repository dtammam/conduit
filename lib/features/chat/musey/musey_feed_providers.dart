import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'musey_feed_api.dart';

/// What the Feed page shows. A relay that errors, 404s or says disabled gives
/// an empty list: the page then reads "Nothing here yet".
@immutable
class FeedState {
  const FeedState({
    this.items = const <FeedItem>[],
    this.prompt = '',
    this.loading = false,
    this.loaded = false,
  });

  final List<FeedItem> items;
  final String prompt;
  final bool loading;

  /// A load has finished at least once (well or not).
  final bool loaded;

  FeedState copyWith({
    List<FeedItem>? items,
    String? prompt,
    bool? loading,
    bool? loaded,
  }) => FeedState(
    items: items ?? this.items,
    prompt: prompt ?? this.prompt,
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
  );
}

final feedProvider = NotifierProvider<FeedController, FeedState>(
  FeedController.new,
);

class FeedController extends Notifier<FeedState> {
  Future<void>? _inFlight;

  @override
  FeedState build() => const FeedState();

  /// Loads the list once per call; one load at a time, no retry loop. A
  /// failure keeps what is on screen.
  Future<void> load() {
    final running = _inFlight;
    if (running != null) return running;
    return _inFlight = _load().whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    final api = ref.read(museyFeedApiProvider);
    if (!ref.mounted) return;
    state = state.copyWith(loading: true);
    FeedData? data;
    try {
      data = await api?.getFeed();
    } catch (_) {
      data = null;
    }
    if (!ref.mounted) return;
    state = data == null
        ? state.copyWith(loading: false, loaded: true)
        : FeedState(items: data.items, prompt: data.prompt, loaded: true);
  }

  /// Saves the prompt; true when the relay took it.
  Future<bool> savePrompt(String prompt) async {
    final ok = await _safe(
      () => ref.read(museyFeedApiProvider)?.setFeedPrompt(prompt),
    );
    if (ok && ref.mounted) state = state.copyWith(prompt: prompt);
    return ok;
  }

  /// Asks the relay for a run; true when it started one.
  Future<bool> startRun() =>
      _safe(() => ref.read(museyFeedApiProvider)?.refreshFeed());

  /// Hearts or un-hearts [id] at once and puts it back when the relay says no.
  Future<void> toggleLike(String id) async {
    final index = state.items.indexWhere((i) => i.id == id);
    if (index < 0) return;
    final was = state.items[index].liked;
    _setLiked(id, !was);
    final ok = await _safe(
      () => ref.read(museyFeedApiProvider)?.like(id, liked: !was),
    );
    if (!ok && ref.mounted) _setLiked(id, was);
  }

  void _setLiked(String id, bool liked) {
    state = state.copyWith(
      items: [for (final i in state.items) i.id == id ? i.withLiked(liked) : i],
    );
  }
}

Future<bool> _safe(Future<bool>? Function() call) async {
  try {
    return await call() ?? false;
  } catch (_) {
    return false;
  }
}

@immutable
class IdeasState {
  const IdeasState({
    this.items = const <IdeaItem>[],
    this.loading = false,
    this.loaded = false,
  });

  final List<IdeaItem> items;
  final bool loading;
  final bool loaded;
}

final ideasProvider = NotifierProvider<IdeasController, IdeasState>(
  IdeasController.new,
);

class IdeasController extends Notifier<IdeasState> {
  Future<void>? _inFlight;

  @override
  IdeasState build() => const IdeasState();

  Future<void> load() {
    final running = _inFlight;
    if (running != null) return running;
    return _inFlight = _load().whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    final api = ref.read(museyFeedApiProvider);
    if (!ref.mounted) return;
    state = IdeasState(items: state.items, loading: true, loaded: state.loaded);
    List<IdeaItem>? items;
    try {
      items = await api?.getIdeas();
    } catch (_) {
      items = null;
    }
    if (!ref.mounted) return;
    state = IdeasState(items: items ?? state.items, loaded: true);
  }

  /// Takes the idea off the list at once, then tells the relay. A refused
  /// dismissal leaves it gone for now; the next load brings it back.
  Future<void> dismiss(String id) async {
    state = IdeasState(
      items: [
        for (final i in state.items)
          if (i.id != id) i,
      ],
      loaded: state.loaded,
    );
    await _safe(() => ref.read(museyFeedApiProvider)?.dismissIdea(id));
  }
}
