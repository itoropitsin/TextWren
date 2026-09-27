# AGENTS.md

Notes for AI coding agents (and people) working on TinyAI. The user-facing documentation is in
[README.md](README.md). This file covers how to build, test and change the code safely.

## Project at a glance

- A native macOS app in SwiftUI and AppKit, for macOS 14.6+. The project uses Swift 5 language
  mode with Xcode 27.
- Every source file sits flat in `TinyAI/`. There are no packages or subfolders.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) in `TinyAITests/`. UI tests are in
  `TinyAIUITests/`.
- Native engines are prebuilt frameworks in `Vendor/`, which git ignores. The build downloads them:
  - `scripts/fetch_transcribe_cpp.sh` downloads transcribe.cpp for local speech-to-text.
  - `scripts/fetch_llama_cpp.sh` downloads llama.cpp for the on-device text model.
  - Both scripts pin a release and check its SHA-256.

## Build and test

Full Xcode is required, not only the Command Line Tools. If `xcode-select` points at the CLT, prefix
commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
# Unit tests (the same command CI runs; no signing certificate needed)
xcodebuild test -scheme TinyAI-UnitTests -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=

# The release app via swiftc, without signing or installing
zsh scripts/build_and_install.sh --build-only

# Checks for the installer's version comparison
zsh scripts/test_build_and_install.sh
```

- CI (`.github/workflows/tests.yml`) runs the unit tests and the `--build-only` build on every PR.
  Both must pass.
- Tests that need downloaded speech or text models skip themselves when the models are missing.
- A fresh clone or git worktree has no `Vendor/`. Run both fetch scripts first, or let the Xcode
  build phase run them.
- xcodebuild prints a line saying XCTest executed 0 tests. Swift Testing reports separately:
  look for `Test run with N tests ... passed`.

## Rules that are easy to break

- **New Swift files must be added to `TinyAI.xcodeproj`.** The project uses explicit file
  references, not synchronized folders. `build_and_install.sh` compiles `TinyAI/*.swift` with
  `swiftc`, so a file missing from the project still builds there but fails in Xcode and CI.
- **MainActor by default.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set. Mark code that runs
  off the main thread as `nonisolated`. Examples are audio taps, the event-tap callback and the
  engines.
- **Imports are explicit.** `MemberImportVisibility` is on, so you must import the module that
  defines what you use. For example, `Timer.publish(...).autoconnect()` needs `import Combine`,
  even though SwiftUI is already imported.
- **Keep the two build paths in sync.** When you change Swift flags, upcoming features or linked
  frameworks in Xcode, change the `swiftc` call in `scripts/build_and_install.sh` too.
- **Versions live in two places.** Change `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the
  Xcode project together with `version` and `build_number` at the top of `build_and_install.sh`.
  The script refuses a mismatch. It also refuses to install over an equal or newer installed build,
  so bump `build_number` before a local install.
- **Do not use AppKit's HTML importer** (`NSAttributedString(html:)` and similar). It crashes on
  macOS 27 for HTML with links. Use `RichTextHTMLParser` and `RichTextHTMLSanitizer` in
  `RichTextPayload.swift`.
- **Keep `FirstMouseHostingView` concrete.** A generic `NSHostingView` subclass crashes the Swift 6.3
  Release optimizer.
- **Tests must not touch the user's settings.** Use `TinyAIRuntime.userDefaults` and check
  `TinyAIRuntime.isTestEnvironment`. Tests run with their own defaults suite and never prompt for
  permissions.
- **Secrets go to the Keychain** through `KeychainStore`. API keys, connection headers and OAuth
  tokens are never stored in `UserDefaults` or files.
- **Test data stays neutral.** Do not put real people, companies or private URLs in tests or UI
  placeholders.

## Where things are

| Area | Files |
| --- | --- |
| App entry, permissions, popup window | `TinyAIApp.swift` |
| Main window | `MainTranslationView.swift` |
| Popup | `TranslationPopupView.swift` |
| Settings | `SettingsView.swift`, `VoiceSettingsView.swift` |
| Global hotkeys (CGEvent tap) | `KeyboardMonitor.swift` |
| Model catalog, requests, prompts | `TranslationService.swift` (`ModelCatalog`, `LLMRequestPolicy`) |
| On-device text model (llama.cpp) | `LocalLLM.swift` |
| Model downloads, local speech-to-text | `LocalTranscription.swift` (`LocalModelManager`) |
| Voice flow | `VoiceCoordinator.swift`, `AudioCapture.swift`, `VoiceSettings*.swift` |
| Agents and live mode (beta) | `AgentDispatcher.swift`, `HTTPAgentClient.swift`, `MCPClient.swift`, `OAuthBrowserAuthorizer.swift`, `LiveAgentSession.swift`, `LiveProtocol.swift` |
| Rich text (HTML, RTF, Markdown) | `RichTextPayload.swift`, `MarkdownTextView.swift` |
| Paste and replace in other apps | `TextInserter.swift` |

## Permissions

- **Accessibility** covers both the global event tap and text replacement. No separate Input
  Monitoring grant is needed.
- **Microphone** is needed for voice.
- Signatures matter for both grants. The release is ad hoc signed, so macOS may keep a stale
  entry for an older build. The README and the Settings text explain how to reset it.

## Releases

1. Bump the version in both places (see above). Merge to `main` after CI passes.
2. Build the Release configuration with Xcode, ad hoc signed:
   `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=`.
3. Sign the bundle with `zsh scripts/sign_release_ad_hoc.sh /path/to/TinyAI.app`.
4. Package the zip: `ditto -c -k --sequesterRsrc --keepParent TinyAI.app TinyAI.zip`.
5. Write the checksum: `shasum -a 256 TinyAI.zip > SHA256SUMS.txt`.
6. Create a GitHub release `vX.Y.Z` on the merge commit, with both files attached.

The `TinyAI Local Code Signing` certificate used by `build_and_install.sh` works only on the
maintainer's Mac. Never use it for published builds.

## Style

- Code, comments, UI text, script output, commits and PRs are in English.
- Keep comments short and about *why*. Match the surrounding code.
- Model output has em dashes replaced with hyphens. Keep that behavior when you touch output
  handling.
- Keep PRs small and focused, and describe what changed, why, and how it was verified.
