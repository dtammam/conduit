import 'dart:math' as math;

import 'package:conduit/shared/theme/color_tokens.dart' show contrastRatio;
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../avatar/assistant_avatar_accent.dart';
import '../avatar/persona_appearance_service.dart';

/// Widest a reply bubble gets, as a share of the chat column.
const double kAssistantBubbleMaxWidthFactor = 0.85;

const Color _black = Color(0xFF000000);
const Color _white = Color(0xFFFFFFFF);

/// A preset the user can pick for their own bubbles instead of the color
/// derived from the avatar.
enum MessageBubbleSwatch {
  gold(Color(0xFFE0B030)),
  orange(Color(0xFFE07A30)),
  pink(Color(0xFFD8508E)),
  purple(Color(0xFF8E5CD8)),
  blue(Color(0xFF3E7BD8)),
  green(Color(0xFF4CAF50));

  const MessageBubbleSwatch(this.color);

  /// The base color; [toneBubbleAccent] adapts it to the theme.
  final Color color;

  /// The value stored in [AppSettings.assistantAvatarBubbleColor].
  String get storageValue => encodeBubbleColor(color);
}

/// `#RRGGBB` for [color].
String encodeBubbleColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// Parses a stored `#RRGGBB` choice; anything else (auto, gray, junk) is null.
Color? parseBubbleColor(String value) {
  if (value.length != 7 || !value.startsWith('#')) return null;
  final rgb = int.tryParse(value.substring(1), radix: 16);
  if (rgb == null) return null;
  return Color(0xFF000000 | rgb);
}

/// The base accent the user's bubbles take, or null for the neutral grays.
///
/// Null unless the assistant avatar is on. "Auto" follows the color derived
/// from the avatar's media (null while there is none), "Gray" is always
/// null, and a swatch is that swatch.
///
/// While "Match persona from Switchboard" is on and the active persona has a
/// bubble color, that color replaces the user's choice (the stored choice is
/// never overwritten); a persona without one leaves the user's choice alone.
final messageBubbleAccentProvider = Provider<Color?>((ref) {
  final (avatarOn, userChoice) = ref.watch(
    appSettingsProvider.select(
      (settings) => (
        settings.assistantAvatarEnabled,
        settings.assistantAvatarBubbleColor,
      ),
    ),
  );
  if (!avatarOn) return null;
  final choice =
      ref.watch(
        activePersonaAppearanceProvider.select(
          (persona) => persona?.bubbleColor,
        ),
      ) ??
      userChoice;
  if (choice == assistantAvatarBubbleColorGray) return null;
  if (choice == assistantAvatarBubbleColorAuto) {
    return ref.watch(assistantAvatarAutoAccentProvider);
  }
  return parseBubbleColor(choice);
});

/// The fills and text colors of both bubble kinds for one theme.
@immutable
class MessageBubbleColors {
  const MessageBubbleColors({
    required this.assistantFill,
    required this.userFill,
    required this.userText,
  });

  final Color assistantFill;
  final Color userFill;
  final Color userText;

  @override
  bool operator ==(Object other) =>
      other is MessageBubbleColors &&
      other.assistantFill == assistantFill &&
      other.userFill == userFill &&
      other.userText == userText;

  @override
  int get hashCode => Object.hash(assistantFill, userFill, userText);
}

typedef _ColorsKey = ({
  Color background,
  Color foreground,
  bool dark,
  Color? accent,
});

final Map<_ColorsKey, MessageBubbleColors> _colorsCache = {};

/// Bubble colors for [theme] with the user accent [accent] (null: grays).
///
/// With no accent the reply bubble is a dark gray and the user bubble a
/// lighter one on dark themes; light themes use a faint gray for replies and
/// a firmer one for the user. Both grays are mixed from the theme's own page
/// and text colors, so any theme gets matching neutrals. An accent is toned
/// for the theme and the text on it is black or white, whichever contrasts
/// more. Results are cached, so message builds do not redo the math.
MessageBubbleColors resolveMessageBubbleColors(
  ConduitThemeExtension theme,
  Color? accent,
) {
  final key = (
    background: theme.surfaceBackground,
    foreground: theme.textPrimary,
    dark: theme.isDark,
    accent: accent,
  );
  final cached = _colorsCache[key];
  if (cached != null) return cached;
  if (_colorsCache.length >= 8) _colorsCache.clear();
  return _colorsCache[key] = computeMessageBubbleColors(
    background: key.background,
    foreground: key.foreground,
    dark: key.dark,
    accent: accent,
  );
}

/// The uncached form of [resolveMessageBubbleColors].
MessageBubbleColors computeMessageBubbleColors({
  required Color background,
  required Color foreground,
  required bool dark,
  Color? accent,
}) {
  final assistantFill = Color.lerp(background, foreground, dark ? 0.12 : 0.06)!;
  if (accent == null) {
    return MessageBubbleColors(
      assistantFill: assistantFill,
      userFill: Color.lerp(background, foreground, dark ? 0.24 : 0.13)!,
      userText: foreground,
    );
  }
  final userFill = toneBubbleAccent(accent, dark: dark);
  return MessageBubbleColors(
    assistantFill: assistantFill,
    userFill: userFill,
    userText: bubbleTextColorOn(userFill),
  );
}

/// Tones [base] into a bubble fill: on dark themes a muted mid-dark shade
/// (a bright yellow becomes a darkish gold), on light themes a soft pastel.
Color toneBubbleAccent(Color base, {required bool dark}) {
  final hsl = HSLColor.fromColor(base);
  return dark
      ? hsl
            .withSaturation(math.min(hsl.saturation, 0.55))
            .withLightness(0.40)
            .toColor()
      : hsl
            .withSaturation(math.min(hsl.saturation, 0.70))
            .withLightness(0.78)
            .toColor();
}

/// Black or white, whichever has the higher contrast ratio on [fill]. One
/// of the two always reaches at least 4.58:1, so the text clears WCAG AA.
Color bubbleTextColorOn(Color fill) {
  return contrastRatio(fill, _black) >= contrastRatio(fill, _white)
      ? _black
      : _white;
}
