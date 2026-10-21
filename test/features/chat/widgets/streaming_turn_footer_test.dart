import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit/features/chat/widgets/conduit_streaming_orbit.dart';
import 'package:conduit/features/chat/widgets/conduit_wave_dots.dart';
import 'package:conduit/features/chat/widgets/streaming_turn_footer.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

Iterable<_RecordedPlatformCall> _lightImpactCalls(
  List<_RecordedPlatformCall> calls,
) => calls.where(
  (call) =>
      call.method == 'HapticFeedback.vibrate' &&
      call.arguments == 'HapticFeedbackType.lightImpact',
);

ProviderContainer _buildContainer() {
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(
        const AppSettings(disableHapticsWhileStreaming: true),
      ),
    ],
  );
}

ProviderContainer _buildHapticsContainer({bool enabled = true}) {
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(
        AppSettings(disableHapticsWhileStreaming: !enabled),
      ),
    ],
  );
}

Widget _buildHarness({
  required ProviderContainer container,
  required ChatMessage message,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(body: StreamingTurnFooter(message: message)),
      ),
    ),
  );
}

void main() {
  testWidgets('shows empty-stream indicator immediately while running', (
    tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final message = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: message),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
  });

  testWidgets('stays visible once streaming content arrives', (tester) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final empty = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: empty),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);

    // Re-pump the same message id with content arriving so the footer is driven
    // through the empty -> content transition rather than asserting a static
    // single state.
    final withContent = empty.copyWith(content: 'Hello');
    await tester.pumpWidget(
      _buildHarness(container: container, message: withContent),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
  });

  testWidgets('left-aligns the running indicator in its footer row', (
    tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final message = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: 'Hello',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 320,
                  child: StreamingTurnFooter(message: message),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final indicatorLeft = tester
        .getTopLeft(find.byType(ConduitStreamingOrbit))
        .dx;
    expect(indicatorLeft, lessThan(48));
  });

  testWidgets('the wave setting swaps the orbit for the wave dots', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: 'Hello',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );
    Future<Size> footerSize({required bool wave}) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AppSettings(
              disableHapticsWhileStreaming: true,
              waveTypingIndicator: wave,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _buildHarness(container: container, message: message),
      );
      await tester.pump();
      return tester.getSize(find.byKey(const ValueKey('typing')));
    }

    final orbitSize = await footerSize(wave: false);
    check(find.byType(ConduitStreamingOrbit).evaluate()).length.equals(1);
    check(find.byType(ConduitWaveDots).evaluate()).isEmpty();

    // Remount so the new container's setting is read from scratch.
    await tester.pumpWidget(const SizedBox.shrink());
    final waveSize = await footerSize(wave: true);
    check(find.byType(ConduitWaveDots).evaluate()).length.equals(1);
    check(find.byType(ConduitStreamingOrbit).evaluate()).isEmpty();
    check(tester.getSize(find.byType(ConduitWaveDots)).height).equals(28);
    // The harness disables animations, so the dots hold still.
    check(tester.widget<ConduitWaveDots>(find.byType(ConduitWaveDots)).animate)
        .isFalse();

    check(waveSize).equals(orbitSize);
  });

  testWidgets('the wave paces itself once reply text arrives', (tester) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AppSettings(
            disableHapticsWhileStreaming: true,
            waveTypingIndicator: true,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    Widget footer(String content) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: StreamingTurnFooter(
            message: ChatMessage(
              id: 'assistant-live',
              role: 'assistant',
              content: content,
              timestamp: DateTime(2024, 1, 1),
              isStreaming: true,
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(footer(''));
    await tester.pump(const Duration(milliseconds: 250));

    var dots = tester.widget<ConduitWaveDots>(find.byType(ConduitWaveDots));
    check(dots.animate).isTrue();
    check(dots.paced).isFalse();
    check(
      find
          .ancestor(
            of: find.byType(ConduitWaveDots),
            matching: find.byType(RepaintBoundary),
          )
          .evaluate(),
    ).isNotEmpty();

    await tester.pumpWidget(footer('Hello'));
    await tester.pump(const Duration(milliseconds: 250));
    dots = tester.widget<ConduitWaveDots>(find.byType(ConduitWaveDots));
    check(dots.animate).isTrue();
    check(dots.paced).isTrue();

    // Unmount so the wave's controller and timer do not outlive the test.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stays visible while status rows are pending', (tester) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final pending = ChatMessage(
      id: 'assistant-status',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
      statusHistory: const [
        ChatStatusUpdate(action: 'search', description: 'Searching'),
      ],
    );
    final done = pending.copyWith(
      statusHistory: const [
        ChatStatusUpdate(
          action: 'search',
          description: 'Searching',
          done: true,
        ),
      ],
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: pending),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);

    await tester.pumpWidget(_buildHarness(container: container, message: done));
    await tester.pump();

    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
  });

  test(
    'active assistant streams show the footer until response completion',
    () {
      final streaming = ChatMessage(
        id: 'assistant-live',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      expect(shouldShowStreamingTurnFooter(message: streaming), isTrue);
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(content: 'Hello'),
        ),
        isTrue,
      );
      // `responseDone` settles the turn even while the transport flag is still
      // streaming, so the typing footer must hide (the "responseDone gap").
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(metadata: const {'responseDone': true}),
        ),
        isFalse,
      );
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(files: const [{}]),
        ),
        isTrue,
      );
      // An errored turn is failed, not running — the footer is suppressed even
      // while `isStreaming` is still set.
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(
            error: const ChatMessageError(content: 'boom'),
          ),
        ),
        isFalse,
      );
      expect(
        shouldShowStreamingTurnFooter(
          message: streaming.copyWith(
            isStreaming: false,
            metadata: const {'responseDone': true},
          ),
        ),
        isFalse,
      );
    },
  );

  testWidgets('hides typing indicator while a queued completion is pending', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AppSettings(disableHapticsWhileStreaming: true),
        ),
        queuedCompletionInfoForMessageProvider('assistant-queued').overrideWith(
          (ref) => Stream<QueuedCompletionInfo?>.value(
            const QueuedCompletionInfo(
              databaseOwner: Object(),
              seq: 1,
              chatId: 'chat-1',
              scopedChatId: 'chat-1',
              assistantMessageId: 'assistant-queued',
              phase: QueuedCompletionPhase.pending,
              isOffline: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final message = ChatMessage(
      id: 'assistant-queued',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: message),
    );
    await tester.pump();

    expect(find.byType(ConduitStreamingOrbit), findsNothing);
    expect(find.byKey(const ValueKey('typing')), findsNothing);
  });

  testWidgets('fires one running haptic and re-arms on message id change', (
    tester,
  ) async {
    final container = _buildHapticsContainer();
    addTearDown(container.dispose);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <_RecordedPlatformCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(_RecordedPlatformCall(call.method, call.arguments));
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      final running = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      await tester.pumpWidget(
        _buildHarness(container: container, message: running),
      );
      await tester.pump();
      expect(_lightImpactCalls(calls), hasLength(1));

      // Same id, content arrives, still running: the fire-once guard holds.
      await tester.pumpWidget(
        _buildHarness(
          container: container,
          message: running.copyWith(content: 'Hi'),
        ),
      );
      await tester.pump();
      expect(_lightImpactCalls(calls), hasLength(1));

      // A new running message id re-arms the haptic.
      final next = ChatMessage(
        id: 'assistant-2',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );
      await tester.pumpWidget(
        _buildHarness(container: container, message: next),
      );
      await tester.pump();
      expect(_lightImpactCalls(calls), hasLength(2));
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'does not fire the running haptic when suppressed on the footer',
    (tester) async {
      final container = _buildHapticsContainer();
      addTearDown(container.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Scaffold(
                  body: StreamingTurnFooter(
                    message: ChatMessage(
                      id: 'assistant-1',
                      role: 'assistant',
                      content: '',
                      timestamp: DateTime(2026),
                      isStreaming: true,
                    ),
                    suppressStreamingHaptics: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(_lightImpactCalls(calls), isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'does not fire the running haptic when streaming haptics are disabled',
    (tester) async {
      final container = _buildHapticsContainer(enabled: false);
      addTearDown(container.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        await tester.pumpWidget(
          _buildHarness(
            container: container,
            message: ChatMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: '',
              timestamp: DateTime(2026),
              isStreaming: true,
            ),
          ),
        );
        await tester.pump();

        expect(_lightImpactCalls(calls), isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('hides the typing indicator once the turn settles', (
    tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);
    final running = ChatMessage(
      id: 'assistant-live',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildHarness(container: container, message: running),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);

    await tester.pumpWidget(
      _buildHarness(
        container: container,
        message: running.copyWith(metadata: const {'responseDone': true}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('typing')), findsNothing);
    expect(
      find.byKey(const ValueKey('streaming-turn-footer-empty')),
      findsOneWidget,
    );
  });

  testWidgets('does not replay the running haptic when the footer remounts', (
    tester,
  ) async {
    final container = _buildHapticsContainer();
    addTearDown(container.dispose);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <_RecordedPlatformCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(_RecordedPlatformCall(call.method, call.arguments));
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      final running = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      await tester.pumpWidget(
        _buildHarness(container: container, message: running),
      );
      await tester.pump();
      check(_lightImpactCalls(calls)).length.equals(1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        _buildHarness(container: container, message: running),
      );
      await tester.pump();

      check(_lightImpactCalls(calls)).length.equals(1);
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    're-arms the running haptic after hiding and reshowing on the same id',
    (tester) async {
      final container = _buildHapticsContainer();
      addTearDown(container.dispose);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        final running = ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: '',
          timestamp: DateTime(2026),
          isStreaming: true,
        );

        await tester.pumpWidget(
          _buildHarness(container: container, message: running),
        );
        await tester.pump();
        expect(_lightImpactCalls(calls), hasLength(1));

        // Settling (responseDone) hides the footer and re-arms the guard via
        // _syncRunningHaptic(false) — without a message-id change.
        await tester.pumpWidget(
          _buildHarness(
            container: container,
            message: running.copyWith(metadata: const {'responseDone': true}),
          ),
        );
        await tester.pump();
        expect(_lightImpactCalls(calls), hasLength(1));

        // Back to running on the SAME id: the guard re-fires exactly once more.
        await tester.pumpWidget(
          _buildHarness(container: container, message: running),
        );
        await tester.pump();
        expect(_lightImpactCalls(calls), hasLength(2));
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
