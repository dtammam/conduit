# Musey action menu grouping

Dated 2026-11-06 (build 175).

## Why

Dean: "In the Actions menu there are too many immediate actions. Maybe we sub it to being 'Do a thing' -> Log a chore, expense, grocery stuff all there. Then 'Run a routine', put the routines inside. Then 'Check off a thing' -> check off a routine goes inside. Then 'Undo the last thing' is fine."

The wrench sheet used to list every catalog action at once. It now shows exactly four rows, in this order:

1. Do a thing: every action not placed below (log a chore, log an expense, grocery actions, calendar, quick note, and anything new).
2. Run a routine: `routine_start`.
3. Check off a thing: `routine_done`.
4. Undo the last thing: `undo`, acts immediately.

A group holding exactly one action opens that action directly (no one-row list). A group with several actions or none shows a list (or "Nothing here yet.") with a back chevron. Back from a form returns to where it came from.

## Where the grouping lives

The app groups by catalog id (`museyGroupById` in `lib/features/chat/musey/musey_actions_sheet.dart`). The relay (`GET /musey/actions`) is unchanged. Forms, picks and the composed chat message are unchanged: only navigation changed. The "/" shortcut and the widget tap open the same sheet and still work.

## Rule for a new action

- Do nothing and it lands under Do a thing. It cannot vanish.
- To put it elsewhere, add one entry to `museyGroupById`, then update the "each id has its home" test in `test/features/chat/musey/musey_test.dart`.
- Adding a fifth top row is a decision for Dean, not a default. (He was offered one for the house on 2026-11-06 and chose not to: see below.)

## Home widget taps

Dean: "can we make any part of the widget just open raw Musey without anything else. Right now it's either clipboard, audio, picture, camera, or action."

- M logo in the pill (76x56 tap area), and the widget's empty background: `conduit://open?homeWidget=true`. Opens the app as it was: no Omni switch, no menu, no voice, no composer action. Cold start is the normal launch (`MuseyWidgetAction.open`, handled by an early return in `home_widget_service.dart`).
- "Ask Musey" text area: `actions`, Omni with the wrench menu.
- Four buttons: camera, photos, mic (voice), clipboard, each in Omni.

### Taps swapped (2026-11-06, build 181)

Dean: "for the other widget, can we switch it so that if you press the little M, it brings you to the actions, and if you click into the Ask Musey, it's just text chat?"

Now the M in the pill opens `actions` (Omni with the wrench menu) and the "Ask Musey" text opens `conduit://type?homeWidget=true` (`MuseyWidgetAction.type`): Omni with the keyboard up, no menu, voice or attachment. It reuses the app's explicit-focus ask (`composerFocusIntentProvider`, the same one shares and Siri use), which the composer serves once Omni is open and the launch has settled, so cold start waits like every other action. The empty background stays `open` (plain app, no Omni switch). The four round buttons are unchanged. The history above stays as the earlier reason: the M used to be the "open raw Musey" tap and the text the menu; Dean swapped them. Whether the keyboard really rises on a cold start needs a device check.

## Control the house (2026-11-06, build 179)

Dean: "Are there options in the wrench, can we add, like 'turn on the scenes' etc." That is step 2 of the Home Assistant plan (docs/ROADMAP.md in the relay repo): devices grouped by location as tappable picks, read live from Home Assistant, not written into code. First it was a fifth top row; then: "I think I want it under a thing." So there is no fifth row. The four rows stay, and "Control the house" (id `home_control`, house icon) is one entry inside Do a thing, first in that list (`groupMuseyActions` moves it to the front; the rest keep the relay's order).

It opens one list with headings: Scenes first (Arcade on, Arcade off, DDR cabinet on, DDR cabinet off, Daytime lights, Nighttime lights), then each room Home Assistant knows with an on and an off row per device, then his groups (All the lights, Downstairs, Downstairs lights). A device row shows its state at the end ("on now", "off now"); an offline plug has one greyed row marked "offline" that cannot be tapped. If Home Assistant is slow or down the row opens with "Can't reach your home right now" and the rest of the menu is unaffected.

How it stays live: the app names nothing. Options come from `GET /musey/actions` (the relay reads Home Assistant when the sheet loads, with a short time limit), each option may carry `group`, `hint` and `disabled`, and the app draws headings from `group` (`_buildGroupedChoice`). A tap sends `{pick: "<kind>|<id>|<on|off>"}` to `POST /musey/actions/compose`, which answers plain words ("Turn on Arcade") plus the invisible marker, like every other pick. A new plug, scene or room in Home Assistant appears next time the sheet opens, with no app change. The relay omits the row when the house switch is off or the action is not enabled, and older builds without this code put it under Do a thing anyway (unknown ids always land there).

Why a pick still gets a card, unlike chores and routine check-offs: Dean's decision for the house is that nothing skips a card. A pick builds the card for exactly that device or scene (no name matching), and the yes, read-back, log and undo are the normal ones.

## Actions widget (2026-11-06, build 180)

Dean: "Can we make one more widget that's kind of reminiscent of the iOS shortcuts widget where we have all those cubes? ... basically all of the, like, do a thing, like control the house, do this, do that, like one tap over there, so I can easily from like the widget tap the action I want and be brought to like the sub menu and then immediately to a card. Separate from the [Musey] widget we have, this will be another additional widget."

A second widget in the same extension: gallery name "Musey Actions", kind `MuseyActionsWidget`, medium (5 columns by 2 rows) and large (2 columns by 5 rows). Code: `ios/ConduitWidget/MuseyActionsWidget.swift` (the folder is a file-system synced Xcode group, so the new file is picked up). The original "Musey" widget is unchanged. Each tile is a filled rounded square in its own color, SF Symbol top-left, label bottom-left, a `Link` over the whole tile. Sizes come from a GeometryReader so the smallest medium (about 292 by 141 pt) does not clip; medium labels are short and shrink to fit, large labels are full.

Tiles, in order (catalog id: medium label / large label / symbol):

1. home_control: House / Control the house / house
2. chore_log: Chore / Log a chore / checkmark.circle
3. expense_log: Expense / Log an expense / dollarsign.circle
4. grocery_add: Grocery / Add to a grocery list / cart.badge.plus
5. grocery_run: Run / Start a grocery run / cart
6. event_create: Calendar / Add to the calendar / calendar.badge.plus
7. note_quick: Note / Quick note / note.text
8. routine_start: Routine / Run a routine / play.circle
9. routine_done: Check off / Check off a routine / checkmark.square
10. more (no catalog id): More / All actions / square.grid.2x2, the existing wrench menu

How a tap works: a tile opens `conduit://actions?homeWidget=true&id=<catalog id>`. The app reads the id with `museyWidgetActionIdOf` (only `[a-z_]` up to 40 characters, anything else counts as no id), opens Omni like the other buttons, and raises the same menu ask the wrench pill uses, now carrying the id (`museyMenuIntentProvider`). The composer serves the ask once Omni is open and the launch settled, refreshes the catalog (`GET /musey/actions`, 5 second limit, the cached list still counts), finds the id (`resolveWidgetAction`) and calls `showMuseyActionsSheet(initial: action)`. Dean lands on that action's form or pick list; the form, pick, compose and card steps after that are unchanged (chores and routine check-offs keep their no-card behaviour; the house keeps its card). With `initial` set the sheet has no back chevron (existing rule); swiping the sheet down or finishing closes it.

Fallback rule: an unknown or unavailable id (the relay leaves out `home_control` when the house switch is off, or a new build renamed an id), or a catalog that cannot be had at all, opens the normal wrench menu. Never an error, never nothing. Cold start uses the existing pending-link path (router and chat readiness wait, then the same handler). An ask lives 20 seconds and its id is cleared when it is taken or expires, so a tile never reopens on a later launch; a newer plain ask drops an older tile's id.

Why undo is not a tile: Undo acts immediately with no card, so a stray tap on the home screen would undo a real thing. It stays one tap further, in More.

Why the list is fixed: WidgetKit does not fetch from the network at tap time, and the catalog lives on the relay. So the widget carries a fixed list of ids, labels and symbols, and the relay stays the source of truth for forms and labels. There is no app-group catalog sync (Dean did not ask for it). A new relay action reaches Dean through More as usual.

How to add a tile: add one `MuseyTile` to `museyTiles` in `MuseyActionsWidget.swift` (catalog id, short label, full label, SF Symbol, color). The grid is 5 by 2 and 2 by 5, so ten tiles fill it; an eleventh means changing the row counts in `MuseyActionsEntryView` and checking the smallest phone. The id must be `[a-z_]` only or the app ignores it. Nothing changes on the Dart side. Unproven until a device build: how the tiles look and that taps land (nothing here can tap a home screen widget).

The More tile wears the Musey M (build 181, Dean: "is there any way to incorporate the Musey logo anywhere in that widget, just so it's kind of obvious that it's from that?") instead of the grid symbol, drawn at the other icons' size in the same white. Its label and link are unchanged.
