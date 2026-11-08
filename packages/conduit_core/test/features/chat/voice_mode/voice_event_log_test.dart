import 'package:conduit_core/features/chat/voice_mode/voice_event_log.dart';
import 'package:test/test.dart';

void main() {
  test('call-start is posted at once, not with the next batch', () {
    final posts = <Map<String, Object?>>[];
    final log = VoiceEventLog.instance;
    log.start(
      sender: (body) async {
        posts.add(body);
        return true;
      },
      info: {'route': 'speaker'},
    );
    addTearDown(log.stop);
    final events = posts.expand((b) => b['events']! as List).toList();
    expect(posts, hasLength(1));
    expect((events.first as Map)['kind'], 'call-start');
  });

  test('an engine failure between calls is reported at the next call-start', () {
    final posts = <Map<String, Object?>>[];
    final log = VoiceEventLog.instance;
    if (log.active) log.stop();
    log.add('engine-failed', {'error': 'probe'});
    log.add('play-start'); // everything else is still dropped off-call
    log.start(
      sender: (body) async {
        posts.add(body);
        return true;
      },
    );
    log.flush();
    addTearDown(log.stop);
    final events = posts
        .expand((b) => b['events']! as List)
        .cast<Map<String, Object?>>()
        .toList();
    expect(events.map((e) => e['kind']), ['call-start', 'engine-failed']);
    expect(events.last['error'], 'probe');
    expect(events.last['between-calls'], isTrue);
  });
}
