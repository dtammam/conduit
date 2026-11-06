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
