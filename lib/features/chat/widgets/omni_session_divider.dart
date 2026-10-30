import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

/// [child] with the Omni session divider above it when message [messageId]
/// started a session. The transcript's first row never gets one.
class OmniSessionDividerGate extends ConsumerWidget {
  const OmniSessionDividerGate({
    super.key,
    required this.messageId,
    required this.child,
    this.timestamp,
    this.now,
  });

  final String messageId;
  final Widget child;

  /// When message [messageId] was sent; without it no divider is drawn.
  final DateTime? timestamp;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startsSession = ref.watch(
      omniSessionProvider.select(
        (session) => session.boundaries.contains(messageId),
      ),
    );
    final start = timestamp;
    if (!startsSession || start == null) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OmniSessionDivider(start: start, now: now),
        child,
      ],
    );
  }
}

/// The label of a session that began at [start]: the time alone today, else
/// the ISO date, a comma and the time ("2026-10-12, 3:26 PM"). [locale] picks
/// the time format.
String omniSessionTimeLabel(DateTime start, DateTime now, String locale) {
  final time = DateFormat.jm(locale).format(start);
  final sameDay =
      start.year == now.year &&
      start.month == now.month &&
      start.day == now.day;
  if (sameDay) return time;
  return '${DateFormat('yyyy-MM-dd').format(start)}, $time';
}

/// A small centered muted timestamp where a new Omni session begins.
class OmniSessionDivider extends StatelessWidget {
  const OmniSessionDivider({super.key, required this.start, this.now});

  /// When the first message of the session was sent.
  final DateTime start;

  /// The clock, for tests; defaults to the current time.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = omniSessionTimeLabel(
      start,
      now ?? DateTime.now(),
      Localizations.localeOf(context).toString(),
    );
    return Semantics(
      label: '${l10n.omniSessionDividerLabel}, $label',
      container: true,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: context.conduitTheme.textSecondary.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}
