# Message reactions for Conduit (Dean's fork)

Written 2026-10-20. Owner: Dean Tammam. Executing agents: Opus (build) and Sonnet (gate, tests, l10n). Aligner: the SANDYJAR host session.

## 1. The ask, in Dean's words

Dean uses Conduit on his iPhone against his own Open WebUI (model "Bobby"). Meta's Muse app lets him react to messages, and the app reacts to his. He wants two small things, nothing more:

1. **Quick-reply reactions.** When Bobby asks a question ("Save this expense?"), Dean long-presses the reply and taps a thumbs up instead of typing "yes" or "save it". The app sends the matching short message as a normal user turn. Thumbs down sends "no".
2. **Delivery receipts.** When Dean sends a message, the app shows a thumbs up on his bubble once the server has accepted it and the reply has started, and a red mark if it failed.

"I don't want it to be a very complex thing. The reaction is literally just a hook off of something that already exists."

Target: Dean's own build on his phone first; upstream pull requests second, so everything follows upstream's conventions from the first commit.

## 2. Repo facts (measured 2026-10-20)

- Upstream: `github.com/cogwheel0/conduit`, Flutter (Dart), GPLv3, 2,347 stars, version 4.2.1+152, default branch `main`.
- Fork: `github.com/dtammam/conduit`. Local clone `~/projects/conduit` with remotes `origin` (fork) and `upstream`. The two build submodules `third_party/katex` and `third_party/mermaid` are initialised. `openwebui-src` and `hermes-src` are reference-only submodules and are not initialised (not needed for this work).
- Lines of Dart under `lib/`: about 188,000. Pub workspace with `packages/conduit_core` (models, providers, no Flutter UI), `conduit_markdown`, `conduit_theme`, `conduit_ddgs`.
- Build: `docs/BUILDING.md`. Requires Flutter 3.47.0+ and Dart 3.13.0+. Codegen (`dart run build_runner build`) is mandatory before the analyzer works. iOS runs with `XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/ArmOnly.xcconfig" flutter run -d ios`. There is a `Podfile` and a `Gemfile` in `ios/`, so CocoaPods is needed for device builds.
- Gates upstream CI runs (`.github/workflows/ci.yml`): `flutter analyze --no-fatal-warnings --no-fatal-infos`, `dart run tool/run_test_shards.dart`, `dart tool/platform_ui_lint.dart --base-ref <base>`, `dart run tool/validate_arb_locales.dart`, `dart run tool/verify_arb_descriptions.dart`, `dart run tool/check_package_boundaries.dart`, per-package `dart test` and `dart analyze --fatal-infos`.
- Tests: `flutter_test` with `package:checks` and `mocktail`. Chat widget tests live under `test/features/chat/widgets/`.
- Conventions that bite: no raw `print` (use `DebugLogger` with a slash scope such as `chat/reactions`); every new string goes in `lib/l10n/app_en.arb` with an `@key` description (run the two ARB validators to learn whether other locales must mirror the key); new UI files must not import `material_ui` or `cupertino_ui` directly, they go through `lib/shared/widgets/platform_ui/platform_ui.dart` (the lint keeps an allowlist in `tool/platform_ui_allowlist.yaml` and new entries are not acceptable for a PR).

## 3. Where the hooks already are

| Need | Existing code |
|---|---|
| Long-press menu on an assistant message | `ConduitContextMenu` in `lib/shared/utils/conversation_context_menu.dart`. It already has an unused `topWidgetBuilder` slot, which is exactly where an iMessage-style reaction row goes. `AssistantMessageWidget` (`lib/features/chat/widgets/assistant_message_widget.dart`, 2,644 lines) builds its footer actions in a list of `_AssistantFooterAction` around line 2411 and exposes `onLike` and `onDislike` callbacks that `chat_page.dart` never wires (confirmed by grep). |
| Sending a user turn programmatically | `_sendMessage(text, includeComposerContext: ...)` in `lib/features/chat/views/chat_page.dart` line 1243. It returns `({bool admitted, bool dispatched})`. |
| Knowing whether a send was accepted or failed | The same return value, plus the following assistant `ChatMessage` (`packages/conduit_core/lib/models/chat_message.dart`): `isStreaming`, `error` (`ChatMessageError`), `statusHistory`. No new persistence is needed; receipts are derived state. |
| The user bubble | `UserMessageBubble` in `lib/features/chat/widgets/user_message_bubble.dart` (1,074 lines). Its actions come from `_buildMessageActions` (edit, copy). The footer under the bubble is where the receipt glyph goes. |
| Haptics | `ConduitHaptics.selectionClick()` in `lib/core/services/haptic_service.dart`. |
| Settings page for toggles | `lib/features/profile/views/app_customization_page.dart` (or `personalization_page.dart`; the builder picks whichever already holds chat display toggles and follows its pattern for the preference provider). |

## 4. Design (the minimum that does the job)

### 4.1 Quick-reply reactions (assistant messages)

- Long-press an assistant message. Above the existing context menu, a horizontal row of preset reactions appears via `topWidgetBuilder`: 👍 👎 ✅ ❌. On Android the same row shows at the top of the adaptive menu.
- Tapping one closes the menu, plays the selection haptic, and sends a normal user message through the existing `_sendMessage` path with `includeComposerContext: false`. Nothing else: no new API, no reaction stored on the server.
- The text sent per reaction is a small constant table in one new file, `lib/features/chat/reactions/quick_reply_reactions.dart`:

  | Reaction | Text sent (default) |
  |---|---|
  | 👍 | `Yes` |
  | 👎 | `No` |
  | ✅ | `Yes, do it.` |
  | ❌ | `Cancel.` |

  The sent message reads as a short confirmation, which is what Bobby's skills already accept in a confirmation turn. Dean may change the words before the build starts (open question 1).
- The row is hidden while the assistant message is still streaming, on read-only chats, on error messages, and on voice replies, using the same flags the footer already computes (`_responseCompleted`, `widget.readOnly`, `isErrorMessage`, `_isVoiceReply`).
- Optional, only if trivial after the above works: render a user message whose text exactly equals one of the table's texts as a compact pill (emoji plus word) instead of a full bubble. Not required for acceptance.

### 4.2 Delivery receipts (user messages)

- Under Dean's bubble, in the existing footer area, a small glyph driven by derived state:

  | State | Glyph |
  |---|---|
  | Send not yet admitted or dispatched | nothing (keep the UI quiet) |
  | Dispatched and the assistant message exists (streaming or done) with no error | 👍 small, muted |
  | `_sendMessage` returned not admitted or not dispatched, or the following assistant message carries `error` | ❌ small, in the theme's error colour |

- The glyph is computed from the message list in `chat_page.dart` and passed to `UserMessageBubble` as a plain enum parameter (`MessageReceipt { none, delivered, failed }`). No message model changes, no database changes, no network calls.
- Only the most recent user message in a thread needs a live receipt; older ones may show nothing (decision: show nothing on older turns to keep the list clean, unless the builder finds the computation is free for all turns).

### 4.3 Settings

Two toggles under the chat display settings, both default on in Dean's build: "Quick-reply reactions" and "Delivery receipts". For the upstream PRs the defaults are the maintainer's call; the toggles exist so either default is a one-line change. Stored with the same preference mechanism the page already uses.

### 4.4 Not in scope

No server-side reactions, no emoji picker, no reactions on user messages, no reaction history, no changes to Open WebUI, Switchboard, the relays or Bobby's skills, no Android-specific polish beyond "it works and lint passes".

## 5. Branches and pull requests

- Fork `main` mirrors `upstream/main` and is never committed to directly.
- Dean's integration branch is `dean`: it carries this plan, any harness files, and both features merged. His phone build comes from `dean`.
- Feature work happens on `feature/delivery-receipts` and `feature/quick-reply-reactions`, each branched from `upstream/main`, each a separate small PR (upstream prefers small PRs; receipts is the simpler one and goes first). Feature commits never touch `docs/exec-plans/` or harness files, so they cherry-pick cleanly onto an upstream-based branch.
- Commit messages follow upstream's style visible in `git log` (short imperative subject, PR number added by GitHub). Before opening a PR, read any `CONTRIBUTING` guidance and the latest merged PRs for the expected shape, and open the PR against `cogwheel0/conduit:main` from the fork.
- Pushing the fork's branches and opening PRs are Dean's calls, each time.

## 6. Steps for the executing agents

0. **Environment (Dean does these; they download software).** Install Flutter 3.47+ and CocoaPods, run `flutter doctor`, then in `~/projects/conduit`: `flutter pub get`, `dart run build_runner build`, `flutter analyze`, `dart run tool/run_test_shards.dart`. Record the baseline (analyzer clean, test count, duration) at the top of the progress log below. Do not start step 1 until the baseline passes unchanged.
1. **Receipts (Opus).** Add the `MessageReceipt` enum and the derivation in `chat_page.dart`, the glyph in `UserMessageBubble`, the setting, the ARB strings (for the accessibility labels), and a widget test for each state plus a unit test for the derivation. Gate: analyzer, test shards, platform UI lint, ARB validators.
2. **Quick replies (Opus).** Add `quick_reply_reactions.dart`, the row through `topWidgetBuilder`, the wiring to `_sendMessage`, the setting, ARB strings, a widget test that a tap sends the mapped text and that the row is hidden while streaming. Same gate.
3. **Gate (Sonnet, independent).** Refute by running the CI commands from section 2 locally, reading the diff for allowlist edits, raw prints, direct `material_ui`/`cupertino_ui` imports in new files, and any touch of the message model or database. Verdict bound to the sha.
4. **Phone build.** `XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/ArmOnly.xcconfig" flutter run -d <YOUNGKEY udid>` (the phone is paired over Wi-Fi; UDID in `~/srv/AGENTS.md`). Dean tests against Bobby: ask for an expense log, long-press the question, tap 👍, confirm the write happens; send a message with Switchboard mid-switch (503) and confirm ❌ appears.
5. **Upstream.** Cherry-pick each feature onto its `upstream/main` branch, re-run the gate, and hand Dean the PR text to approve.

## 7. Acceptance

- Long-press on a finished assistant reply shows the four reactions on iOS; tapping 👍 sends `Yes` as a user turn and Bobby proceeds. Measured on the phone, not the simulator.
- The row does not appear while streaming, on error replies, or in read-only chats.
- Dean's latest bubble shows 👍 once the reply starts and ❌ when the send is refused or the reply errors; nothing on older turns.
- Both toggles work and persist across app restarts.
- All CI commands in section 2 pass locally on each feature branch, with zero new allowlist entries and no changes under `packages/conduit_core/lib/models/`.
- `git diff upstream/main --stat` on each feature branch touches only the files this plan names plus tests and ARB files.

## 8. Risks and known unknowns

- Flutter 3.47 and Dart 3.13 are new enough that the installed SDK must be exactly checked with `flutter --version`; an older Flutter fails `pub get` on the sdk constraint.
- `CupertinoContextMenu` layout is fragile (the file's own comment says it can assert under flex parents); the reaction row must be fixed-height and must not change the preview child's size.
- Open WebUI's error shape varies (`ChatMessageError` already parses several); the receipt derivation must treat any non-null `error` as failed and nothing else.
- What Bobby's confirmation turn actually accepts as "yes" has not been tested through Conduit with a one-word reply; step 4 is where this is measured.
- Nothing here has been run yet: no Flutter SDK is installed on SANDYJAR as of 2026-10-20.

## 9. Open questions for Dean

1. The four reactions and their texts in section 4.1: keep, or change the words?
2. Receipt glyph: a thumbs up emoji as asked, or a plain checkmark in the theme colour (quieter, more upstream-friendly)? Default in this plan: thumbs up in Dean's build, both selectable later if upstream prefers.
3. Toolchain route: Homebrew (`brew install --cask flutter`, `brew install cocoapods`) or a manual Flutter zip plus `gem install --user-install cocoapods`? Homebrew is recommended; it needs Dean at the keyboard once for its installer.

## 10. Revision, 2026-10-20 evening (supersedes 4.1 and 4.2 where they differ)

Dean clarified after the first build: it must feel like an iMessage Tapback, and the first gate found the plan's long-press placement unreachable (Conduit shows the model header only on the first reply from a model in a conversation). Built behaviour:

- Long-press (400 ms, wins before `SelectionArea`'s 500 ms) anywhere on a finished assistant reply opens a floating pill with 👍 👎 ✅ ❌, built with `RawGestureDetector` plus `showGeneralDialog`, no `CupertinoContextMenu`. Picking one sends the mapped text through the follow-up send path. Known cost: long-press word selection on assistant replies is off while the setting is on (double-tap selection still works, measured in widget tests only).
- The reaction is a 22 px badge on the reply's top-trailing corner, derived from the next user message's text matching one of the four mapped texts exactly; that user turn renders as `SizedBox.shrink` while the setting is on. Not stored anywhere.
- Delivery receipts are the same badge style on Dean's bubble's top-leading corner: 👍 muted once the reply has content, a status or finished; ❌ on an error reply or an undispatched send. Only the latest visible user message carries one; the failed id clears on regenerate and on conversation switch.
- Settings: Settings, Chats (native page on iOS), last two rows of the chat behaviour group: "Delivery receipts", "Quick-reply reactions". Keys `delivery_receipts_enabled`, `quick_reply_reactions_enabled`, default on.
- Phone build: `XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/Dean.xcconfig" flutter build ios --release`, then `xcrun devicectl device install app --device 00008130-001A1C6420A1401C build/ios/iphoneos/Runner.app`. Signing (team, `am.tamm.conduit` ids, app group, entitlements, display name) lives only in the `dean:` commits.

## 11. Progress log

- 2026-10-20: upstream researched, fork created, clone and build submodules in place, this plan written. No code yet.
- 2026-10-20 15:40 to 16:30: Flutter 3.47.7 and CocoaPods 1.17.0 installed by Dean through Homebrew. Baseline on untouched upstream: analyzer 68 warnings and infos, 0 errors; shards 5,002 passed, 2 failed (`direct_send_history_links_test`, `sidebar_workspace_tabs_test`, both pre-existing). Opus built both features; gate one rejected the header-only long-press; rebuilt as Tapback (section 10). Final: analyzer clean, shards 5,023 passed, the same 2 baseline failures. Release build signed with Dean's team in 60 s incremental, installed on YOUNGKEY at 16:30. Gate two approved with notes; its two medium notes (a typed "Yes" with attachments must not hide; a failed reaction send must show ❌) were folded in. Final commits `64aa83c6` (receipts) and `54307fa4` (quick replies); shards 5,025 passed, same 2 baseline failures. Reinstalled on YOUNGKEY after that. Not yet verified on the phone by Dean.
