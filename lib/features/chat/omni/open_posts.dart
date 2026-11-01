import 'dart:async';

import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/message_bubble_colors.dart';

/// How long after Dean sends a message the posts are asked again, so the relay
/// has recorded the reply.
const Duration kOpenPostsAfterSendDelay = Duration(seconds: 2);

/// How often the posts are asked again while the Omni chat is visible.
const Duration kOpenPostsPollInterval = Duration(seconds: 60);

const Duration _requestTimeout = Duration(seconds: 5);

/// One routine or check-in message the relay posted into the Omni chat
/// (`GET /musey/open-posts`). [messageId] is the Open WebUI history message
/// id, the same id the app gives that message.
@immutable
class OpenPost {
  const OpenPost({
    required this.messageId,
    required this.slug,
    required this.postedAt,
    required this.expectsReply,
    required this.open,
  });

  final String messageId;
  final String slug;
  final DateTime postedAt;
  final bool expectsReply;
  final bool open;
}

/// The posts in a `/musey/open-posts` response. Entries that are malformed
/// are skipped; anything that is not the expected shape gives an empty list.
List<OpenPost> parseOpenPosts(Object? data) {
  if (data is! Map) return const [];
  final posts = data['posts'];
  if (posts is! List) return const [];
  final out = <OpenPost>[];
  for (final entry in posts) {
    if (entry is! Map) continue;
    final id = entry['message_id'];
    final slug = entry['slug'];
    final at = entry['posted_at'];
    if (id is! String || id.isEmpty || slug is! String || at is! String) {
      continue;
    }
    final postedAt = DateTime.tryParse(at);
    if (postedAt == null) continue;
    out.add(
      OpenPost(
        messageId: id,
        slug: slug,
        postedAt: postedAt,
        expectsReply: entry['expects_reply'] == true,
        open: entry['open'] == true,
      ),
    );
  }
  return out;
}

/// The message ids that glow: per routine only the newest post, and only when
/// it expects a reply and is still open. Older unanswered posts of the same
/// routine never glow.
Set<String> highlightedPostIds(Iterable<OpenPost> posts) {
  final newest = <String, OpenPost>{};
  for (final post in posts) {
    final current = newest[post.slug];
    if (current == null || post.postedAt.isAfter(current.postedAt)) {
      newest[post.slug] = post;
    }
  }
  return {
    for (final post in newest.values)
      if (post.expectsReply && post.open) post.messageId,
  };
}

/// The message ids to highlight in the Omni chat, kept for the session. A
/// failed request keeps the last known set.
final openPostsProvider = NotifierProvider<OpenPostsNotifier, Set<String>>(
  OpenPostsNotifier.new,
);

class OpenPostsNotifier extends Notifier<Set<String>> {
  Future<void>? _inFlight;

  @override
  Set<String> build() => const <String>{};

  /// Asks the relay now. Does nothing without a Voice provider or while an
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
      final url = voice.profile.requestBaseUri().replace(
        path: '/musey/open-posts',
        query: '',
        fragment: '',
      );
      final response = await lease.dio.getUri<Object?>(
        url,
        options: Options(
          sendTimeout: _requestTimeout,
          receiveTimeout: _requestTimeout,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) return;
      final data = response.data;
      if (data is! Map || data['posts'] is! List) return;
      final next = highlightedPostIds(parseOpenPosts(data));
      if (ref.mounted && !_sameIds(next, state)) state = next;
    } catch (_) {
      // Keep the last known state.
    } finally {
      lease.release();
    }
  }

  bool _sameIds(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// Keeps [openPostsProvider] current while the Omni chat is on screen: when it
/// opens, when the app comes to the foreground, about 2 s after Dean sends a
/// message, and every 60 s. Draws nothing.
class OpenPostsRefresher extends ConsumerStatefulWidget {
  const OpenPostsRefresher({super.key});

  @override
  ConsumerState<OpenPostsRefresher> createState() => _OpenPostsRefresherState();
}

class _OpenPostsRefresherState extends ConsumerState<OpenPostsRefresher>
    with WidgetsBindingObserver {
  Timer? _poll;
  Timer? _afterSend;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _startPoll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _afterSend?.cancel();
    super.dispose();
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(kOpenPostsPollInterval, (_) => _refresh());
  }

  void _refresh() {
    if (!mounted) return;
    unawaited(ref.read(openPostsProvider.notifier).refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _startPoll();
    } else {
      _poll?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    // A new user message in the chat means Dean just sent something.
    ref.listen<String?>(
      chatMessagesProvider.select((messages) {
        for (var i = messages.length - 1; i >= 0; i--) {
          if (messages[i].role == 'user') return messages[i].id;
        }
        return null;
      }),
      (previous, next) {
        if (next == null || next == previous) return;
        _afterSend?.cancel();
        _afterSend = Timer(kOpenPostsAfterSendDelay, _refresh);
      },
    );
    return const SizedBox.shrink();
  }
}

/// Opacity of the tint behind an open post.
const double kOpenPostTintLight = 0.10;
const double kOpenPostTintDark = 0.16;

/// Opacity of the thin left edge.
const double kOpenPostEdgeAlpha = 0.40;

/// A soft tint (and a thin left edge) behind [child] while [highlighted],
/// in the persona's accent. It fades out when it clears. It only paints
/// behind the child; the message itself is never changed.
class OpenPostHighlight extends ConsumerWidget {
  const OpenPostHighlight({
    super.key,
    required this.messageId,
    required this.child,
  });

  final String messageId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      openPostsProvider.select((ids) => ids.contains(messageId)),
    );
    final theme = context.conduitTheme;
    final accent =
        ref.watch(messageBubbleAccentProvider) ?? theme.buttonPrimary;
    return OpenPostHighlightFrame(
      highlighted: on,
      accent: accent,
      dark: theme.isDark,
      child: child,
    );
  }
}

/// The painting half of [OpenPostHighlight], with the state passed in.
class OpenPostHighlightFrame extends StatelessWidget {
  const OpenPostHighlightFrame({
    super.key,
    required this.highlighted,
    required this.accent,
    required this.dark,
    required this.child,
  });

  final bool highlighted;
  final Color accent;
  final bool dark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tint = accent.withValues(
      alpha: dark ? kOpenPostTintDark : kOpenPostTintLight,
    );
    final edge = accent.withValues(alpha: kOpenPostEdgeAlpha);
    const fade = Duration(milliseconds: 400);
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: fade,
              curve: Curves.easeOut,
              opacity: highlighted ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 8,
          bottom: 8,
          width: 2,
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: fade,
              curve: Curves.easeOut,
              opacity: highlighted ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: edge,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
