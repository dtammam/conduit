import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../musey/musey_feed_views.dart' show MuseyImage;

/// A page the reply's web tools found or opened. It comes only from a tool
/// result, never from text the model wrote.
class WebSource {
  const WebSource({
    required this.url,
    required this.title,
    this.snippet,
    this.query,
    this.opened = false,
  });

  final String url;
  final String title;

  /// The snippet the search gave for this page.
  final String? snippet;

  /// The search query that returned it (the first one, when several did).
  final String? query;

  /// A `fetch_url` call read this page.
  final bool opened;

  /// The short site name: host without a leading "www.".
  String get domain {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  @override
  bool operator ==(Object other) =>
      other is WebSource &&
      other.url == url &&
      other.title == title &&
      other.snippet == snippet &&
      other.query == query &&
      other.opened == opened;

  @override
  int get hashCode => Object.hash(url, title, snippet, query, opened);
}

/// Icons on the control; the sheet lists every source.
const int kSourceIconLimit = 4;

/// The site's own icon from the relay (`/musey/favicon`, so the phone never
/// asks a third-party icon service), or a letter in a neutral circle while it
/// loads, when the site has none, and on an old relay. Never a broken image.
class SourceFavicon extends StatelessWidget {
  const SourceFavicon({super.key, required this.domain, this.size = 16});

  final String domain;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final letter = domain.isEmpty ? '?' : domain.substring(0, 1).toUpperCase();
    final fallback = Container(
      key: ValueKey<String>('source-letter-$domain'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.surfaceContainerHighest,
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.58,
          height: 1.0,
          fontWeight: FontWeight.w600,
          color: theme.textSecondary,
        ),
      ),
    );
    if (domain.isEmpty) return fallback;
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: MuseyImage(
          key: ValueKey<String>('source-icon-$domain'),
          src: '/musey/favicon?domain=${Uri.encodeQueryComponent(domain)}',
          width: size,
          height: size,
          fallback: fallback,
        ),
      ),
    );
  }
}

/// One compact line under the web step: the word "Sources" and up to
/// [kSourceIconLimit] small overlapping icons (+N for the rest). It is one
/// short line, never scrolls and does not widen the bubble. Tap opens the
/// list ([showWebSourcesSheet]).
class WebSourcesControl extends StatelessWidget {
  const WebSourcesControl({super.key, required this.sources, this.onOpen});

  final List<WebSource> sources;

  /// Opens a URL; a test replaces it. Defaults to the system browser.
  final void Function(String url)? onOpen;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final s in sources)
        if (s.domain.isNotEmpty) s,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final muted = theme.textSecondary.withValues(alpha: 0.85);
    const icon = 16.0, step = 11.0;
    final icons = shown.take(kSourceIconLimit).toList();
    final more = shown.length - icons.length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          label:
              'Sources, ${shown.length} '
              '${shown.length == 1 ? 'site' : 'sites'}. Tap to list them',
          excludeSemantics: true,
          child: GestureDetector(
            key: const ValueKey<String>('web-sources-control'),
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                unawaited(showWebSourcesSheet(context, shown, onOpen: onOpen)),
            child: SizedBox(
              height: 22,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Sources',
                    style: TextStyle(fontSize: 11, height: 1.1, color: muted),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: icon + step * (icons.length - 1),
                    height: icon,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var i = 0; i < icons.length; i++)
                          Positioned(
                            left: i * step,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.surfaceBackground,
                                  width: 1.5,
                                ),
                              ),
                              child: SourceFavicon(
                                domain: icons[i].domain,
                                size: icon,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (more > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '+$more',
                      key: const ValueKey<String>('web-sources-more'),
                      style: TextStyle(fontSize: 11, height: 1.1, color: muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bottom sheet listing every source, pages that were opened first.
Future<void> showWebSourcesSheet(
  BuildContext context,
  List<WebSource> sources, {
  void Function(String url)? onOpen,
}) {
  return ThemedSheets.showCustom<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => WebSourcesSheet(sources: sources, onOpen: onOpen),
  );
}

class WebSourcesSheet extends StatelessWidget {
  const WebSourcesSheet({super.key, required this.sources, this.onOpen});

  final List<WebSource> sources;
  final void Function(String url)? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return ConduitModalSheetSurface(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  'Sources',
                  key: const ValueKey<String>('web-sources-title'),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: theme.textPrimary,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  key: const ValueKey<String>('web-sources-list'),
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: sources.length,
                  itemBuilder: (context, i) =>
                      _SourceRow(source: sources[i], onOpen: onOpen),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatefulWidget {
  const _SourceRow({required this.source, this.onOpen});

  final WebSource source;
  final void Function(String url)? onOpen;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  bool _expanded = false;

  void _open() {
    try {
      final open = widget.onOpen;
      if (open != null) {
        open(widget.source.url);
      } else {
        launchExternalLink(widget.source.url, scope: 'chat/web-source');
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final s = widget.source;
    final title = s.title.isEmpty ? s.domain : s.title;
    final query = s.query;
    final snippet = s.snippet;
    return Semantics(
      button: true,
      expanded: _expanded,
      label:
          '$title, ${s.domain}${s.opened ? ', opened' : ''}. '
          '${_expanded ? 'Tap to collapse' : 'Tap for details'}',
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey<String>('web-source-row-${s.url}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SourceFavicon(domain: s.domain, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.25,
                            color: theme.textPrimary,
                          ),
                        ),
                        Text(
                          s.domain,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: theme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (s.opened) ...[
                    const SizedBox(width: 8),
                    Container(
                      key: ValueKey<String>('web-source-opened-${s.url}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: theme.surfaceContainerHighest,
                      ),
                      child: Text(
                        'Opened',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.1,
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (_expanded)
                Padding(
                  key: ValueKey<String>('web-source-detail-${s.url}'),
                  padding: const EdgeInsets.only(left: 36, top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (query != null && query.isNotEmpty)
                        Text(
                          'Searched: $query',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                            color: theme.textPrimary,
                          ),
                        ),
                      if (snippet != null && snippet.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            snippet,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              color: theme.textSecondary,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        key: ValueKey<String>('web-source-open-${s.url}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _open,
                        child: Semantics(
                          button: true,
                          link: true,
                          label: 'Open page, ${s.domain}',
                          excludeSemantics: true,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: theme.buttonPrimary,
                            ),
                            child: Text(
                              'Open page',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: theme.buttonPrimaryText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
