import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'musey_feed_api.dart';

/// What the Feed page shows. A relay that errors, 404s or says disabled gives
/// an empty list: the page then reads "Nothing here yet".
@immutable
class FeedState {
  const FeedState({
    this.items = const <FeedItem>[],
    this.prompt = '',
    this.topics,
    this.savingTopics = false,
    this.loading = false,
    this.loaded = false,
  });

  final List<FeedItem> items;
  final String prompt;

  /// The interests as the relay holds them; null when the relay does not send
  /// them, then only [prompt] is shown, read only.
  final List<String>? topics;

  /// A topic change is on its way to the relay; another waits for it.
  final bool savingTopics;
  final bool loading;

  /// A load has finished at least once (well or not).
  final bool loaded;

  FeedState copyWith({
    List<FeedItem>? items,
    String? prompt,
    List<String>? topics,
    bool? savingTopics,
    bool? loading,
    bool? loaded,
  }) => FeedState(
    items: items ?? this.items,
    prompt: prompt ?? this.prompt,
    topics: topics ?? this.topics,
    savingTopics: savingTopics ?? this.savingTopics,
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
        : FeedState(
            items: data.items,
            prompt: data.prompt,
            topics: data.topics,
            savingTopics: state.savingTopics,
            loaded: true,
          );
  }

  /// Interests the relay accepts at most.
  static const int maxTopics = 6;

  /// Adds [raw] as an interest. The relay's answer is the list afterwards.
  Future<TopicOutcome> addTopic(String raw) {
    final topic = raw.trim();
    final current = state.topics;
    if (topic.isEmpty || current == null) {
      return Future.value(TopicOutcome.same);
    }
    if (current.any((t) => t.toLowerCase() == topic.toLowerCase())) {
      return Future.value(TopicOutcome.same);
    }
    if (current.length >= maxTopics) return Future.value(TopicOutcome.full);
    return _saveTopics([...current, topic]);
  }

  Future<TopicOutcome> removeTopic(String topic) {
    final current = state.topics;
    if (current == null || !current.contains(topic)) {
      return Future.value(TopicOutcome.same);
    }
    return _saveTopics([
      for (final t in current)
        if (t != topic) t,
    ]);
  }

  Future<TopicOutcome> _saveTopics(List<String> next) async {
    // One request at a time: a second tap while one is out does nothing.
    if (state.savingTopics) return TopicOutcome.busy;
    state = state.copyWith(savingTopics: true);
    TopicsResult result;
    try {
      result =
          await ref.read(museyFeedApiProvider)?.setFeedTopics(next) ??
          const TopicsResult.failed();
    } catch (_) {
      result = const TopicsResult.failed();
    }
    if (!ref.mounted) return TopicOutcome.failed;
    final saved = result.topics;
    state = state.copyWith(savingTopics: false, topics: saved);
    return saved != null ? TopicOutcome.saved : TopicOutcome.failed;
  }

  /// Takes [id] off the list at once; when the relay fails (not a 404, which
  /// means it is gone already) the card goes back where it was. True when it
  /// stays gone.
  Future<bool> dismissItem(String id) async {
    final index = state.items.indexWhere((i) => i.id == id);
    if (index < 0) return true;
    final item = state.items[index];
    state = state.copyWith(
      items: [
        for (final i in state.items)
          if (i.id != id) i,
      ],
    );
    DismissResult result;
    try {
      result =
          await ref.read(museyFeedApiProvider)?.dismissFeedItem(id) ??
          DismissResult.failed;
    } catch (_) {
      result = DismissResult.failed;
    }
    if (result != DismissResult.failed) return true;
    // Let the list drop the swiped row first: a Dismissible still in the tree
    // when its item returns is an error.
    await SchedulerBinding.instance.endOfFrame;
    if (ref.mounted && !state.items.any((i) => i.id == id)) {
      final items = [...state.items];
      items.insert(index.clamp(0, items.length), item);
      state = state.copyWith(items: items);
    }
    return false;
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

enum TopicOutcome { saved, same, full, busy, failed }

/// Where the guess for the turn now running stands.
enum TurnPhase {
  /// No turn asked (a reply nobody sent from here): show the plain word.
  none,

  /// Asked, no answer yet and still inside the wait: hold a quiet placeholder.
  pending,

  /// Answered inside the wait: [TurnReaction.status] and [emoji] may show.
  ready,

  /// The wait ran out: the plain word shows and a late answer is dropped, so
  /// the line never changes twice.
  gaveUp,
}

/// How long the working line holds its placeholder for the relay's guess.
/// The relay's median is about 140 ms and p90 about 200 ms on the Mac (2026-11-05),
/// so 600 ms covers the network on top and still feels immediate.
const Duration kTurnReactionWait = Duration(milliseconds: 600);

@immutable
class TurnReaction {
  const TurnReaction({this.phase = TurnPhase.none, this.status, this.emoji});
  final TurnPhase phase;
  final String? status;
  final String? emoji;
}

/// A status is 1 to 3 plain words, so the working line stays short. The relay
/// already checks this; the app does not trust a server that may be older.
String? cleanTurnStatus(String? raw) {
  final t = raw?.trim();
  if (t == null || t.isEmpty || t.length > 32) return null;
  if (!RegExp(r"^[A-Za-z]+(?: [A-Za-z']+){0,2}$").hasMatch(t)) return null;
  return t;
}

/// The status words (and optional emoji) the relay picked for the turn now
/// running, shown in place of the working word at the top of the chat. Only
/// the newest request counts: a late answer for an older message is dropped.
final turnReactionProvider =
    NotifierProvider<TurnReactionController, TurnReaction>(
      TurnReactionController.new,
    );

class TurnReactionController extends Notifier<TurnReaction> {
  int _turn = 0;
  Timer? _limit;

  @override
  TurnReaction build() {
    ref.onDispose(() => _limit?.cancel());
    return const TurnReaction();
  }

  /// Starts a turn for [text]: clears the last guess and asks the relay once.
  /// Never throws and never waits for the caller.
  void request(String text) {
    final turn = ++_turn;
    _limit?.cancel();
    state = const TurnReaction(phase: TurnPhase.pending);
    _limit = Timer(kTurnReactionWait, () {
      if (turn == _turn && state.phase == TurnPhase.pending) {
        state = const TurnReaction(phase: TurnPhase.gaveUp);
      }
    });
    unawaited(_ask(turn, text));
  }

  /// A send that never went out ends its turn with nothing shown.
  void cancel() {
    _turn++;
    _limit?.cancel();
    state = const TurnReaction();
  }

  Future<void> _ask(int turn, String text) async {
    TurnHint? hint;
    try {
      hint = await ref
          .read(museyFeedApiProvider)
          ?.react(text)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      hint = null;
    }
    if (!ref.mounted || turn != _turn) return;
    // Past the wait the line already says the plain word: no second change.
    if (state.phase != TurnPhase.pending) return;
    _limit?.cancel();
    final e = hint?.emoji?.trim();
    // A single emoji is short; anything long is not one.
    final emoji = (e == null || e.isEmpty || e.length > 16) ? null : e;
    state = TurnReaction(
      phase: TurnPhase.ready,
      status: cleanTurnStatus(hint?.status),
      emoji: emoji,
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
