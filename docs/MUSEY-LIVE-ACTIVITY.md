# Musey Live Activity: next event (build 183, 2026-11-07)

Dean said yes on 2026-11-07. That yes includes the trade-off: a Live Activity payload is not sealed like the routine push (there is no Notification Service Extension for it). The content state reaches Apple readable, so Apple can read the event title and calendar name. Only the next event of the day is sent, nothing else.

Contract with the relay (names, keys, routes, schedule, switch): `~/srv/docs/LIVE-ACTIVITY.md` (written in the srv worktree `.claude/worktrees/agent-ab1e3c4fe0faed956/docs/LIVE-ACTIVITY.md` until it lands on srv main). Plan: `~/srv/docs/IOS-SURFACES-PLAN.md`.

## What the app does

The relay starts and updates the activity with push-to-start. The app only draws it and registers tokens.

- `ios/ConduitWidget/NextEventAttributes.swift`: `NextEventAttributes` (`label`; state `title`, `startISO`, `calendar`, `minutesUntil`, `emptyDay`). One file, compiled into the ConduitWidgetExtension (synced folder) and into Runner (listed in project.pbxproj by hand, path `ConduitWidget/NextEventAttributes.swift`).
- `ios/ConduitWidget/NextEventLiveActivity.swift`: Lock Screen (title, time and calendar, a system countdown to `startISO`, "Nothing else today" on an empty day) and Dynamic Island compact, minimal and expanded. Colors follow the other widgets (Musey blue, `WidgetBackground`, dark text in light mode). Registered in `ConduitWidgetBundle`.
- `ios/Runner/LiveActivityBridge.swift`: started from `attachBridges`. Watches `pushToStartTokenUpdates` (iOS 17.2+), `Activity<NextEventAttributes>.activityUpdates` and each activity's `pushTokenUpdates` and `activityStateUpdates`. Posts to `/push/live-activity/start-token`, `/update-token` (with the activity id) and `/remove` (when the activity ends or is dismissed). It reuses the relay address and bearer that PushBridge stores in the shared keychain ("relay", the same ones the snooze action uses) and `PushBridge.apsEnvironment()` for `env`. Tokens are resent when the app becomes active, because the relay address can reach the keychain from Dart after launch. No Dart code was needed, so there are no Dart tests for it.
- Info.plist: `NSSupportsLiveActivities = YES`. No frequent updates key.

## Needs a device (not verified)

- Push-to-start on a real iPhone on iOS 17.2 or later, and that the token arrives at the relay.
- Apple accepting the relay's payload (alert on start, `stale-date`), the sandbox topic, Apple's update budget, and whether a swipe-away returns 410.
- How the Lock Screen and Island look (only typechecked with `swiftc` against the iPhone SDK; no simulator, no Xcode build run for this change).
- Live Activities must be allowed for Musey in Settings (default on).
