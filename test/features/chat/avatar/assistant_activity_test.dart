import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_activity.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

final _at = DateTime.utc(2024, 1, 1, 12);

ChatMessage _user(String content) =>
    ChatMessage(id: 'u', role: 'user', content: content, timestamp: _at);

ChatMessage _assistant({
  String id = 'a',
  String content = '',
  bool isStreaming = true,
  List<ChatStatusUpdate> statusHistory = const [],
  ChatMessageError? error,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: _at,
  isStreaming: isStreaming,
  statusHistory: statusHistory,
  error: error,
);

AssistantActivity _live(List<ChatMessage> messages) =>
    assistantActivitySnapshot(messages).live;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('live activity', () {
    test('idle with no messages, a user turn last, or a finished reply', () {
      check(_live(const [])).equals(AssistantActivity.idle);
      check(_live([_user('hi')])).equals(AssistantActivity.idle);
      check(
        _live([_user('hi'), _assistant(content: 'Hello', isStreaming: false)]),
      ).equals(AssistantActivity.idle);
    });

    test('working while streaming with no visible text yet', () {
      check(_live([_user('hi'), _assistant()]))
          .equals(AssistantActivity.working);
      check(
        _live([
          _user('hi'),
          _assistant(
            content: '<details type="reasoning" done="false">\n<summary>',
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('working when the latest status is unfinished reasoning', () {
      check(
        _live([
          _user('hi'),
          _assistant(
            content: 'Partial',
            statusHistory: const [
              ChatStatusUpdate(action: 'reasoning', done: false),
            ],
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('working while visible text streams in', () {
      check(_live([_user('hi'), _assistant(content: 'Hel')]))
          .equals(AssistantActivity.working);
      check(
        _live([
          _user('hi'),
          _assistant(
            content:
                '<details type="reasoning" done="true">thought</details>\n'
                'Answer',
            statusHistory: const [
              ChatStatusUpdate(action: 'reasoning', done: true),
            ],
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('working for an unfinished search, knowledge or tool step', () {
      for (final action in [
        'web_search',
        'web_search_queries_generated',
        'queries_generated',
        'knowledge_search',
        'hermes_tool_terminal',
      ]) {
        check(
          because: action,
          _live([
            _user('hi'),
            _assistant(
              statusHistory: [ChatStatusUpdate(action: action, done: false)],
            ),
          ]),
        ).equals(AssistantActivity.working);
      }
    });

    test('a finished tool step leaves plain working', () {
      check(
        _live([
          _user('hi'),
          _assistant(
            content: 'Found it',
            statusHistory: const [
              ChatStatusUpdate(action: 'web_search', done: true),
            ],
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('hidden status updates are ignored', () {
      check(
        _live([
          _user('hi'),
          _assistant(
            content: 'Text',
            statusHistory: const [
              ChatStatusUpdate(
                description: 'Creating image',
                done: false,
                hidden: true,
              ),
            ],
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('working for an Open WebUI tool call block in flight', () {
      check(
        _live([
          _user('hi'),
          _assistant(
            content:
                'Let me check.\n'
                '<details type="tool_calls" done="false" name="fetch_url">\n'
                '<summary>Executing...</summary>\n</details>\n',
          ),
        ]),
      ).equals(AssistantActivity.working);
      check(
        _live([
          _user('hi'),
          _assistant(
            content:
                '<details type="tool_calls" done="true" name="x">'
                '<summary>Done</summary></details>\nThe page says hello',
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('making while an image tool call is in flight', () {
      for (final name in [
        'generate_image',
        'edit_image',
        'images_generate_image',
      ]) {
        check(
          because: name,
          _live([
            _user('draw a cat'),
            _assistant(
              content:
                  '<details type="tool_calls" done="false" id="c1" '
                  'name="$name" arguments="{}">\n'
                  '<summary>Executing...</summary>\n</details>\n',
            ),
          ]),
        ).equals(AssistantActivity.making);
      }
      check(
        _live([
          _user('draw a cat'),
          _assistant(
            content:
                '<details type="tool_calls" done="true" name="generate_image">'
                '<summary>Done</summary></details>\nHere it is',
          ),
        ]),
      ).equals(AssistantActivity.working);
      // Only the image tools themselves, not names that merely contain them.
      for (final name in ['generate_images', 'regenerate_image_cache']) {
        check(
          because: name,
          _live([
            _user('draw a cat'),
            _assistant(
              content:
                  '<details type="tool_calls" done="false" name="$name">\n',
            ),
          ]),
        ).equals(AssistantActivity.working);
      }
    });

    test('making while image generation reports Creating image', () {
      // Open WebUI's chat_image_generation_handler: description only, no
      // action, then "Image created" with done true.
      check(
        _live([
          _user('draw a cat'),
          _assistant(
            statusHistory: const [
              ChatStatusUpdate(description: 'Creating image', done: false),
            ],
          ),
        ]),
      ).equals(AssistantActivity.making);
      check(
        _live([
          _user('draw a cat'),
          _assistant(
            statusHistory: const [
              ChatStatusUpdate(action: 'image_generation', done: false),
            ],
          ),
        ]),
      ).equals(AssistantActivity.making);
      check(
        _live([
          _user('draw a cat'),
          _assistant(
            statusHistory: const [
              ChatStatusUpdate(description: 'Creating image', done: false),
              ChatStatusUpdate(description: 'Image created', done: true),
            ],
          ),
        ]),
      ).equals(AssistantActivity.working);
    });

    test('the streaming reply of a multi-model turn wins', () {
      check(
        _live([
          _user('hi'),
          _assistant(id: 'a1', content: 'Done one', isStreaming: false),
          _assistant(
            id: 'a2',
            content:
                '<details type="tool_calls" done="false" '
                'name="edit_image">\n',
          ),
        ]),
      ).equals(AssistantActivity.making);
    });
  });

  group('resolveDisplayedAssistantActivity', () {
    test('a live activity always wins', () {
      for (final live in [
        AssistantActivity.working,
        AssistantActivity.making,
      ]) {
        check(resolveDisplayedAssistantActivity(live: live, holdingDone: true))
            .equals(live);
      }
    });

    test('done shows only while it is held', () {
      check(
        resolveDisplayedAssistantActivity(
          live: AssistantActivity.idle,
          holdingDone: true,
        ),
      ).equals(AssistantActivity.done);
      check(
        resolveDisplayedAssistantActivity(
          live: AssistantActivity.idle,
          holdingDone: false,
        ),
      ).equals(AssistantActivity.idle);
    });
  });

  group('tool step detail', () {
    String? detail(List<ChatMessage> messages) =>
        assistantActivitySnapshot(messages).detail;

    test('names the tool call in flight as the status rows do', () {
      check(
        detail([
          _user('hi'),
          _assistant(
            content:
                '<details type="tool_calls" done="false" id="c1" '
                'name="search_web" arguments="{}">\n'
                '<summary>Executing...</summary>\n</details>\n',
          ),
        ]),
      ).equals('Search web');
      check(
        detail([
          _user('hi'),
          _assistant(
            content: '<details type="tool_calls" done="false" name="">\n',
          ),
        ]),
      ).isNull();
    });

    test('finds a running tool call at the end of a long reply', () {
      final longAnswer = List.filled(5000, 'word').join(' ');
      final messages = [
        _user('hi'),
        _assistant(
          content:
              '<details type="tool_calls" done="true" name="fetch_url">'
              '<summary>Done</summary></details>\n$longAnswer\n'
              '<details type="tool_calls" done="false" name="generate_image">'
              '\n<summary>Executing...</summary>\n</details>\n',
        ),
      ];
      check(assistantActivitySnapshot(messages).live)
          .equals(AssistantActivity.making);
      check(detail(messages)).equals('Generate image');
    });

    test('uses the status description for a search step', () {
      check(
        detail([
          _user('hi'),
          _assistant(
            statusHistory: const [
              ChatStatusUpdate(
                action: 'web_search',
                description: 'Searching the web',
                done: false,
              ),
            ],
          ),
        ]),
      ).equals('Searching the web');
      check(
        detail([
          _user('hi'),
          _assistant(
            statusHistory: const [
              ChatStatusUpdate(action: 'hermes_tool_terminal', done: false),
            ],
          ),
        ]),
      ).equals('Terminal');
    });

    test('names the image step while making', () {
      check(
        detail([
          _user('draw'),
          _assistant(
            content:
                '<details type="tool_calls" done="false" '
                'name="generate_image">\n',
          ),
        ]),
      ).equals('Generate image');
      check(
        detail([
          _user('draw'),
          _assistant(
            statusHistory: const [
              ChatStatusUpdate(description: 'Creating image', done: false),
            ],
          ),
        ]),
      ).equals('Creating image');
    });

    test('nothing for reasoning, writing, an unnamed tool or idle', () {
      check(detail([_user('hi'), _assistant()])).isNull();
      check(detail([_user('hi'), _assistant(content: 'Hel')])).isNull();
      check(
        detail([
          _user('hi'),
          _assistant(
            content: '<details type="tool_calls" done="false">\n<summary>',
          ),
        ]),
      ).isNull();
      check(detail([_user('hi'), _assistant(isStreaming: false)])).isNull();
    });

    test('a finished tool block names nothing', () {
      final messages = [
        _user('hi'),
        _assistant(
          content:
              '<details type="tool_calls" done="true" name="fetch_url">'
              '<summary>Done</summary></details>\nThe page says hello',
        ),
      ];
      check(detail(messages)).isNull();
      check(assistantActivitySnapshot(messages).detail).isNull();
    });
  });

  test('snapshot reports a failed latest reply', () {
    final snapshot = assistantActivitySnapshot([
      _user('hi'),
      _assistant(
        isStreaming: false,
        error: const ChatMessageError(content: 'boom'),
      ),
    ]);
    check(snapshot.live).equals(AssistantActivity.idle);
    check(snapshot.failed).isTrue();
  });

  group('AssistantAvatarMediaSet.resolve', () {
    const workingFile = AssistantAvatarMedia.file(
      '/docs/assistant_avatar/working.gif',
      AssistantAvatarMediaKind.image,
    );
    const idleFile = AssistantAvatarMedia.file(
      '/docs/assistant_avatar/idle.mov',
      AssistantAvatarMediaKind.video,
    );

    test('making falls back to the working clip, then to nothing', () {
      const withWorking = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.working: workingFile},
      );
      check(withWorking.resolve(AssistantActivity.making)).equals(workingFile);
      const makingFile = AssistantAvatarMedia.file(
        '/docs/assistant_avatar/making.mp4',
        AssistantAvatarMediaKind.video,
      );
      const ownMaking = AssistantAvatarMediaSet(
        userFiles: {
          AssistantActivity.working: workingFile,
          AssistantActivity.making: makingFile,
        },
      );
      check(ownMaking.resolve(AssistantActivity.making)).equals(makingFile);
      const idleOnly = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.idle: idleFile},
      );
      check(idleOnly.resolve(AssistantActivity.making)).isNull();
    });

    test('done falls back to the idle clip, then to nothing', () {
      const withIdle = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.idle: idleFile},
      );
      check(withIdle.resolve(AssistantActivity.done)).equals(idleFile);
      const workingOnly = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.working: workingFile},
      );
      check(workingOnly.resolve(AssistantActivity.done)).isNull();
    });

    test('a user file beats the bundled default', () {
      const media = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.working: workingFile},
        bundled: {AssistantActivity.working},
      );
      check(media.resolve(AssistantActivity.working)).equals(workingFile);
    });

    test('a bundled default is used when no user file exists', () {
      const media = AssistantAvatarMediaSet(bundled: {AssistantActivity.idle});
      final resolved = media.resolve(AssistantActivity.idle)!;
      check(resolved.isBundled).isTrue();
      check(resolved.path).equals('assets/assistant_avatar/idle.mp4');
      check(resolved.kind).equals(AssistantAvatarMediaKind.video);
      check(media.resolve(AssistantActivity.done)!.path)
          .equals('assets/assistant_avatar/idle.mp4');
      const bundledWorking = AssistantAvatarMediaSet(
        bundled: {AssistantActivity.working},
      );
      check(bundledWorking.resolve(AssistantActivity.making)!.path)
          .equals('assets/assistant_avatar/working.mp4');
    });

    test('working and idle have no fallback, so the initial shows', () {
      const media = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.done: idleFile},
      );
      check(media.resolve(AssistantActivity.working)).isNull();
      check(media.resolve(AssistantActivity.idle)).isNull();
      for (final state in AssistantActivity.values) {
        check(AssistantAvatarMediaSet.empty.resolve(state)).isNull();
      }
    });
  });

  group('AssistantAvatarMediaStore', () {
    late Directory documents;
    late Directory sources;

    setUp(() {
      documents = Directory.systemTemp.createTempSync('avatar_docs_');
      sources = Directory.systemTemp.createTempSync('avatar_src_');
    });

    tearDown(() {
      documents.deleteSync(recursive: true);
      sources.deleteSync(recursive: true);
    });

    XFile source(String name) {
      final file = File('${sources.path}/$name')..writeAsBytesSync([1, 2, 3]);
      return XFile(file.path, name: name);
    }

    test('assigning replaces the previous file for that state only', () async {
      final store = AssistantAvatarMediaStore(
        documentsDirectory: () async => documents,
      );
      check(await store.assign(AssistantActivity.idle, source('a.mov')))
          .isTrue();
      check(await store.assign(AssistantActivity.done, source('b.png')))
          .isTrue();
      check(await store.assign(AssistantActivity.idle, source('c.GIF')))
          .isTrue();

      final media = await store.load();
      check(media.userFiles.keys.toSet())
          .deepEquals({AssistantActivity.idle, AssistantActivity.done});
      final idle = media.userFiles[AssistantActivity.idle]!;
      check(idle.path).endsWith('assistant_avatar/idle.GIF');
      check(idle.kind).equals(AssistantAvatarMediaKind.image);
      check(Directory('${documents.path}/assistant_avatar').listSync().length)
          .equals(2);

      await store.remove(AssistantActivity.idle);
      check((await store.load()).userFiles.keys.toSet())
          .deepEquals({AssistantActivity.done});
    });

    group('migration from the five earlier states', () {
      Directory folder() => Directory('${documents.path}/assistant_avatar');

      void seed(Map<String, List<int>> files) {
        folder().createSync(recursive: true);
        files.forEach(
          (name, bytes) =>
              File('${folder().path}/$name').writeAsBytesSync(bytes),
        );
      }

      Map<String, List<int>> onDisk() => {
        for (final entity in folder().listSync())
          if (entity is File)
            entity.uri.pathSegments.last: entity.readAsBytesSync(),
      };

      AssistantAvatarMediaStore newStore() =>
          AssistantAvatarMediaStore(documentsDirectory: () async => documents);

      test('working takes the tools clip first', () async {
        seed({
          'idle.mov': [1],
          'thinking.mp4': [2],
          'writing.gif': [3],
          'tools.mov': [4],
          'done.png': [5],
        });
        final media = await newStore().load();
        check(onDisk()).deepEquals({
          'idle.mov': [1],
          'working.mov': [4],
          'done.png': [5],
        });
        check(media.userFiles.keys.toSet()).deepEquals({
          AssistantActivity.idle,
          AssistantActivity.working,
          AssistantActivity.done,
        });
        check(media.userFiles[AssistantActivity.making]).isNull();
        check(media.resolve(AssistantActivity.making)!.path)
            .endsWith('assistant_avatar/working.mov');
      });

      test('working takes the writing clip without a tools clip', () async {
        seed({
          'thinking.mp4': [2],
          'writing.gif': [3],
        });
        final media = await newStore().load();
        check(onDisk()).deepEquals({
          'working.gif': [3],
        });
        check(media.userFiles[AssistantActivity.working]!.kind)
            .equals(AssistantAvatarMediaKind.image);
      });

      test('working takes the thinking clip when it is the only one', () async {
        seed({
          'thinking.mp4': [2],
          'done.png': [5],
        });
        await newStore().load();
        check(onDisk()).deepEquals({
          'working.mp4': [2],
          'done.png': [5],
        });
      });

      test('nothing to move leaves idle and done untouched', () async {
        seed({
          'idle.mov': [1],
          'done.png': [5],
        });
        final media = await newStore().load();
        check(onDisk()).deepEquals({
          'idle.mov': [1],
          'done.png': [5],
        });
        check(media.userFiles.keys.toSet())
            .deepEquals({AssistantActivity.idle, AssistantActivity.done});
      });

      test('an existing working clip wins and old files are removed', () async {
        seed({
          'working.mp4': [9],
          'tools.mov': [4],
          'thinking.mp4': [2],
        });
        await newStore().load();
        check(onDisk()).deepEquals({
          'working.mp4': [9],
        });
      });

      test('running it again changes nothing', () async {
        seed({
          'idle.mov': [1],
          'writing.gif': [3],
          'tools.mov': [4],
        });
        final store = newStore();
        await store.load();
        final first = onDisk();
        await store.migrateLegacyFiles();
        await newStore().load();
        check(onDisk()).deepEquals(first);
        check(first).deepEquals({
          'idle.mov': [1],
          'working.mov': [4],
        });
      });

      test('a later pick for making is kept', () async {
        seed({
          'tools.mov': [4],
        });
        final store = newStore();
        await store.load();
        check(await store.assign(AssistantActivity.making, source('m.mp4')))
            .isTrue();
        final media = await newStore().load();
        check(media.userFiles.keys.toSet())
            .deepEquals({AssistantActivity.working, AssistantActivity.making});
      });

      test('no folder is fine', () async {
        await newStore().migrateLegacyFiles();
        check(folder().existsSync()).isFalse();
      });
    });

    test(
      'a failing documents directory yields nothing, never throws',
      () async {
        final store = AssistantAvatarMediaStore(
          documentsDirectory: () async => throw const FileSystemException('no'),
        );
        check((await store.load()).userFiles).isEmpty();
        check(await store.assign(AssistantActivity.idle, source('a.mp4')))
            .isFalse();
        await store.remove(AssistantActivity.idle);
      },
    );
  });
}
