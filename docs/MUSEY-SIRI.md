# Ask Musey by voice (Siri, Shortcuts, Action button)

Dated 2026-11-07 (build 182). Plan: `~/srv/docs/IOS-SURFACES-PLAN.md` (slice 1, no CarPlay entitlement).

## Dean's go

Dean said yes on 2026-11-07: "Hey Siri, ask Musey <question>" (or the shortcut) works by voice, including in the car through the phone's Siri. Siri speaks Bobby's reply, and Omni shows it afterwards.

## Phrases

- "Ask Musey"
- "Ask Musey something"
- "Ask Bobby in Musey", "Talk to Musey", "Musey question" (added in case Siri mishears the name)

Siri may hear "Musi" or "Muse". Info.plist lists those and "Moosey" under `INAlternativeAppNames` with pronunciation hints; whether App Shortcut phrases match them is not verified (needs a device). A personal shortcut in the Shortcuts app named, for example, "Ask Bobby" can run the same action, with no app name to mishear.

Siri then asks "What do you want to ask Bobby?" and Dean says the question. A String parameter cannot sit inside an App Shortcut phrase (only entities and enums can), so "Ask Musey what is on today" in one breath is not available; if the phrase is followed by words Siri may still hear them as the question, but that is not promised. The same intent appears in the Shortcuts app as the action "Ask Musey" (one Question input, the reply as text output), so it can go on a widget or the Action button.

## How the question travels

Not a second path. `ios/Runner/AskMuseyIntent.swift` (intent, `openAppWhenRun = false`, runs in the app process) calls Dart over the channel `am.tamm.conduit/ask_musey`. `lib/platform/ask_musey.dart` opens the Omni chat and sends with the app's own `durableSend` and the chat's selected tools, exactly like typing in Omni, then watches that turn until it finishes.

Why not call the relay from Swift: the relay address and token are in the Open WebUI session held in Dart (the push keychain group holds only the routines server and the push key), and Bobby's tools run through that session. A raw relay call would have no tools, so "what is on my calendar" would fail. Dart is the one path that acts.

The Dart side tells native `ready` after sign-in (post-auth startup). Native waits up to 7 s for it on a cold start.

## Timeout rule

Everything is under 24 s (intents are cut off at about 30 s, unverified). Dart gets what is left minus 1.5 s and native has a hard cap on top. If the reply is not finished in time and the question was sent, Siri says: "Bobby is still thinking, it's in Musey." The reply lands in Omni as normal. If the question could not be sent (not ready, signed out, Omni off, Bobby already busy in that chat), Siri says so and does not claim it is in Musey.

Replies are read as words: code, links and markdown marks are dropped, and a reply over about 480 characters is cut at a sentence end with "The rest is in Musey."

## Card rule

Nothing is auto-confirmed and nothing answers a card. If Bobby's turn raises a confirmation card or question (the same prompt Musey shows in Omni), Siri says the card's own line followed by "Confirm it in Musey." and stops. The card stays pending in Omni; Open WebUI's live prompt times out after 2 minutes and then counts as declined, which is the safe side.

## What cannot be verified without a device

Checked here: Dart unit tests (`test/platform/ask_musey_test.dart`), `flutter analyze`, a Swift typecheck against the iPhone SDK. Not checked, needs Dean's phone:

- That iOS starts the app process and the Flutter engine for an intent with `openAppWhenRun = false`, and how long Dart takes to sign in (the 7 s ready wait is a guess; the first ask after a reboot or force-quit is the risk).
- The real intent time limit (24 s is under the commonly quoted 30 s).
- That Siri recognizes "Ask Musey" with the app name, and how it handles the follow-up question in the car.
- That Siri reads the dialog aloud on a locked phone (the app's data protection may block the Open WebUI session before first unlock).
- That a card from a real write turn is detected (it uses the same prompt the Omni composer shows).
- The Shortcuts action and the Action button.

## Files

`lib/platform/ask_musey.dart`, `lib/core/providers/app_startup_providers.dart` (reads the bridge after sign-in), `ios/Runner/AskMuseyIntent.swift` (new, in the Runner target), `ios/Runner/ConduitAppIntents.swift` (adds the App Shortcut), `ios/Runner/AppDelegate.swift` (configures the channel), `ios/Runner.xcodeproj/project.pbxproj` (lists the new file).
