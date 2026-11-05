import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/chat/services/reply_audio_flow.dart';
import 'package:conduit/features/chat/services/reply_mp3_export.dart';
import 'package:conduit/features/chat/services/speech_take_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late SpeechTakeStore store;
  late ReplyAudioFlow flow;
  var relayCalls = 0;
  var renderNumber = 0;

  const request = ReplyAudioRequest(
    messageId: 'm1',
    text: 'Here is your day. It looks quiet.',
    lookupVoiceKeys: ['heard', 'direct|m|alloy'],
    renderVoiceKey: 'direct|m|alloy',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('reply_flow_');
    relayCalls = 0;
    renderNumber = 0;
    store = SpeechTakeStore(
      supportDirectory: () async => Directory('${tmp.path}/support'),
      excludeFromBackup: (_) async {},
    );
    flow = ReplyAudioFlow(
      store: store,
      exporter: ReplyMp3Export(
        startRelayExport: (text) async {
          relayCalls++;
          return const Mp3ExportTicket(url: 'https://relay.invalid/x');
        },
        // Every render is a different take, as Breeze's are.
        download: (url) async => Uint8List.fromList([++renderNumber, 9, 9]),
        render: (text) async => throw StateError('no fallback render'),
        tempDirectory: () async => Directory('${tmp.path}/cache'),
      ),
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<SpeechTake> keepHeardTake() async {
    final heard = File('${tmp.path}/heard.mp3')
      ..writeAsBytesSync([42, 42, 42, 42]);
    return store.save(
      messageId: 'm1',
      voiceKey: 'heard',
      text: request.text,
      source: heard,
      extension: 'mp3',
    );
  }

  test('a heard take is shared at once: no relay call, no preview', () async {
    await keepHeardTake();
    var previews = 0;
    final chosen = await flow.choose(
      request,
      render: () => throw StateError('must not render'),
      showPreview: (take, again) async {
        previews++;
        return take;
      },
    );
    expect(relayCalls, 0);
    expect(previews, 0);
    final staged = await flow.stage(chosen!, request);
    expect(await staged.file.readAsBytes(), [42, 42, 42, 42]);
    expect(staged.file.path, endsWith('Here-is-your-day-It-looks.mp3'));
    // The shared file is a copy: the kept take is not the share-sheet file.
    expect(staged.file.path, isNot(chosen.file.path));
    expect(chosen.file.existsSync(), isTrue);
  });

  test('with no take it renders through the relay and shows the preview', () async {
    var previews = 0;
    SpeechTake? shown;
    final chosen = await flow.choose(
      request,
      render: () => flow.render(request),
      showPreview: (take, again) async {
        previews++;
        shown = take;
        return take;
      },
    );
    expect(relayCalls, 1);
    expect(previews, 1);
    expect(chosen!.file.path, shown!.file.path);
    // It is kept: the next share is this audio, with no relay call.
    final next = await flow.choose(
      request,
      render: () => throw StateError('must not render'),
      showPreview: (t, a) => throw StateError('no preview'),
    );
    expect(relayCalls, 1);
    expect(await next!.file.readAsBytes(), await chosen.file.readAsBytes());
  });

  test('Try again replaces the take and Share sends the replaced one', () async {
    SpeechTake? first;
    final chosen = await flow.choose(
      request,
      render: () => flow.render(request),
      showPreview: (take, again) async {
        first = take;
        final second = await again();
        final third = await again();
        expect(relayCalls, 3);
        expect(second.file.path, third.file.path);
        return third;
      },
    );
    final bytes = await chosen!.file.readAsBytes();
    expect(bytes.first, 3);
    final staged = await flow.stage(chosen, request);
    expect(await staged.file.readAsBytes(), bytes);
    // The kept take is the newest one.
    final kept = await flow.savedTake(request);
    expect(await kept!.file.readAsBytes(), bytes);
    expect((await first!.file.readAsBytes()).first, 3, reason: 'same slot');
  });

  test('closing the preview shares nothing', () async {
    final chosen = await flow.choose(
      request,
      render: () => flow.render(request),
      showPreview: (take, again) async => null,
    );
    expect(chosen, isNull);
  });

  test('Preview audio opens the sheet on a heard take, Try again re-renders', () async {
    await keepHeardTake();
    final chosen = await flow.choose(
      request,
      preview: true,
      render: () => throw StateError('no render before the sheet'),
      renderForTryAgain: () => flow.render(request),
      showPreview: (take, again) async {
        expect(await take.file.readAsBytes(), [42, 42, 42, 42]);
        return again();
      },
    );
    expect(relayCalls, 1);
    expect((await chosen!.file.readAsBytes()).first, 1);
  });

  test('another text is not the heard take', () async {
    await keepHeardTake();
    const edited = ReplyAudioRequest(
      messageId: 'm1',
      text: 'Here is your day. It looks busy.',
      lookupVoiceKeys: ['heard', 'direct|m|alloy'],
      renderVoiceKey: 'direct|m|alloy',
    );
    expect(await flow.savedTake(edited), isNull);
  });
}
