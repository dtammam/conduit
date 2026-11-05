import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

const Duration _requestTimeout = Duration(seconds: 8);

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// One item of the Feed (`GET /musey/feed`). Every field but [id] and [title]
/// may be missing.
@immutable
class FeedItem {
  const FeedItem({
    required this.id,
    required this.title,
    this.body,
    this.url,
    this.source,
    this.imageUrl,
    this.icon,
    this.at,
    this.liked = false,
  });

  final String id;
  final String title;
  final String? body;
  final String? url;
  final String? source;
  final String? imageUrl;
  final String? icon;
  final DateTime? at;
  final bool liked;

  FeedItem withLiked(bool value) => FeedItem(
    id: id,
    title: title,
    body: body,
    url: url,
    source: source,
    imageUrl: imageUrl,
    icon: icon,
    at: at,
    liked: value,
  );

  /// The domain shown under the info button: the source, else the link's host.
  String? get domain {
    final host = Uri.tryParse(url ?? '')?.host;
    if (host != null && host.isNotEmpty) {
      return host.startsWith('www.') ? host.substring(4) : host;
    }
    return source;
  }

  /// The text Discuss sends, exactly as the relay's doc specifies.
  String get discussText => url == null
      ? "Let's discuss this: $title"
      : "Let's discuss this: $title\n$url";
}

/// What `GET /musey/feed` answered.
@immutable
class FeedData {
  const FeedData({
    this.enabled = false,
    this.prompt = '',
    this.topics,
    this.items = const <FeedItem>[],
  });

  final bool enabled;
  final String prompt;

  /// The interests as separate things; null when the relay does not send
  /// them (an older relay), then only [prompt] is known.
  final List<String>? topics;
  final List<FeedItem> items;
}

/// The Feed in an answer; malformed items are skipped, anything that is not
/// the expected shape gives null.
FeedData? parseFeed(Object? data) {
  if (data is! Map) return null;
  final enabled = data['enabled'] != false;
  final items = <FeedItem>[];
  final raw = data['items'];
  if (raw is List) {
    for (final e in raw) {
      if (e is! Map) continue;
      final id = e['id']?.toString();
      final title = _str(e['title']);
      if (id == null || id.isEmpty || title == null) continue;
      final at = e['at'];
      items.add(
        FeedItem(
          id: id,
          title: title,
          body: _str(e['body']),
          url: _httpOnly(_str(e['url'])),
          source: _str(e['source']),
          imageUrl: _str(e['image_url']),
          icon: _str(e['icon']),
          at: at is String ? DateTime.tryParse(at) : null,
          liked: e['liked'] == true,
        ),
      );
    }
  }
  final prompt = data['prompt'];
  return FeedData(
    enabled: enabled,
    prompt: prompt is String ? prompt : '',
    topics: parseTopics(data['topics']),
    items: enabled ? items : const <FeedItem>[],
  );
}

/// The interests of an answer: strings only, trimmed, empty ones dropped.
/// Null when [raw] is not a list.
List<String>? parseTopics(Object? raw) {
  if (raw is! List) return null;
  return [
    for (final t in raw)
      if (t is String && t.trim().isNotEmpty) t.trim(),
  ];
}

/// What `POST /musey/feed/topics` answered: [topics] is the relay's list when
/// it took the change, else [error] says why in the relay's words (or null).
@immutable
class TopicsResult {
  const TopicsResult.saved(List<String> this.topics) : error = null;
  const TopicsResult.failed([this.error]) : topics = null;

  final List<String>? topics;
  final String? error;
  bool get ok => topics != null;
}

/// How a dismissal ended: the relay took it, the story was already gone (a
/// 404, which counts as done), or the call failed.
enum DismissResult { done, gone, failed }

String? _httpOnly(String? url) {
  if (url == null) return null;
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https' ? url : null;
}

/// One idea (`GET /musey/ideas`).
@immutable
class IdeaItem {
  const IdeaItem({
    required this.id,
    required this.title,
    this.body,
    this.icon,
    this.prompt,
    this.at,
  });

  final String id;
  final String title;
  final String? body;
  final String? icon;
  final String? prompt;
  final DateTime? at;

  /// What a tap sends: the idea's prompt, else its title.
  String get sendText => prompt ?? title;
}

List<IdeaItem>? parseIdeas(Object? data) {
  if (data is! Map) return null;
  if (data['enabled'] == false) return const <IdeaItem>[];
  final raw = data['items'];
  if (raw is! List) return const <IdeaItem>[];
  final out = <IdeaItem>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final id = e['id']?.toString();
    final title = _str(e['title']);
    if (id == null || id.isEmpty || title == null) continue;
    final at = e['at'];
    out.add(
      IdeaItem(
        id: id,
        title: title,
        body: _str(e['body']),
        icon: _str(e['icon']),
        prompt: _str(e['prompt']),
        at: at is String ? DateTime.tryParse(at) : null,
      ),
    );
  }
  return out;
}

/// A link card's content (`GET /musey/link-preview`).
@immutable
class LinkPreview {
  const LinkPreview({this.title, this.domain, this.imageUrl});

  final String? title;
  final String? domain;
  final String? imageUrl;

  bool get isEmpty => title == null && imageUrl == null;

  Map<String, Object?> toJson() => {
    'title': title,
    'domain': domain,
    'image_url': imageUrl,
  };

  static LinkPreview? fromJson(Object? data) {
    if (data is! Map) return null;
    final p = LinkPreview(
      title: _str(data['title']),
      domain: _str(data['domain']),
      imageUrl: _str(data['image_url']),
    );
    return p.isEmpty ? null : p;
  }
}

/// The relay's feed, ideas, icon and link-preview routes. Every method fails
/// soft: null or false, never a throw. A fake of this stands in for the relay
/// in tests.
abstract class MuseyFeedApi {
  Future<FeedData?> getFeed();
  Future<bool> setFeedPrompt(String prompt);
  Future<TopicsResult> setFeedTopics(List<String> topics);
  Future<DismissResult> dismissFeedItem(String id);

  /// The emoji that fits [text], or null for none, an error or a missing
  /// route.
  Future<String?> react(String text);

  /// True when the relay started a run.
  Future<bool> refreshFeed();
  Future<bool> like(String id, {required bool liked});
  Future<List<IdeaItem>?> getIdeas();
  Future<bool> dismissIdea(String id);

  /// The bytes of a relay path (an icon, or a link image), or null.
  Future<Uint8List?> fetchBytes(String path);
  Future<LinkPreview?> linkPreview(String url);
}

class DioMuseyFeedApi implements MuseyFeedApi {
  DioMuseyFeedApi(this._ref);

  final Ref _ref;

  Future<Response<Object?>?> _call(
    String method,
    String path, {
    Object? data,
    Map<String, String>? query,
    ResponseType responseType = ResponseType.json,
  }) async {
    try {
      final voice = _ref.read(directVoiceProviderProvider);
      if (voice == null) return null;
      final lease = _ref
          .read(directHttpClientPoolProvider)
          .acquire(voice.profile);
      try {
        final url = voice.profile.requestBaseUri().replace(
          path: path,
          queryParameters: query,
          fragment: '',
        );
        return await lease.dio.requestUri<Object?>(
          url,
          data: data,
          options: Options(
            method: method,
            responseType: responseType,
            sendTimeout: _requestTimeout,
            receiveTimeout: _requestTimeout,
            validateStatus: (_) => true,
          ),
        );
      } finally {
        lease.release();
      }
    } catch (_) {
      return null;
    }
  }

  static bool _ok(Response<Object?>? r) {
    final s = r?.statusCode ?? 0;
    return s >= 200 && s < 300;
  }

  @override
  Future<FeedData?> getFeed() async {
    final r = await _call('GET', '/musey/feed');
    return _ok(r) ? parseFeed(r!.data) : null;
  }

  @override
  Future<bool> setFeedPrompt(String prompt) async =>
      _ok(await _call('POST', '/musey/feed/prompt', data: {'prompt': prompt}));

  @override
  Future<TopicsResult> setFeedTopics(List<String> topics) async {
    final r = await _call(
      'POST',
      '/musey/feed/topics',
      data: {'topics': topics},
    );
    if (r == null) return const TopicsResult.failed();
    final d = r.data;
    if (_ok(r)) {
      final list = d is Map ? parseTopics(d['topics']) : null;
      return list == null
          ? const TopicsResult.failed()
          : TopicsResult.saved(list);
    }
    final e = d is Map ? _str(d['error']) : null;
    return TopicsResult.failed(r.statusCode == 400 ? e : null);
  }

  @override
  Future<DismissResult> dismissFeedItem(String id) async {
    final r = await _call(
      'POST',
      '/musey/feed/${Uri.encodeComponent(id)}/dismiss',
    );
    if (_ok(r)) return DismissResult.done;
    return r?.statusCode == 404 ? DismissResult.gone : DismissResult.failed;
  }

  @override
  Future<String?> react(String text) async {
    final r = await _call('POST', '/musey/react', data: {'text': text});
    if (!_ok(r)) return null;
    final d = r!.data;
    return d is Map ? _str(d['emoji']) : null;
  }

  @override
  Future<bool> refreshFeed() async {
    final r = await _call('POST', '/musey/feed/refresh');
    if (!_ok(r)) return false;
    final d = r!.data;
    return d is Map ? d['started'] != false : true;
  }

  @override
  Future<bool> like(String id, {required bool liked}) async => _ok(
    await _call(
      'POST',
      '/musey/feed/${Uri.encodeComponent(id)}/like',
      data: {'liked': liked},
    ),
  );

  @override
  Future<List<IdeaItem>?> getIdeas() async {
    final r = await _call('GET', '/musey/ideas');
    return _ok(r) ? parseIdeas(r!.data) : null;
  }

  @override
  Future<bool> dismissIdea(String id) async => _ok(
    await _call('POST', '/musey/ideas/${Uri.encodeComponent(id)}/dismiss'),
  );

  @override
  Future<Uint8List?> fetchBytes(String path) async {
    final uri = Uri.tryParse(path);
    if (uri == null || uri.path.isEmpty) return null;
    final r = await _call(
      'GET',
      uri.path,
      query: uri.queryParameters.isEmpty ? null : uri.queryParameters,
      responseType: ResponseType.bytes,
    );
    if (!_ok(r)) return null;
    final d = r!.data;
    if (d is Uint8List && d.isNotEmpty) return d;
    if (d is List<int> && d.isNotEmpty) return Uint8List.fromList(d);
    return null;
  }

  @override
  Future<LinkPreview?> linkPreview(String url) async {
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    final r = await _call('GET', '/musey/link-preview', query: {'url': url});
    return _ok(r) ? LinkPreview.fromJson(r!.data) : null;
  }
}

/// The relay client, or null when no Voice provider is set.
final museyFeedApiProvider = Provider<MuseyFeedApi?>((ref) {
  final voice = ref.watch(directVoiceProviderProvider);
  if (voice == null) return null;
  return DioMuseyFeedApi(ref);
});

/// Where icons, link images and link cards are kept on disk.
final museyCacheDirProvider = Provider<Future<Directory?> Function()>((ref) {
  return () async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/musey_cache');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  };
});

String _fileKey(String text) => sha1.convert(utf8.encode(text)).toString();

/// Bytes of relay paths and link previews, kept on disk so a restart does not
/// fetch them again, and in memory for the session. Misses and failures are
/// remembered for the session only.
class MuseyAssetCache {
  MuseyAssetCache(this._ref);

  final Ref _ref;
  final Map<String, Future<Uint8List?>> _bytes = {};
  final Map<String, Future<LinkPreview?>> _previews = {};

  Future<File?> _file(String name) async {
    final dir = await _ref.read(museyCacheDirProvider)();
    return dir == null ? null : File('${dir.path}/$name');
  }

  /// The bytes at relay [path], from disk or the relay; null when neither.
  Future<Uint8List?> bytes(String path) => _bytes.putIfAbsent(path, () async {
    final file = await _file('a_${_fileKey(path)}');
    try {
      if (file != null && file.existsSync()) {
        final data = await file.readAsBytes();
        if (data.isNotEmpty) return data;
      }
    } catch (_) {}
    final api = _ref.read(museyFeedApiProvider);
    final data = await api?.fetchBytes(path);
    if (data == null) return null;
    try {
      await file?.writeAsBytes(data, flush: true);
    } catch (_) {}
    return data;
  });

  /// The preview of [url], from disk or the relay; null when empty or failed.
  Future<LinkPreview?> preview(String url) =>
      _previews.putIfAbsent(url, () async {
        final file = await _file('p_${_fileKey(url)}.json');
        try {
          if (file != null && file.existsSync()) {
            final cached = LinkPreview.fromJson(
              jsonDecode(await file.readAsString()),
            );
            if (cached != null) return cached;
          }
        } catch (_) {}
        final api = _ref.read(museyFeedApiProvider);
        final fresh = await api?.linkPreview(url);
        if (fresh == null) return null;
        try {
          await file?.writeAsString(jsonEncode(fresh.toJson()), flush: true);
        } catch (_) {}
        return fresh;
      });
}

final museyAssetCacheProvider = Provider<MuseyAssetCache>(MuseyAssetCache.new);
