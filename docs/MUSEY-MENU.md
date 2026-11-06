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
- Adding a fifth top row is a decision for Dean, not a default.
