import 'dart:async';

import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/external_link_launcher.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../musey/musey_feed_api.dart';
import '../musey/musey_feed_views.dart';

/// The most cards one message shows.
const int kMaxLinkCards = 3;

final RegExp _detailsBlock = RegExp(
  r'<details\b[^>]*>.*?</details>',
  dotAll: true,
  caseSensitive: false,
);
final RegExp _fence = RegExp(r'```.*?(```|$)', dotAll: true);
final RegExp _inlineCode = RegExp(r'`[^`\n]*`');
final RegExp _mdLink = RegExp(
  r'(?<!!)\[[^\]\n]*\]\((<?)(https?://[^)\s>]+)>?\)',
);
final RegExp _bareUrl = RegExp(
  r'https?://[^\s<>()\[\]"]+',
  caseSensitive: false,
);

/// The http(s) links of an assistant message worth a card: plain URLs and
/// markdown link targets in its text, in order, without repeats, at most
/// [kMaxLinkCards]. Tool output blocks and code are not looked at, and an
/// image is not a link.
List<String> extractPreviewUrls(String content) {
  if (!content.contains('http')) return const [];
  var text = content
      .replaceAll(_detailsBlock, ' ')
      .replaceAll(_fence, ' ')
      .replaceAll(_inlineCode, ' ');
  final found = <String>[];
  void add(String raw) {
    var url = raw;
    // A sentence's own punctuation is not part of a bare link.
    while (url.isNotEmpty && '.,;:!?\'"'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return;
    if (!found.contains(url)) found.add(url);
  }

  // Markdown links first, so their targets are not read twice as bare URLs.
  for (final m in _mdLink.allMatches(text)) {
    add(m.group(2)!);
  }
  text = text.replaceAll(_mdLink, ' ');
  text = text.replaceAll(RegExp(r'!\[[^\]\n]*\]\([^)\n]*\)'), ' ');
  for (final m in _bareUrl.allMatches(text)) {
    add(m.group(0)!);
  }
  return found.take(kMaxLinkCards).toList(growable: false);
}

/// Small cards under a finished assistant message, one per link, from the
/// relay's link preview. A link with no preview shows nothing, so the message
/// reads exactly as it did. Built only for a message that is not streaming.
class LinkPreviewCards extends StatelessWidget {
  const LinkPreviewCards({super.key, required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final url in urls) _LinkCard(key: ValueKey(url), url: url),
      ],
    );
  }
}

class _LinkCard extends ConsumerStatefulWidget {
  const _LinkCard({super.key, required this.url});

  final String url;

  @override
  ConsumerState<_LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends ConsumerState<_LinkCard> {
  LinkPreview? _preview;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    LinkPreview? preview;
    try {
      preview = await ref.read(museyAssetCacheProvider).preview(widget.url);
    } catch (_) {
      preview = null;
    }
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (!_done || preview == null) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final image = preview.imageUrl;
    final domain = preview.domain ?? Uri.tryParse(widget.url)?.host;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: GestureDetector(
        key: ValueKey('link-card-${widget.url}'),
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            unawaited(launchExternalLink(widget.url, scope: 'chat/link-card')),
        child: Container(
          decoration: BoxDecoration(
            color: theme.surfaceContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              if (image != null)
                SizedBox(
                  width: 72,
                  height: 72,
                  child: MuseyImage(
                    src: image,
                    width: 72,
                    height: 72,
                    fallback: const SizedBox.shrink(),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md,
                    vertical: Spacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (preview.title != null)
                        Text(
                          preview.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyMediumStyle.copyWith(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (domain != null)
                        Text(
                          domain,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
