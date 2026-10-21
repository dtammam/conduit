import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../theme/theme_extensions.dart';
import '../../assistant_detail_header.dart';

/// Whether the tool rows above a reply read "Used tools" instead of naming
/// each tool (the "Compact tool summaries" setting). Read where the row is
/// built so the chat and the status timeline agree.
bool compactToolSummariesOf(WidgetRef ref) => ref.watch(
  appSettingsProvider.select((settings) => settings.compactToolSummaries),
);

/// The title of a group of [count] tool calls: the tool names joined in
/// [summary], or the compact "Used tools" form.
String toolCallGroupTitle(
  AppLocalizations l10n, {
  required String summary,
  required int count,
  required bool isPending,
  required bool compact,
}) {
  if (compact) {
    return isPending
        ? l10n.markdownDetailsGroupCompactPendingTitle
        : l10n.markdownDetailsGroupCompactCompleteTitle(count);
  }
  return isPending
      ? l10n.markdownDetailsGroupPendingTitle(summary)
      : l10n.markdownDetailsGroupCompleteTitle(summary);
}

enum MarkdownDetailsGroupRenderMode { details, previewsOnly }

class MarkdownDetailsGroupRenderScope extends InheritedWidget {
  const MarkdownDetailsGroupRenderScope({
    super.key,
    required this.mode,
    required super.child,
  });

  final MarkdownDetailsGroupRenderMode mode;

  static MarkdownDetailsGroupRenderMode? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MarkdownDetailsGroupRenderScope>()
          ?.mode;

  @override
  bool updateShouldNotify(MarkdownDetailsGroupRenderScope oldWidget) =>
      mode != oldWidget.mode;
}

class MarkdownDetailsGroupItem {
  const MarkdownDetailsGroupItem({
    required this.type,
    required this.childBuilder,
    this.name = '',
    this.isDone = true,
  });

  final String type;
  final String name;
  final bool isDone;
  final WidgetBuilder childBuilder;
}

class MarkdownDetailsGroup extends StatefulWidget {
  const MarkdownDetailsGroup({super.key, required this.items, this.stateId});

  final List<MarkdownDetailsGroupItem> items;
  final String? stateId;

  @override
  State<MarkdownDetailsGroup> createState() => _MarkdownDetailsGroupState();
}

class _MarkdownDetailsGroupState extends State<MarkdownDetailsGroup> {
  var _isExpanded = false;
  String? _restoredStateId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restoreExpansionStateIfNeeded();
  }

  @override
  void didUpdateWidget(covariant MarkdownDetailsGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stateId != widget.stateId) {
      _restoredStateId = null;
      _restoreExpansionStateIfNeeded();
    }
  }

  bool get _hasPending => widget.items.any((item) => !item.isDone);

  void _restoreExpansionStateIfNeeded() {
    final stateId = widget.stateId;
    if (stateId == null || _restoredStateId == stateId) {
      return;
    }

    final restored = PageStorage.maybeOf(context)
        ?.readState(context, identifier: stateId);
    if (restored is bool) {
      _isExpanded = restored;
    }
    _restoredStateId = stateId;
  }

  void _persistExpansionState() {
    final stateId = widget.stateId;
    if (stateId == null) {
      return;
    }
    PageStorage.maybeOf(context)
        ?.writeState(context, _isExpanded, identifier: stateId);
  }

  String _buildSummaryText() {
    final l10n = AppLocalizations.of(context)!;
    final toolNameCounts = <String, int>{};

    for (final item in widget.items) {
      final name = item.name.trim().isEmpty
          ? l10n.markdownDetailsGroupUnnamedTool
          : item.name.trim();
      toolNameCounts[name] = (toolNameCounts[name] ?? 0) + 1;
    }

    final parts = toolNameCounts.entries
        .map(
          (entry) =>
              entry.value > 1 ? '${entry.key} (${entry.value})' : entry.key,
        )
        .toList(growable: false);

    return parts.join(', ');
  }

  String _buildTitle({required bool compact}) {
    final l10n = AppLocalizations.of(context)!;
    return toolCallGroupTitle(
      l10n,
      summary: _buildSummaryText(),
      count: widget.items.length,
      isPending: _hasPending,
      compact: compact,
    ).trim();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) =>
          _buildGroup(context, compact: compactToolSummariesOf(ref)),
    );
  }

  Widget _buildGroup(BuildContext context, {required bool compact}) {
    final theme = context.conduitTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
              _persistExpansionState();
            },
            child: AssistantDetailHeader(
              title: _buildTitle(compact: compact),
              showShimmer: _hasPending,
              showChevron: true,
              allowWrap: true,
              useInlineChevron: true,
              isExpanded: _isExpanded,
            ),
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs, left: Spacing.sm),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.28),
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: Spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.items
                        .map(
                          (item) => MarkdownDetailsGroupRenderScope(
                            mode: MarkdownDetailsGroupRenderMode.details,
                            child: Builder(builder: item.childBuilder),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
            ),
          MarkdownDetailsGroupRenderScope(
            mode: MarkdownDetailsGroupRenderMode.previewsOnly,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.items
                  .map((item) => Builder(builder: item.childBuilder))
                  .toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }
}
