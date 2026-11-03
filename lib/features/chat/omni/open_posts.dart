import 'dart:async';

import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/message_bubble_colors.dart';
import 'message_jump.dart';

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

/// Opacity of the glow around an open post, at rest. The breathing takes it
/// down to [kOpenPostGlowLow] of this and back.
const double kOpenPostGlowLight = 0.09;
const double kOpenPostGlowDark = 0.12;

/// The lowest point of the breathing, as a share of the glow's opacity.
const double kOpenPostGlowLow = 0.75;

/// Blur radius of the glow, in logical pixels.
const double kOpenPostGlowBlur = 10;

/// Opacity and width of the hairline on the message's own outline.
const double kOpenPostGlowBorderAlpha = 0.06;
const double kOpenPostGlowBorderWidth = 1;

/// One breath, low to high and back, takes this long (3.6 s).
const Duration kOpenPostGlowCycle = Duration(milliseconds: 3600);

/// How long the glow takes to come on or go out.
const Duration kOpenPostGlowFade = Duration(milliseconds: 400);

/// A soft glow around [child]'s own bounds (a bubble or a text block, never
/// the row) while the post [messageId] is open, in the persona's accent. It
/// goes out when the post is answered. It only paints around the child; the
/// message itself is never changed.
///
/// With [hug] the child is shrunk to its content width first and the glow
/// sits a little outside it, for text that has no bubble.
class OpenPostGlow extends ConsumerWidget {
  const OpenPostGlow({
    super.key,
    required this.messageId,
    required this.radius,
    required this.child,
    this.hug = false,
  });

  final String messageId;
  final double radius;
  final bool hug;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(
      openPostsProvider.select((ids) => ids.contains(messageId)),
    );
    // A message a notification tap just jumped to glows for a moment too.
    final jumped = ref.watch(
      highlightedMessageProvider.select((id) => id == messageId),
    );
    final on = open || jumped;
    final theme = context.conduitTheme;
    final accent =
        ref.watch(messageBubbleAccentProvider) ?? theme.buttonPrimary;
    return OpenPostGlowFrame(
      glowing: on,
      accent: accent,
      dark: theme.isDark,
      radius: radius,
      hug: hug,
      child: child,
    );
  }
}

/// The painting half of [OpenPostGlow], with the state passed in.
class OpenPostGlowFrame extends StatefulWidget {
  const OpenPostGlowFrame({
    super.key,
    required this.glowing,
    required this.accent,
    required this.dark,
    required this.radius,
    required this.child,
    this.hug = false,
  });

  final bool glowing;
  final Color accent;
  final bool dark;
  final double radius;
  final bool hug;
  final Widget child;

  @override
  State<OpenPostGlowFrame> createState() => _OpenPostGlowFrameState();
}

class _OpenPostGlowFrameState extends State<OpenPostGlowFrame>
    with TickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: kOpenPostGlowFade,
    value: widget.glowing ? 1 : 0,
  );
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: kOpenPostGlowCycle,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(OpenPostGlowFrame old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.glowing) {
      if (_reduceMotion) {
        _fade.value = 1;
      } else if (_fade.status != AnimationStatus.forward) {
        _fade.forward();
      }
    } else {
      if (_reduceMotion) {
        _fade.value = 0;
      } else if (_fade.status != AnimationStatus.reverse) {
        _fade.reverse();
      }
    }
    final breathe = widget.glowing && !_reduceMotion;
    if (breathe && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!breathe && _breath.isAnimating) {
      _breath.stop();
      _breath.value = 0;
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _breath.dispose();
    super.dispose();
  }

  /// The glow's opacity share now: 1 at the top of a breath, down to
  /// [kOpenPostGlowLow] at the bottom.
  double get _level =>
      _fade.value *
      (1 - (1 - kOpenPostGlowLow) * Curves.easeInOut.transform(_breath.value));

  @override
  Widget build(BuildContext context) {
    Widget child = widget.child;
    if (widget.hug && widget.glowing) {
      child = Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: IntrinsicWidth(child: child),
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([_fade, _breath]),
      child: child,
      builder: (context, child) => CustomPaint(
        foregroundPainter: _level <= 0
            ? null
            : _GlowPainter(
                color: widget.accent,
                glowAlpha: widget.dark ? kOpenPostGlowDark : kOpenPostGlowLight,
                level: _level,
                fadeShare: _fade.value,
                radius: widget.radius,
                outset: widget.hug ? 6 : 0,
                textDirection: Directionality.of(context),
              ),
        child: child,
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.color,
    required this.glowAlpha,
    required this.level,
    required this.fadeShare,
    required this.radius,
    required this.outset,
    required this.textDirection,
  });

  final Color color;
  final double glowAlpha;
  final double level;
  final double fadeShare;
  final double radius;
  final double outset;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(
      (Offset.zero & size).inflate(outset),
      Radius.circular(radius + outset),
    );
    // The glow lives outside the outline only: the interior stays the
    // message's own.
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(shape.outerRect.inflate(kOpenPostGlowBlur * 4)),
      Path()..addRRect(shape),
    );
    canvas.save();
    canvas.clipPath(outside);
    canvas.drawRRect(
      shape,
      Paint()
        ..color = color.withValues(alpha: glowAlpha * level)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, kOpenPostGlowBlur / 2),
    );
    canvas.restore();
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kOpenPostGlowBorderWidth
        ..color = color.withValues(alpha: kOpenPostGlowBorderAlpha * fadeShare),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.color != color ||
      old.glowAlpha != glowAlpha ||
      old.level != level ||
      old.fadeShare != fadeShare ||
      old.radius != radius ||
      old.outset != outset;
}
