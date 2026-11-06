import 'dart:async';
import 'dart:io';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../shared/theme/color_tokens.dart' show contrastRatio;
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/theme/tweakcn_themes.dart';

// Musey chat background. Design and the reasons for the numbers are in
// docs/MUSEY-BACKGROUND.md. To change the look, edit the constants and
// [chatBackgroundGradientColors] below; nothing else decides colors.

/// Which background sits behind the chat message list.
enum ChatBackgroundMode { gradient, color, image, none }

const String kChatBackgroundModeKey = 'musey_chat_background_mode_v1';
const String kChatBackgroundColorKey = 'musey_chat_background_color_v1';
const String kChatBackgroundImageKey = 'musey_chat_background_image_v1';

/// Subfolder of the app documents directory that holds the chosen photo.
const String kChatBackgroundFolder = 'chat_background';

/// Text must keep this contrast against every background we paint.
const double kChatBackgroundMinContrast = 4.5;

/// Swatches for the Color option (ARGB). Painted as a light wash over the
/// theme's page color, so they stay quiet in both themes.
const List<int> kChatBackgroundSwatches = <int>[
  0xFF64748B, // slate
  0xFF3B82F6, // blue
  0xFF14B8A6, // teal
  0xFF22C55E, // green
  0xFFF59E0B, // amber
  0xFFF43F5E, // rose
  0xFF8B5CF6, // violet
];

/// The user's choice. [colorValue] null means "theme default" (the gradient's
/// middle tone as a flat color). [imageName] is a file name inside
/// [kChatBackgroundFolder], never a full path: the app container path changes
/// between installs.
@immutable
class ChatBackgroundSettings {
  const ChatBackgroundSettings({
    this.mode = ChatBackgroundMode.gradient,
    this.colorValue,
    this.imageName,
  });

  final ChatBackgroundMode mode;
  final int? colorValue;
  final String? imageName;

  ChatBackgroundSettings copyWith({
    ChatBackgroundMode? mode,
    int? colorValue,
    bool clearColor = false,
    String? imageName,
    bool clearImage = false,
  }) => ChatBackgroundSettings(
    mode: mode ?? this.mode,
    colorValue: clearColor ? null : (colorValue ?? this.colorValue),
    imageName: clearImage ? null : (imageName ?? this.imageName),
  );

  @override
  bool operator ==(Object other) =>
      other is ChatBackgroundSettings &&
      other.mode == mode &&
      other.colorValue == colorValue &&
      other.imageName == imageName;

  @override
  int get hashCode => Object.hash(mode, colorValue, imageName);
}

Color _lerp(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// Strength of the accent tint at the top and bottom of the default gradient.
/// Light themes take less tint than dark ones because tint on white shows
/// sooner than on black.
({double top, double bottom}) _tintFor(bool isDark) =>
    isDark ? (top: 0.05, bottom: 0.17) : (top: 0.035, bottom: 0.13);

/// Pulls [color] toward [page] until [foreground] reads on it at
/// [kChatBackgroundMinContrast]. Returns [color] unchanged when it already
/// does.
///
/// [muted] (secondary text) is held to the same bar only when it meets it on
/// the plain page already; a palette whose muted text is weak on its own page
/// is not made to pass here.
Color chatBackgroundReadable(
  Color color, {
  required Color page,
  required Color foreground,
  Color? muted,
}) {
  final guardMuted =
      muted != null && contrastRatio(muted, page) >= kChatBackgroundMinContrast;
  var out = color;
  for (var i = 0; i < 20; i++) {
    if (contrastRatio(foreground, out) >= kChatBackgroundMinContrast &&
        (!guardMuted ||
            contrastRatio(muted, out) >= kChatBackgroundMinContrast)) {
      return out;
    }
    out = _lerp(out, page, 0.2);
  }
  return page;
}

/// The default gradient's colors, top to bottom, for one theme variant.
///
/// Page color (the chat window's own color) is the base. The top is the page
/// with a whisper of the palette's primary; the bottom adds more of the
/// primary blended toward the palette's accent, so the gradient follows the
/// accent choice. Both stops are then checked against the text color and
/// pulled back toward the page if they would drop under 4.5:1.
List<Color> chatBackgroundGradientColors(TweakcnThemeVariant v, bool isDark) {
  final tint = _tintFor(isDark);
  final hue = _lerp(v.primary, v.accent, 0.35);
  final top = chatBackgroundReadable(
    _lerp(v.background, v.primary, tint.top),
    page: v.background,
    foreground: v.foreground,
    muted: v.mutedForeground,
  );
  final bottom = chatBackgroundReadable(
    _lerp(v.background, hue, tint.bottom),
    page: v.background,
    foreground: v.foreground,
    muted: v.mutedForeground,
  );
  return <Color>[top, bottom];
}

/// The flat color for the Color option. [colorValue] null is the theme
/// default (the gradient's bottom tone).
Color chatBackgroundFlatColor(
  TweakcnThemeVariant v,
  bool isDark,
  int? colorValue,
) {
  if (colorValue == null) return chatBackgroundGradientColors(v, isDark).last;
  final wash = _lerp(v.background, Color(colorValue), isDark ? 0.30 : 0.22);
  return chatBackgroundReadable(
    wash,
    page: v.background,
    foreground: v.foreground,
    muted: v.mutedForeground,
  );
}

/// Opacity of the page-colored scrim laid over a photo.
double chatBackgroundImageScrim(bool isDark) => isDark ? 0.62 : 0.72;

/// The colors the top and bottom chrome fades should use so they melt into
/// the background instead of drawing a band of the plain page color.
({Color top, Color bottom}) chatBackgroundEdgeColors(
  ChatBackgroundSettings s,
  TweakcnThemeVariant v,
  bool isDark,
) {
  switch (s.mode) {
    case ChatBackgroundMode.gradient:
      final c = chatBackgroundGradientColors(v, isDark);
      return (top: c.first, bottom: c.last);
    case ChatBackgroundMode.color:
      final c = chatBackgroundFlatColor(v, isDark, s.colorValue);
      return (top: c, bottom: c);
    case ChatBackgroundMode.image:
    case ChatBackgroundMode.none:
      return (top: v.background, bottom: v.background);
  }
}

/// Holds and saves the choice. Same store the other Appearance settings use
/// ([PreferencesStore]).
class ChatBackgroundNotifier extends Notifier<ChatBackgroundSettings> {
  @override
  ChatBackgroundSettings build() {
    try {
      final modeName = PreferencesStore.getString(kChatBackgroundModeKey);
      final mode = ChatBackgroundMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => ChatBackgroundMode.gradient,
      );
      final colorRaw = PreferencesStore.getString(kChatBackgroundColorKey);
      final image = PreferencesStore.getString(kChatBackgroundImageKey);
      return ChatBackgroundSettings(
        mode: mode,
        colorValue: colorRaw == null ? null : int.tryParse(colorRaw),
        imageName: (image == null || image.isEmpty) ? null : image,
      );
    } catch (_) {
      return const ChatBackgroundSettings();
    }
  }

  void setMode(ChatBackgroundMode mode) {
    state = state.copyWith(mode: mode);
    _put(kChatBackgroundModeKey, mode.name);
  }

  /// Picks a swatch, or null for the theme default.
  void setColor(int? colorValue) {
    state = state.copyWith(
      mode: ChatBackgroundMode.color,
      colorValue: colorValue,
      clearColor: colorValue == null,
    );
    _put(kChatBackgroundModeKey, ChatBackgroundMode.color.name);
    if (colorValue == null) {
      _remove(kChatBackgroundColorKey);
    } else {
      _put(kChatBackgroundColorKey, colorValue.toString());
    }
  }

  /// Copies [source] into app documents and switches to the Image option.
  /// Returns false when the copy failed (the setting is left as it was).
  Future<bool> setImageFrom(File source) async {
    try {
      final dir = await ref.read(chatBackgroundDirectoryProvider.future);
      final folder = Directory(p.join(dir.path, kChatBackgroundFolder));
      await folder.create(recursive: true);
      var ext = p.extension(source.path).toLowerCase();
      if (ext.isEmpty || ext.length > 6) ext = '.jpg';
      final name = 'bg_${DateTime.now().millisecondsSinceEpoch}$ext';
      await source.copy(p.join(folder.path, name));
      await _deleteImage(state.imageName);
      state = state.copyWith(mode: ChatBackgroundMode.image, imageName: name);
      _put(kChatBackgroundModeKey, ChatBackgroundMode.image.name);
      _put(kChatBackgroundImageKey, name);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Deletes the copied photo and returns to the default gradient.
  Future<void> removeImage() async {
    await _deleteImage(state.imageName);
    state = state.copyWith(mode: ChatBackgroundMode.gradient, clearImage: true);
    _put(kChatBackgroundModeKey, ChatBackgroundMode.gradient.name);
    _remove(kChatBackgroundImageKey);
  }

  Future<void> _deleteImage(String? name) async {
    if (name == null) return;
    try {
      final dir = await ref.read(chatBackgroundDirectoryProvider.future);
      final f = File(p.join(dir.path, kChatBackgroundFolder, name));
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  void _put(String key, String value) {
    try {
      unawaited(PreferencesStore.put(key, value));
    } catch (_) {}
  }

  void _remove(String key) {
    try {
      unawaited(PreferencesStore.remove(key));
    } catch (_) {}
  }
}

final chatBackgroundProvider =
    NotifierProvider<ChatBackgroundNotifier, ChatBackgroundSettings>(
      ChatBackgroundNotifier.new,
    );

/// Where the photo copy lives. Overridden in tests.
final chatBackgroundDirectoryProvider = FutureProvider<Directory>(
  (ref) => getApplicationDocumentsDirectory(),
);

/// The photo file, or null when none is set or it is gone from disk (the
/// layer then paints the gradient).
final chatBackgroundImageFileProvider = FutureProvider<File?>((ref) async {
  final name = ref.watch(chatBackgroundProvider.select((s) => s.imageName));
  if (name == null) return null;
  final dir = await ref.watch(chatBackgroundDirectoryProvider.future);
  final f = File(p.join(dir.path, kChatBackgroundFolder, name));
  return f.existsSync() ? f : null;
});

/// The static layer behind the chat message list.
///
/// Sized to the full screen, not the body, so the keyboard shrinking the body
/// does not rescale a photo or move the gradient. Wrapped in a
/// [RepaintBoundary] and watching only the setting, the theme and the photo
/// file: no per-frame or per-token rebuilds.
class ChatBackgroundLayer extends ConsumerWidget {
  const ChatBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(chatBackgroundProvider);
    if (settings.mode == ChatBackgroundMode.none) {
      return const SizedBox.shrink();
    }
    final theme = context.conduitTheme;
    final v = theme.variant;
    final isDark = theme.isDark;
    final height = MediaQuery.sizeOf(context).height;

    Widget gradient() => DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: chatBackgroundGradientColors(v, isDark),
        ),
      ),
    );

    Widget content;
    switch (settings.mode) {
      case ChatBackgroundMode.color:
        content = ColoredBox(
          color: chatBackgroundFlatColor(v, isDark, settings.colorValue),
        );
      case ChatBackgroundMode.image:
        final file = ref.watch(chatBackgroundImageFileProvider).value;
        content = file == null
            ? gradient()
            : _PhotoLayer(file: file, theme: theme, fallback: gradient());
      case ChatBackgroundMode.gradient:
      case ChatBackgroundMode.none:
        content = gradient();
    }

    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: RepaintBoundary(child: content),
        ),
      ),
    );
  }
}

class _PhotoLayer extends StatelessWidget {
  const _PhotoLayer({
    required this.file,
    required this.theme,
    required this.fallback,
  });

  final File file;
  final ConduitThemeExtension theme;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cacheWidth = (mq.size.width * mq.devicePixelRatio).round();
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        ),
        ColoredBox(
          color: theme.variant.background.withValues(
            alpha: chatBackgroundImageScrim(theme.isDark),
          ),
        ),
      ],
    );
  }
}
