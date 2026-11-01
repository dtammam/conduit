# AGENTS.md: conduit-routines (Musey)

Dean's build of Conduit (Flutter, GPLv3), called **Musey** on his phone. The checkout is a clone of his PUBLIC fork `dtammam/conduit` (origin), with `cogwheel0/conduit` as `upstream`. Dean's work lives on the local branch `feat/routines-push`. The system it talks to (Open WebUI, the relays, Bobby) is documented in `~/srv`: start with `~/srv/docs/HANDOFF.md` and `~/srv/README.md`. Dean's global rules are in `~/.claude/CLAUDE.md`.

## Rules

- **Never push `feat/routines-push` or anything else to the public fork without asking Dean.** The fork is public and this branch is local only.
- **No personal data in anything public** (finances, names, routines, real chats, real expense text): not in code, tests, fixtures or commit messages. Tests use invented data.
- `clean/*` branches are upstream offers: depersonalized, default OFF, upstream conventions, and they never touch `dean:` files (signing, `scripts/dean-verify.sh`, display name, bundled clips). Upstream wants a discussion before PRs (cogwheel0/conduit#864); a PR only for what Dean accepts, text approved by him first.
- Commit on `feat/routines-push` with explicit paths and a lowercase `area: what changed` message, in the existing style (`chat:`, `launch:`, `share:`, `avatar:`). Fold fixups only on a clean tree, never while a build reads it.
- Feature files import the platform UI seam (`package:conduit/shared/widgets/platform_ui/platform_ui.dart`), never material or cupertino directly.
- Any send path that should act must pass the selected tools (`resolveSendToolIds`); Conduit's follow-up path sends none.

## Audio rules (learned the week of 2026-10-28)

- Never hold the audio session outside playback, recording or calls.
- Silent video (avatar clips) uses `mixWithOthers`, or opening Musey pauses other apps' audio.
- Deactivate with `notifyOthersOnDeactivation` so other apps resume.
- Nothing touches the audio session while composing.

## Build and install on Dean's iPhone (YOUNGKEY)

```bash
export PATH=/opt/homebrew/bin:$PATH      # Flutter, Dart, CocoaPods
cd ~/projects/conduit-routines
flutter analyze                          # run the analyzer and the touched tests first
scripts/dean-verify.sh                   # full local mirror of upstream CI (2 upstream test failures are baseline)
XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/Dean.xcconfig" flutter build ios --release
xcrun devicectl device install app --device 00008130-001A1C6420A1401C build/ios/iphoneos/Runner.app
```

`devicectl` error 4016 or state `unavailable` means the phone is off Wi-Fi or asleep: retry later. The classifier blocks Claude from installing toolchains; Dean runs those. Build and install only after the analyzer and the touched tests pass.

## Where to look

| Need | Read |
|---|---|
| Building from source | `docs/BUILDING.md` |
| The routines and push plan | `docs/exec-plans/active/` (`2026-10-28-routines-push.md`, `2026-10-21-handoff.md` for fork state and branches, `2026-10-20-message-reactions.md` for the design) |
| What the server does for this app, ports, profiles | `~/srv/README.md`, `~/srv/docs/ARCHITECTURE.md` |
| Current state of the whole system | `~/srv/docs/HANDOFF.md` |
