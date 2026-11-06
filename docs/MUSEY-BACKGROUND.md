# Musey chat background

Dean's words: "Adding a 'background image/color' as a thing to add to the chat window which goes in the appearance tab with us being able to set. Maybe also a default option of something related to the gradient that isn't the color of the chat window but a nice thing that is color aligned if that makes sense."

## Options (Settings > Appearance > Chat background)

- Gradient (default, also on upgrade): a gentle top-to-bottom gradient from the theme.
- Color: "Theme default" (the gradient's bottom tone as a flat color) or one of 7 swatches, painted as a light wash over the page color.
- Image: a photo from the library, copied into app documents (`chat_background/`), cover-fit, with a page-colored scrim on top (0.62 dark, 0.72 light). "Remove" deletes the copy and returns to Gradient. A missing or unreadable file shows the gradient.
- None: exactly the old look (plain chat color). Choose this to undo the new default.

## How the gradient is derived, and why

Base is the chat window's own color (palette `background`). Top stop: the base with 3.5% (light) or 5% (dark) of the palette `primary`. Bottom stop: the base with 13% (light) or 17% (dark) of a hue that is `primary` blended 35% toward `accent`. So it is related to the page but never equal to it, it follows the theme and accent with no extra setting, and light themes get less tint than dark ones (tint on white shows sooner).

## Readability rule

Every painted stop must give the palette's text color 4.5:1 (and its muted text 4.5:1 where muted text already meets that on the plain page). If a stop would fall short it is pulled toward the page color until it passes (`chatBackgroundReadable`). No separate scrim is needed for gradient or color. Photos cannot be computed, so they get the fixed scrim above. Tests check every palette in both themes.

Measured (text on bottom stop): conduit light 19.0, dark 14.4; claude light 9.9, dark 7.2; t3_chat 10.7 / 9.5; catppuccin 6.0 / 8.5; tangerine 9.6 / 10.8. Conduit light is nearly flat (#F4F4F4) because its muted text is only 4.99:1 on white.

## Where it applies

Only behind the chat message list: one static layer at the bottom of the chat page body Stack (`ChatBackgroundLayer`), sized to the screen so the keyboard does not rescale it, in a `RepaintBoundary`, rebuilt only when the setting, theme or photo changes (not per frame or stream token). The top and bottom chrome fades take the background's edge color so they do not draw a plain band. Not the sidebar, sheets or other pages. The voice mode panel is an overlay inside the chat page, so it sits over the same background.

## Where to change it

`lib/features/chat/background/chat_background.dart` (tint constants, scrim, swatches, keys). UI: `lib/features/profile/widgets/chat_background_section.dart`. Tests: `test/features/chat/background/`.

## Lesson (build 176 to 177): iOS Appearance is native

Build 176 added Chat background only to the Flutter page (`app_customization_page.dart`). On iOS, Settings > Appearance is a native sheet built in `lib/core/services/native_sheet_hydration_service.dart` (`_applyNativeAppearanceDetail`), so Dean never saw it. Any setting added to a Flutter settings page must also be added to the native sheet (and its event handler in `lib/main.dart`, `_handleNativeSheetControlChanged`), or it does not exist on iOS.

Native rows now (below the palette): "Chat background" (Gradient, Color, Image, None); with Color, "Background color" (Theme default plus 7 named swatches); with Image, "Background photo" (Choose or Change photo, Remove photo). Ids are `chat-background-mode|color|photo` in `chat_background.dart`. Each change updates `chatBackgroundProvider` (live chat) and re-hydrates the sheet. Tests: `native_sheet_settings_event_test.dart`, `native_sheet_hydration_locale_test.dart`.

## Lesson from build 177: the photo row did nothing, and later rows stopped sticking

The Appearance sheet is a native UIKit sheet. "Choose photo" is a dropdown option, so the sheet stays on screen while Dart gets the event. `image_picker` presents from the root view controller, which is already presenting the sheet, so UIKit refuses and the plugin never answers. Two effects: nothing opened, and `_handleNativeSheetControlChanged` is serialized through `_nativeSheetControlQueue` in `lib/main.dart`, so the awaited pick that never finished held up every later row (palette, color scheme, language) until the app restarted. That is the likely cause of "claude and catppuccin won't stick" (the palette handler and `setPalette` themselves persist correctly, tested).

Rules, from build 178:
- Anything that must open over the app from the native sheet dismisses the sheet first (`NativeSheetBridge.instance.dismiss()`), waits `nativeSheetDismissSettle` (450 ms, because dismiss returns when the slide starts), then opens.
- Never await a user-paced action inside the control queue: start it with `unawaited`.
- A pick failure is logged (`chat/background`) and shown in a snack bar; a cancel changes nothing.
- Not testable without a device: that UIKit really presents the library after 450 ms, and the permission prompt.
