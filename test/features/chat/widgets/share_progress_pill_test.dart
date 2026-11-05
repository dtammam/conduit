import 'dart:async';

import 'package:conduit/features/chat/widgets/share_progress_pill.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors how the message widget drives the pill: show at the tap, end it
/// when the share sheet would open, on error, or when the widget goes away.
class _Host extends StatefulWidget {
  const _Host({required this.work, this.onError});
  final Future<void> Function(ShareProgress? progress) work;
  final void Function(Object error)? onError;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  ShareProgress? _progress;

  Future<void> _run() async {
    _progress = ShareProgress.show(context, 'Making the audio…');
    try {
      await widget.work(_progress);
    } catch (e) {
      widget.onError?.call(e);
    } finally {
      _progress?.dismiss();
      _progress = null;
    }
  }

  @override
  void dispose() {
    _progress?.dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: _run, child: const Text('go'));
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(TweakcnThemes.t3Chat),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  const text = 'Making the audio…';

  testWidgets('shows from the tap and clears on success', (tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      _app(
        _Host(
          work: (p) async {
            await gate.future;
          },
        ),
      ),
    );
    expect(find.text(text), findsNothing);
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text(text), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text(text), findsNothing);
  });

  testWidgets('shows an estimate update, then clears on error', (tester) async {
    final gate = Completer<void>();
    Object? seen;
    await tester.pumpWidget(
      _app(
        _Host(
          work: (p) async {
            p?.update('Making the audio, about 40 s');
            await gate.future;
            throw StateError('boom');
          },
          onError: (e) => seen = e,
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('Making the audio, about 40 s'), findsOneWidget);
    expect(find.text(text), findsNothing);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(seen, isA<StateError>());
    expect(find.byType(ShareProgressPill), findsNothing);
  });

  testWidgets('clears when the chat goes away mid-export', (tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(_app(_Host(work: (p) => gate.future)));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.byType(ShareProgressPill), findsOneWidget);
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump();
    expect(find.byType(ShareProgressPill), findsNothing);
    gate.complete();
    await tester.pump();
  });

  testWidgets('does not block taps underneath', (tester) async {
    final gate = Completer<void>();
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            _Host(work: (p) => gate.future),
            TextButton(onPressed: () => taps++, child: const Text('other')),
          ],
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.tap(find.text('other'));
    expect(taps, 1);
    gate.complete();
    await tester.pump();
  });
}
