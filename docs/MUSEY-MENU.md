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

## Control the house (2026-11-06, build 179)

Dean: "Are there options in the wrench, can we add, like 'turn on the scenes' etc." That is step 2 of the Home Assistant plan (docs/ROADMAP.md in the relay repo): devices grouped by location as tappable picks, read live from Home Assistant, not written into code. First it was a fifth top row; then: "I think I want it under a thing." So there is no fifth row. The four rows stay, and "Control the house" (id `home_control`, house icon) is one entry inside Do a thing, first in that list (`groupMuseyActions` moves it to the front; the rest keep the relay's order).

It opens one list with headings: Scenes first (Arcade on, Arcade off, DDR cabinet on, DDR cabinet off, Daytime lights, Nighttime lights), then each room Home Assistant knows with an on and an off row per device, then his groups (All the lights, Downstairs, Downstairs lights). A device row shows its state at the end ("on now", "off now"); an offline plug has one greyed row marked "offline" that cannot be tapped. If Home Assistant is slow or down the row opens with "Can't reach your home right now" and the rest of the menu is unaffected.

How it stays live: the app names nothing. Options come from `GET /musey/actions` (the relay reads Home Assistant when the sheet loads, with a short time limit), each option may carry `group`, `hint` and `disabled`, and the app draws headings from `group` (`_buildGroupedChoice`). A tap sends `{pick: "<kind>|<id>|<on|off>"}` to `POST /musey/actions/compose`, which answers plain words ("Turn on Arcade") plus the invisible marker, like every other pick. A new plug, scene or room in Home Assistant appears next time the sheet opens, with no app change. The relay omits the row when the house switch is off or the action is not enabled, and older builds without this code put it under Do a thing anyway (unknown ids always land there).

Why a pick still gets a card, unlike chores and routine check-offs: Dean's decision for the house is that nothing skips a card. A pick builds the card for exactly that device or scene (no name matching), and the yes, read-back, log and undo are the normal ones.
