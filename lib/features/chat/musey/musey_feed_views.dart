import 'dart:async';
import 'dart:typed_data';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/external_link_launcher.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'musey_feed_api.dart';
import 'musey_feed_providers.dart';

/// A short relative time: "now", "5m", "3h", "2d", then the date.
String museyRelativeTime(DateTime at, DateTime now) {
  final diff = now.difference(at);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}

/// The relay path an image [src] points at, or null when it is another site.
String? museyRelayPath(String src) {
  if (src.startsWith('/')) return src;
  final uri = Uri.tryParse(src);
  if (uri == null || !uri.path.startsWith('/musey/')) return null;
  return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
}

/// An image from the relay (cached on disk) or the web, with [fallback] while
/// it loads and when it is missing.
class MuseyImage extends ConsumerStatefulWidget {
  const MuseyImage({
    super.key,
    required this.src,
    required this.fallback,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String src;
  final Widget fallback;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  ConsumerState<MuseyImage> createState() => _MuseyImageState();
}

class _MuseyImageState extends ConsumerState<MuseyImage> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MuseyImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) _start();
  }

  void _start() {
    final path = museyRelayPath(widget.src);
    _bytes = path == null
        ? null
        : ref.read(museyAssetCacheProvider).bytes(path);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      final uri = Uri.tryParse(widget.src);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return widget.fallback;
      }
      return Image.network(
        widget.src,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return widget.fallback;
        return Image.memory(
          data,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.fallback,
        );
      },
    );
  }
}

/// A named icon of the relay's set (`/musey/icons/<name>.png`), with a
/// built-in glyph when it is not there.
class MuseyIcon extends StatelessWidget {
  const MuseyIcon({
    super.key,
    required this.name,
    required this.fallbackSymbol,
    this.size = 40,
  });

  final String? name;
  final String fallbackSymbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final fallback = SizedBox(
      width: size,
      height: size,
      child: Icon(
        cupertinoIconForSFSymbol(fallbackSymbol),
        size: size * 0.7,
        color: theme.textSecondary,
      ),
    );
    final n = name;
    if (n == null || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(n)) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox(
        width: size,
        height: size,
        child: MuseyImage(
          key: ValueKey('musey-icon-$n'),
          src: '/musey/icons/$n.png',
          width: size,
          height: size,
          fallback: fallback,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xxl),
      child: Text(
        l10n.museyNothingHere,
        key: const ValueKey('musey-empty'),
        textAlign: TextAlign.center,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      Container(height: 0.5, color: context.conduitTheme.dividerColor);
}

/// The Feed page content: the interests box, then the items.
class FeedTab extends ConsumerStatefulWidget {
  const FeedTab({super.key, required this.onDiscuss});

  /// Switches to the chat and sends [text] there.
  final void Function(String text) onDiscuss;

  @override
  ConsumerState<FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends ConsumerState<FeedTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(feedProvider.notifier).load());
    });
  }

  Future<void> _dismiss(String id) async {
    final l10n = AppLocalizations.of(context)!;
    final stays = await ref.read(feedProvider.notifier).dismissItem(id);
    if (!stays && mounted) {
      AdaptiveSnackBar.show(
        context,
        message: l10n.museyFeedDismissFailed,
        type: AdaptiveSnackBarType.info,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(feedProvider);
    final theme = context.conduitTheme;
    return ConduitRefreshIndicator(
      onRefresh: () => ref.read(feedProvider.notifier).load(),
      child: ListView(
        key: const ValueKey('musey-feed-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: Spacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.md),
            child: _Interests(state: state),
          ),
          if (state.loaded && state.items.isEmpty) const _Empty(),
          for (final item in state.items) ...[
            const _Divider(),
            Dismissible(
              key: ValueKey('musey-feed-dismiss-${item.id}'),
              // Right to left only: the left edge stays the back swipe, and
              // the list's own vertical drag wins over a mostly vertical one.
              direction: DismissDirection.endToStart,
              onDismissed: (_) => unawaited(_dismiss(item.id)),
              background: Container(color: theme.surfaceContainer),
              child: _FeedRow(item: item, onDiscuss: widget.onDiscuss),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Feed's interests: one removable chip each and a field that adds one.
/// Each change saves at once and the relay's list is what shows. An older
/// relay that sends no list gets the old prompt as one read-only line.
class _Interests extends ConsumerStatefulWidget {
  const _Interests({required this.state});

  final FeedState state;

  @override
  ConsumerState<_Interests> createState() => _InterestsState();
}

class _InterestsState extends ConsumerState<_Interests> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _say(String message) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.info,
    );
  }

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _controller.text;
    final outcome = await ref.read(feedProvider.notifier).addTopic(text);
    if (!mounted) return;
    switch (outcome) {
      case TopicOutcome.saved:
        _controller.clear();
      case TopicOutcome.failed:
        _say(l10n.museyFeedPromptFailed);
      case TopicOutcome.full:
        _say(l10n.museyFeedTopicsFull);
      case TopicOutcome.same:
        // A repeat or an empty field: nothing to save.
        if (text.trim().isNotEmpty) _controller.clear();
      case TopicOutcome.busy:
        break;
    }
  }

  Future<void> _remove(String topic) async {
    final l10n = AppLocalizations.of(context)!;
    final outcome = await ref.read(feedProvider.notifier).removeTopic(topic);
    if (!mounted) return;
    if (outcome == TopicOutcome.failed) _say(l10n.museyFeedPromptFailed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final topics = widget.state.topics;
    final box = BoxDecoration(
      color: theme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
    );
    if (topics == null) {
      final prompt = widget.state.prompt;
      return Container(
        key: const ValueKey('musey-feed-prompt'),
        padding: const EdgeInsets.all(Spacing.md),
        decoration: box,
        child: Row(
          children: [
            Icon(
              cupertinoIconForSFSymbol('magnifyingglass'),
              size: IconSize.sm,
              color: theme.textSecondary,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                prompt.isEmpty ? l10n.museyFeedPromptHint : prompt,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: prompt.isEmpty
                      ? theme.textSecondary
                      : theme.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final full = topics.length >= FeedController.maxTopics;
    final saving = widget.state.savingTopics;
    return Container(
      key: const ValueKey('musey-feed-topics'),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: box,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (topics.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  for (final topic in topics)
                    GestureDetector(
                      key: ValueKey('musey-feed-topic-$topic'),
                      behavior: HitTestBehavior.opaque,
                      onTap: saving ? null : () => unawaited(_remove(topic)),
                      child: Semantics(
                        button: true,
                        label: l10n.museyFeedRemoveTopic(topic),
                        excludeSemantics: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.sm,
                            vertical: Spacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color: theme.surfaceBackground,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.bodyMediumStyle.copyWith(
                                    color: theme.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: Spacing.xs),
                              Icon(
                                cupertinoIconForSFSymbol('xmark'),
                                size: IconSize.xs,
                                color: theme.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (full)
            Text(
              l10n.museyFeedTopicsFull,
              key: const ValueKey('musey-feed-topics-full'),
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            )
          else
            Row(
              children: [
                Icon(
                  cupertinoIconForSFSymbol('plus'),
                  size: IconSize.sm,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: AdaptiveTextField(
                    key: const ValueKey('musey-feed-topic-field'),
                    controller: _controller,
                    placeholder: l10n.museyFeedAddTopicHint,
                    textInputAction: TextInputAction.done,
                    maxLength: 60,
                    enabled: !saving,
                    onSubmitted: (_) => unawaited(_add()),
                  ),
                ),
                AdaptiveButton(
                  key: const ValueKey('musey-feed-topic-add'),
                  onPressed: saving ? null : () => unawaited(_add()),
                  label: l10n.museyFeedAdd,
                  style: AdaptiveButtonStyle.tinted,
                  size: AdaptiveButtonSize.small,
                  useNative: false,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _FeedRow extends ConsumerStatefulWidget {
  const _FeedRow({required this.item, required this.onDiscuss});

  final FeedItem item;
  final void Function(String text) onDiscuss;

  @override
  ConsumerState<_FeedRow> createState() => _FeedRowState();
}

class _FeedRowState extends ConsumerState<_FeedRow> {
  bool _info = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final domain = item.domain;
    final image = item.imageUrl;
    return Padding(
      key: ValueKey('musey-feed-item-${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MuseyIcon(name: item.icon, fallbackSymbol: 'newspaper', size: 40),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (item.body != null) ...[
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    item.body!,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
                if (item.url != null) ...[
                  const SizedBox(height: Spacing.xs),
                  GestureDetector(
                    key: ValueKey('musey-feed-link-${item.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(
                      launchExternalLink(item.url!, scope: 'musey/feed'),
                    ),
                    child: Text(
                      item.source ?? domain ?? item.url!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.buttonPrimary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
                if (image != null) ...[
                  const SizedBox(height: Spacing.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: SizedBox(
                        width: double.infinity,
                        child: MuseyImage(
                          key: ValueKey('musey-feed-image-${item.id}'),
                          src: image,
                          fallback: const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.sm),
                Row(
                  children: [
                    GestureDetector(
                      key: ValueKey('musey-feed-like-${item.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(
                        ref.read(feedProvider.notifier).toggleLike(item.id),
                      ),
                      child: Semantics(
                        button: true,
                        label: l10n.museyLike,
                        selected: item.liked,
                        excludeSemantics: true,
                        child: Padding(
                          padding: const EdgeInsets.all(Spacing.xs),
                          child: Icon(
                            cupertinoIconForSFSymbol(
                              item.liked ? 'heart.fill' : 'heart',
                            ),
                            size: IconSize.md,
                            color: item.liked
                                ? theme.error
                                : theme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.xs),
                    AdaptiveButton(
                      key: ValueKey('musey-feed-discuss-${item.id}'),
                      onPressed: () => widget.onDiscuss(item.discussText),
                      label: l10n.museyDiscuss,
                      style: AdaptiveButtonStyle.tinted,
                      size: AdaptiveButtonSize.small,
                      useNative: false,
                    ),
                    const Spacer(),
                    if (item.at != null)
                      Text(
                        museyRelativeTime(item.at!, DateTime.now()),
                        style: AppTypography.captionStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    if (domain != null)
                      GestureDetector(
                        key: ValueKey('musey-feed-info-${item.id}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _info = !_info),
                        child: Padding(
                          padding: const EdgeInsets.all(Spacing.xs),
                          child: Icon(
                            cupertinoIconForSFSymbol('info.circle'),
                            size: IconSize.md,
                            color: theme.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
                if (_info && domain != null)
                  Text(
                    l10n.museyInfoSource(domain),
                    key: ValueKey('musey-feed-info-text-${item.id}'),
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Ideas page content.
class IdeasTab extends ConsumerStatefulWidget {
  const IdeasTab({super.key, required this.onOpen});

  /// Switches to the chat and sends [text] there.
  final void Function(String text) onOpen;

  @override
  ConsumerState<IdeasTab> createState() => _IdeasTabState();
}

class _IdeasTabState extends ConsumerState<IdeasTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(ideasProvider.notifier).load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ideasProvider);
    final theme = context.conduitTheme;
    return ConduitRefreshIndicator(
      onRefresh: () => ref.read(ideasProvider.notifier).load(),
      child: ListView(
        key: const ValueKey('musey-ideas-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: Spacing.xl),
        children: [
          if (state.loaded && state.items.isEmpty) const _Empty(),
          for (final idea in state.items) ...[
            const _Divider(),
            Dismissible(
              key: ValueKey('musey-idea-dismiss-${idea.id}'),
              direction: DismissDirection.endToStart,
              onDismissed: (_) =>
                  unawaited(ref.read(ideasProvider.notifier).dismiss(idea.id)),
              background: Container(color: theme.surfaceContainer),
              child: GestureDetector(
                key: ValueKey('musey-idea-${idea.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onOpen(idea.sendText),
                onLongPress: () => unawaited(
                  ref.read(ideasProvider.notifier).dismiss(idea.id),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MuseyIcon(
                        name: idea.icon,
                        fallbackSymbol: 'lightbulb',
                        size: 40,
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              idea.title,
                              style: AppTypography.bodyLargeStyle.copyWith(
                                color: theme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (idea.body != null) ...[
                              const SizedBox(height: Spacing.xxs),
                              Text(
                                idea.body!,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.bodyMediumStyle.copyWith(
                                  color: theme.textSecondary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One row of the More page.
class MoreRow extends StatelessWidget {
  const MoreRow({
    super.key,
    required this.symbol,
    required this.label,
    required this.hint,
    required this.onTap,
    this.badgeColor,
  });

  final String symbol;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  cupertinoIconForSFSymbol(symbol),
                  size: IconSize.lg,
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTypography.bodyLargeStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      hint,
                      style: AppTypography.bodyMediumStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (badgeColor != null)
                Container(
                  key: ValueKey('musey-more-badge-$label'),
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: Spacing.sm),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    shape: BoxShape.circle,
                  ),
                ),
              Icon(
                cupertinoIconForSFSymbol('chevron.right'),
                size: IconSize.sm,
                color: theme.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hairline between rows.
class MuseyDivider extends StatelessWidget {
  const MuseyDivider({super.key});

  @override
  Widget build(BuildContext context) => const _Divider();
}
