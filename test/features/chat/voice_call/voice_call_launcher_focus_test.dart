import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _dismissProvider = Provider<void Function()>(
  (ref) =>
      () => dismissComposerForVoiceMode(ref),
);

void main() {
  testWidgets('voice mode entry hides the keyboard and keeps autofocus off', (
    tester,
  ) async {
    final hides = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') hides.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(composerAutofocusEnabledProvider.notifier).set(true);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(focusNode: focus)),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    container.read(_dismissProvider)();
    await tester.pump();

    expect(focus.hasFocus, isFalse);
    expect(container.read(composerAutofocusEnabledProvider), isFalse);
    expect(hides, isNotEmpty);

    // Leaving voice mode does not touch focus: nothing here brings it back.
    await tester.pump(const Duration(seconds: 1));
    expect(focus.hasFocus, isFalse);
  });
}
