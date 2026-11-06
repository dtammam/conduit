import 'dart:io';

import 'package:conduit/features/chat/background/chat_background.dart';
import 'package:conduit/features/profile/widgets/chat_background_section.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late ProviderContainer c;
  late List<String> calls;
  late List<String> messages;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bg_pick');
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    c = ProviderContainer(
      overrides: [chatBackgroundDirectoryProvider.overrideWith((_) => tmp)],
    );
    calls = [];
    messages = [];
  });
  tearDown(() {
    c.dispose();
    PreferencesStore.debugReset();
    tmp.deleteSync(recursive: true);
  });

  ChatBackgroundNotifier notifier() => c.read(chatBackgroundProvider.notifier);

  test('the sheet is dismissed first, then the picker opens', () async {
    final src = File('${tmp.path}/in.jpg')..writeAsBytesSync([1, 2, 3]);
    final out = await pickChatBackgroundPhoto(
      notifier(),
      beforePick: () async => calls.add('dismiss'),
      pick: () async {
        calls.add('pick');
        return XFile(src.path);
      },
      onMessage: messages.add,
    );
    expect(calls, ['dismiss', 'pick']);
    expect(out, ChatBackgroundPickOutcome.chosen);
    expect(c.read(chatBackgroundProvider).mode, ChatBackgroundMode.image);
    expect(c.read(chatBackgroundProvider).imageName, isNotNull);
    expect(messages, isEmpty);
  });

  test('a cancelled pick changes nothing and says nothing', () async {
    notifier().setMode(ChatBackgroundMode.color);
    final out = await pickChatBackgroundPhoto(
      notifier(),
      pick: () async => null,
      onMessage: messages.add,
    );
    expect(out, ChatBackgroundPickOutcome.cancelled);
    expect(c.read(chatBackgroundProvider).mode, ChatBackgroundMode.color);
    expect(c.read(chatBackgroundProvider).imageName, isNull);
    expect(messages, isEmpty);
  });

  test('a picker error shows a message and changes nothing', () async {
    final out = await pickChatBackgroundPhoto(
      notifier(),
      pick: () async => throw PlatformException(code: 'boom'),
      onMessage: messages.add,
    );
    expect(out, ChatBackgroundPickOutcome.failed);
    expect(messages, hasLength(1));
    expect(c.read(chatBackgroundProvider).mode, ChatBackgroundMode.gradient);
  });

  test('denied photo access names where to turn it on', () async {
    await pickChatBackgroundPhoto(
      notifier(),
      pick: () async => throw PlatformException(code: 'photo_access_denied'),
      onMessage: messages.add,
    );
    expect(messages.single, contains('Settings'));
    expect(messages.single, contains('Photos'));
  });

  test('a photo that cannot be saved shows a message', () async {
    final out = await pickChatBackgroundPhoto(
      notifier(),
      pick: () async => XFile('${tmp.path}/missing.jpg'),
      onMessage: messages.add,
    );
    expect(out, ChatBackgroundPickOutcome.failed);
    expect(messages, hasLength(1));
  });

  test(
    'image mode with no photo paints the gradient; remove and change work',
    () async {
      notifier().setMode(ChatBackgroundMode.image);
      expect(c.read(chatBackgroundProvider).imageName, isNull);
      final src = File('${tmp.path}/a.jpg')..writeAsBytesSync([1]);
      await notifier().setImageFrom(src);
      final first = c.read(chatBackgroundProvider).imageName!;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await notifier().setImageFrom(src);
      expect(c.read(chatBackgroundProvider).imageName, isNot(first));
      await notifier().removeImage();
      expect(c.read(chatBackgroundProvider).imageName, isNull);
      expect(c.read(chatBackgroundProvider).mode, ChatBackgroundMode.gradient);
    },
  );
}
