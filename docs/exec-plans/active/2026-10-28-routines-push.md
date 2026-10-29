# Routines tab and routine push, 2026-10-28

Branch `feat/routines-push`, cut from `origin/main` (8e363bae, the Omni, voice and persona line). Server side: `~/srv/lan-relay/README.md`, sections "Push" and "Check-ins in the Omni chat".

## What is built

- Routines tab (replaces Upcoming) in the assistant sheet: all automations, soonest next run first, switch, last result from `GET /routines/last`, quiet hours (`/push/settings`), Notifications (permission, registration, Send test).
- Setting "Routines server URL" (`routines_server_url`), the chat relay address. Token is the Switchboard token. The default comes from the build: `--dart-define=ROUTINES_SERVER_URL=...` (Dean's value lives outside the repo, in `~/.config/conduit/defines.json`, used with `--dart-define-from-file`).
- Push without Firebase: `ios/Runner/PushBridge.swift` (permission, token, 32 byte key, actions, snooze), `ios/NotificationService/` (extension that opens the sealed `e` payload), Dart side in `lib/features/routines/`.
- Omni chat is fetched on foreground and on a `chat:message` event for it (`lib/features/chat/omni/omni_refresh.dart`).
- Omni idle gap ignores unsolicited assistant posts, so a reply to a routine's post after a long quiet starts a session.

## Signing

The extension needs App IDs `am.tamm.conduit.NotificationService` and `am.tamm.conduit.debug.NotificationService`, and `am.tamm.conduit` (and `.debug` if used) needs Push Notifications in its development profile. Xcode on SANDYJAR has no account signed in, so automatic signing cannot create them ("No Accounts"). The key group `$(AppIdentifierPrefix)am.tamm.conduit.push` needs no portal entry.

## Environment

`aps-environment` in the entitlements is `development`; the app reports `sandbox` or `production` by reading the embedded provisioning profile, because a Release build signed with a development profile gets sandbox tokens.

## Not verified

Nothing was tapped on the phone. Reply, Snooze, Done, the tap-to-open and the sealed text need a device with push signing in place.
