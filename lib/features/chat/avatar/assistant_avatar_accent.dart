import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'assistant_activity.dart';
import 'assistant_avatar_media.dart';

const String _logScope = 'chat/avatar';

/// Hue buckets of 15 degrees.
const int _hueBins = 24;

/// Picks the most prominent vivid color from straight-alpha RGBA pixels.
///
/// Pixels are bucketed by hue; only saturated, not-too-dark pixels count, so
/// white or near-white backgrounds, grays and shadows never win. Each pixel
/// weighs its saturation squared, favoring mid to high brightness. The best
/// window of three neighboring buckets wins, and its pixels are averaged.
/// Returns null when vivid pixels cover under 4% of the opaque area, which
/// keeps a mostly gray avatar on the neutral bubbles.
Color? dominantVividColor(Uint8List rgba) {
  final weights = List<double>.filled(_hueBins, 0);
  final counts = List<int>.filled(_hueBins, 0);
  final reds = List<double>.filled(_hueBins, 0);
  final greens = List<double>.filled(_hueBins, 0);
  final blues = List<double>.filled(_hueBins, 0);
  var opaque = 0;

  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    opaque += 1;
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    if (max == 0) continue;
    final delta = max - min;
    final saturation = delta / max;
    final value = max / 255;
    if (saturation < 0.3 || value < 0.2) continue;

    double hue;
    if (max == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (max == g) {
      hue = 60 * (((b - r) / delta) + 2);
    } else {
      hue = 60 * (((r - g) / delta) + 4);
    }
    if (hue < 0) hue += 360;
    final bin = (hue / 360 * _hueBins).floor() % _hueBins;
    final weight = saturation * saturation * (1 - (value - 0.7).abs());
    weights[bin] += weight;
    counts[bin] += 1;
    reds[bin] += r * weight;
    greens[bin] += g * weight;
    blues[bin] += b * weight;
  }
  if (opaque == 0) return null;

  var bestCenter = -1;
  var bestWeight = 0.0;
  for (var center = 0; center < _hueBins; center += 1) {
    var sum = 0.0;
    for (var offset = -1; offset <= 1; offset += 1) {
      sum += weights[(center + offset + _hueBins) % _hueBins];
    }
    if (sum > bestWeight) {
      bestWeight = sum;
      bestCenter = center;
    }
  }
  if (bestCenter < 0 || bestWeight <= 0) return null;

  var count = 0;
  var red = 0.0;
  var green = 0.0;
  var blue = 0.0;
  for (var offset = -1; offset <= 1; offset += 1) {
    final bin = (bestCenter + offset + _hueBins) % _hueBins;
    count += counts[bin];
    red += reds[bin];
    green += greens[bin];
    blue += blues[bin];
  }
  if (count < opaque * 0.04) return null;
  return Color.fromARGB(
    255,
    (red / bestWeight).round().clamp(0, 255),
    (green / bestWeight).round().clamp(0, 255),
    (blue / bestWeight).round().clamp(0, 255),
  );
}

/// [dominantVividColor] of a decoded image. The caller keeps ownership.
Future<Color?> dominantVividColorOfImage(ui.Image image) async {
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  if (data == null) return null;
  return dominantVividColor(data.buffer.asUint8List());
}

/// Decodes [bytes] at a thumbnail size and returns its vivid color.
Future<Color?> dominantVividColorOfEncoded(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
  try {
    final frame = await codec.getNextFrame();
    try {
      return await dominantVividColorOfImage(frame.image);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// Identity of [media]'s content: the path plus, for user files, size and
/// modification time, so a replaced clip is sampled again.
Future<String> assistantAvatarMediaCacheKey(AssistantAvatarMedia media) async {
  try {
    final stat = await File(media.path).stat();
    return '${media.id}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
  } catch (error, stackTrace) {
    DebugLogger.error(
      'accent-media-stat-failed',
      scope: _logScope,
      error: error,
      stackTrace: stackTrace,
    );
    return media.id;
  }
}

/// The media whose color the bubbles follow: the idle clip (what shows most
/// of the time), else the first state that has one.
AssistantAvatarMedia? assistantAvatarAccentSource(
  AssistantAvatarMediaSet media,
) {
  final idle = media.resolve(AssistantActivity.idle);
  if (idle != null) return idle;
  for (final state in AssistantActivity.values) {
    final found = media.ownMedia(state);
    if (found != null) return found;
  }
  return null;
}

/// The color derived from the avatar's media, null when there is none yet
/// or it has no vivid color. Seeded from the device cache so the bubbles
/// are colored from the first frame after launch.
final assistantAvatarAutoAccentProvider =
    NotifierProvider<AssistantAvatarAutoAccent, Color?>(
      AssistantAvatarAutoAccent.new,
    );

/// Keeps the derived color in the device-level cache under
/// [PreferenceKeys.assistantAvatarAccentCache], stored as
/// `<media key>|#RRGGBB` (or `<media key>|none` when the media had no vivid
/// color), so it is worked out once per clip, not per launch.
class AssistantAvatarAutoAccent extends Notifier<Color?> {
  String? _cachedKey;

  /// The media key the current color was derived from, if any.
  String? get cachedKey => _cachedKey;

  @override
  Color? build() {
    final raw = PreferencesStore.getString(
      PreferenceKeys.assistantAvatarAccentCache,
    );
    if (raw == null) return null;
    final split = raw.lastIndexOf('|');
    if (split <= 0) return null;
    _cachedKey = raw.substring(0, split);
    final value = raw.substring(split + 1);
    if (value.length != 7 || !value.startsWith('#')) return null;
    final rgb = int.tryParse(value.substring(1), radix: 16);
    return rgb == null ? null : Color(0xFF000000 | rgb);
  }

  /// Stores [color] as the color of the media identified by [mediaKey].
  /// With [persist] false it holds for this session only (a failed video
  /// sample is retried on the next launch).
  Future<void> record(
    String mediaKey,
    Color? color, {
    bool persist = true,
  }) async {
    _cachedKey = mediaKey;
    state = color;
    DebugLogger.log(
      'accent-derived',
      scope: _logScope,
      data: {'color': color == null ? 'none' : _hex(color), 'persist': persist},
    );
    if (!persist) return;
    try {
      await PreferencesStore.put(
        PreferenceKeys.assistantAvatarAccentCache,
        '$mediaKey|${color == null ? 'none' : _hex(color)}',
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'accent-cache-write-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Forgets the color, when the avatar has no media to take one from.
  Future<void> clear() async {
    if (_cachedKey == null && state == null) return;
    _cachedKey = null;
    state = null;
    try {
      await PreferencesStore.put(
        PreferenceKeys.assistantAvatarAccentCache,
        null,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'accent-cache-clear-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static String _hex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}
