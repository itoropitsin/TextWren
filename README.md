# TinyAI

TinyAI is a small macOS app for everyday writing. It translates, fixes grammar, and runs your own
prompts on any text, either in its own window or right where you are typing.

- **Popup in any app.** Select text, press **⌘C twice**, get the result, then **Replace** the
  selection or **Copy** it.
- **Main window** for longer text, with results that update as you type.
- **Formatting is kept.** Lists, links, bold, italic and code survive the round trip to the model
  and back, including when you paste into Slack, Notes or Google Docs.
- **Up to five custom actions** such as Grammar, Summarize or "Create task", each with its own
  model and reasoning level.
- **Voice dictation.** Hold a shortcut and speak into any app, with a local speech model (audio
  stays on your Mac) or OpenAI. A menu bar icon and popup show what is happening.
- **Agents and live conversation (Beta).** Ask remote agents (HTTP APIs or MCP servers) by voice
  and hear the answer, or talk live with GPT-Live-1 while it uses your tools.

## Requirements

- macOS 14.6 or later (Apple Silicon recommended for the on-device models)
- An OpenAI or Google Gemini API key, or none at all: the on-device text and speech models run
  without a key

## Install

1. Download `TinyAI.zip` from the [latest release](https://github.com/itoropitsin/TinyAI/releases/latest)
   and open it.
2. Move `TinyAI.app` to **Applications**.
3. The app is ad hoc signed, not notarized. If macOS blocks the first launch, Control-click
   `TinyAI.app` and choose **Open**, or use **System Settings → Privacy & Security → Open Anyway**.

### Build from source

Open `TinyAI.xcodeproj` in Xcode and run the `TinyAI` scheme. The build phase downloads the pinned
transcribe.cpp and llama.cpp frameworks into `Vendor/`. To compile the release app from the command
line without installing it, run:

```bash
zsh scripts/build_and_install.sh --build-only
```

Without `--build-only` the script signs the app, installs it into `/Applications`, replaces an
older version and relaunches it. It needs one of the maintainer's signing identities, described
below.

For the maintainer's Mac, the script uses the `TinyAI Local Code Signing` identity in the login Keychain.
It pins that certificate's SHA-1 fingerprint in the script so a different certificate with the
same name cannot silently sign an update. If that identity is unavailable, the script can use an
Apple Development certificate for team `Y29LYS5D8M`. The script refuses to install a version
that is not newer than the installed one. Bump `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in Xcode and the matching `version` and `build_number` at the top of the
script together. Use `--build-only` to compile without installing. For an ad hoc signed
release archive without a certificate, run `zsh scripts/sign_release_ad_hoc.sh /path/to/TinyAI.app`
after building and before creating the ZIP. Ad hoc signatures can change between builds, so macOS
may require Accessibility to be granted again after an update.

The local identity is for this Mac only. Keep its private key in the login Keychain, and back up
the certificate and private key securely before migrating to another Mac. Creating a new local
certificate changes the app's signing identity. Local signatures cannot be notarized or used for
public distribution. macOS still requires each permission to be granted initially; stable signing
only gives later updates a consistent code identity, and permission retention should be checked
on the target Mac after updating.
The local build uses a Library Validation runtime exception to load its bundled CTranscribe
framework because a self-signed certificate has no Apple Team ID. The framework is still signed
with the same local certificate and verified before installation. Apple Development builds use
the standard entitlements without this exception.

## Set up

1. Open **Settings → API** and paste an OpenAI and/or Gemini key. Keys are checked before they are
   saved. To stay fully offline, download the on-device models there instead.
2. In **Settings → Primary**, choose what the two result panels show: the built-in Translate or
   one of your actions.
3. When macOS asks, allow **Accessibility** for TinyAI (System Settings → Privacy & Security).
   The popup hotkey, voice shortcuts and Replace need it. If a previously enabled entry does not
   work after an update, remove it, add `/Applications/TinyAI.app`,
   enable it and relaunch.
4. For voice features, allow **Microphone** access when asked (or in **Settings → Voice**).

Settings are applied when you press **Save**; **Cancel** discards the changes.

## Use

### Popup

- Select text in any app and press **⌘C twice**. The hotkey and single/double press mode can be
  changed in **Settings → Hotkeys**.
- **Replace** returns to the original app and pastes the result over the selection. It does not
  paste if that app is no longer in front.
- **Copy** puts the result on the clipboard with formatting.
- Run other actions with the buttons or **⌘1 … ⌘5**.

### Main window

- Paste or type into **Source text**. A new request starts shortly after you stop typing and
  replaces any request still running.
- Choose a target language, or **Auto** to translate between your main and additional languages
  (set in **Settings → Primary**).

### Dictation

By default, hold **⌃V** and speak, or tap it to start and tap again to stop; **Esc** cancels. The text is
pasted where the cursor was, and your clipboard is put back afterwards. If no text field has focus,
the text appears in the popup under the menu bar icon with a **Copy** button. Shortcuts use the
physical key, so they work in any keyboard layout (⌃V and ⌃М are the same shortcut). Existing saved
shortcuts are preserved. Change the shortcut and engine in **Settings → Voice**:

| Engine | Model | Good for |
| --- | --- | --- |
| Local | [Voxtral Mini 4B Realtime](https://huggingface.co/handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf) | Live text, 13 languages. Examples: English, Mandarin, Hindi, Spanish, Arabic. Model weights need about 2.8 GB RAM, plus runtime memory. |
| Local | [Nemotron Streaming 3.5](https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf) | Fast live text, 28 languages in TinyAI. Examples: English, Mandarin, Hindi, Spanish, Arabic. Model weights need about 750 MB RAM, plus runtime memory. |
| Local | [Canary 180M Flash](https://huggingface.co/handy-computer/canary-180m-flash-gguf) | Small offline model. Its four languages are English, Spanish, French and German. Model weights need about 220 MB RAM, plus runtime memory. |
| OpenAI | GPT Live Transcribe (default) | Streams while you talk. [OpenAI list price](https://developers.openai.com/api/docs/pricing): $0.017/minute. |
| OpenAI | GPT Transcribe | Transcribes after recording stops. [OpenAI list price](https://developers.openai.com/api/docs/pricing): $0.0045/minute. |

When a new installation has neither an OpenAI API key nor a downloaded local model, TinyAI offers
to download Nemotron for local dictation. Download and RAM figures are approximate; actual memory
use depends on the runtime and recording length.

Local models are the ones Handy uses, run with transcribe.cpp on the Mac's GPU. Download them in
**Settings → Voice** or **Settings → API**; each file is checked against a pinned SHA-256 and stored in
`~/Library/Application Support/TinyAI/Models`. Audio for local models never leaves the Mac.

### Agents (Beta)

Agents and live conversation are a beta. Turn them on in **Help → Agents and live conversation
(Beta)**; this adds the **Agents** and **Live** tabs to Settings and their shortcuts to the menu
bar.

**Settings → Agents** has two lists:

- **Connections**: an **HTTP API** (URL, method, JSON body template, and the path to the answer
  in the response) or an **MCP server** (Streamable HTTP). Authorization is either a secret
  header stored in the Keychain, or, for MCP servers, **Sign in with browser**: OAuth in your
  default browser with automatic client registration. **Test & load tools** lists the server's
  tools.
- **Agents**: each has its own voice shortcut and a connection (for MCP, the tool and a JSON
  arguments template). Templates can use `{{transcript}}`, `{{sessionId}}`, `{{language}}` and
  `{{agent}}`. Follow-ups within the configured minutes reuse the same `{{sessionId}}`.

Hold an agent's shortcut and ask. The answer can appear in a floating panel, be pasted at the
cursor, be copied, and be spoken with an OpenAI voice (with a style prompt) or a macOS voice.
Requests wait up to the connection's timeout, so agents can think before answering.

### Live conversation (Beta)

**Settings → Live** sets a shortcut that starts and ends a full-duplex conversation with
**GPT-Live-1**. It keeps talking while its backend model (for example GPT-6 Luna) reasons and
calls tools: web search, the tools of the MCP servers you pick, and your agents. Tool calls run
on the Mac with each connection's sign-in. The transcript can be shown in a panel.

### Menu bar

The menu bar icon shows the state: ready, recording (red, pulsing), transcribing, an agent
thinking, speaking, live, or an error (orange). While you record, a popup under the icon shows the
microphone level and the text as it is recognised; errors appear there too.

The menu starts dictation (and, with the beta on, agents or a live conversation), cancels the
current one, lists the **five most recent transcripts** (click one to copy it), shows the last
agent answer and the model download progress.

### Custom actions

Create up to five actions in **Settings → Actions**: a title, a prompt, a model and a reasoning
level. The text you select is treated as input for the prompt: requests or questions inside it are
processed, not answered.

- `{{targetLanguage}}` in a prompt is replaced with the language chosen in the menu.
- **Settings → Style** adds shared tone or terminology to the actions you pick.

Example prompts:

| Action | Prompt |
| --- | --- |
| Summary | Summarize in 3 bullet points, under 60 words. |
| Polite email | Rewrite as a polite, concise email. Keep names, dates and action items. |
| Shorter | Make the text about half as long without losing meaning. |

## Models

TinyAI supports a fixed set of models, each with the reasoning levels its provider accepts.

| Provider | Models |
| --- | --- |
| OpenAI | GPT-6 Luna, GPT-6 Sol, GPT-6 Astra, GPT-5.6 Luna, GPT-5.6 Terra, GPT-5.6 Sol, GPT-5.5 |
| Google Gemini | Gemini 3.8 Flash, Gemini 3.5 Flash-Lite, Gemini 3.1 Pro |
| On-device | Qwen3.5 4B (2.7 GB download, about 3 GB RAM while loaded) |

The default is **GPT-6 Luna** with **Low** reasoning. In testing it was as accurate as higher
levels for translation and grammar, and faster. Use Medium or High for explanations and harder
tasks. Settings that refer to a model that is no longer supported switch to the default.

**Qwen3.5 4B** runs on this Mac with llama.cpp, needs no API key, and the text never leaves the
device. Download it in Settings → API, then pick it for translation or any action. In a blind
comparison with GPT-6 Luna (Low) it scored 4.7 vs 4.8 of 5 for grammar but 3.8 vs 4.9 for
translation. Reasoning is Off by default (it scored best). Low, Medium and High turn thinking on
with a growing budget and are much slower. Typical wait for a sentence or two on Apple Silicon:

| Reasoning | Wait |
| --- | --- |
| Off | 1.5–2.5 s |
| Low | about 30 s |
| Medium | about 2 min |
| High | about 6 min |

The model loads on first use and is freed after five idle minutes.

Model output has em dashes (—) replaced with hyphens (-); code is left unchanged.

## Privacy

- API keys, connection header values and OAuth tokens are stored in the macOS Keychain.
- The microphone records only while a voice shortcut is active or a live conversation runs.
  With a local model, audio stays on the Mac; with OpenAI, the recording goes to OpenAI; agent
  requests send only the transcript to your connection.
- Text is sent to the selected provider only when an action runs: when you open the popup, or
  after a short pause while editing in the main window.

## Development

- Unit tests: `xcodebuild test -scheme TinyAI-UnitTests -destination 'platform=macOS'`
  (CI runs them and the `--build-only` release build on every PR: `.github/workflows/tests.yml`)
- Manual checks: open `scripts/manual-test-kit.html` in a browser. It has rich-text samples
  (lists, links, code, tables, a long text) with the expected result for each.
- Model catalog and request rules (reasoning, token budget): `ModelCatalog` and
  `LLMRequestPolicy` in `TinyAI/TranslationService.swift`.
- Local speech engine: `scripts/fetch_transcribe_cpp.sh` downloads the pinned transcribe.cpp
  framework into `Vendor/` (the build script and the Xcode build phase run it).
  `scripts/fetch_llama_cpp.sh` does the same for llama.cpp, which runs the on-device text model
  (`LocalLLMEngine` in `TinyAI/LocalLLM.swift`); its tests in `LocalLanguageModelTests` run only
  when the model is downloaded. The local-engine
  tests in `TinyAITests/VoiceFeatureTests.swift` run only when the model files are downloaded.
- Voice logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "IT.TinyAI"' --style compact`
  shows hotkeys, recording level, transcripts and failures.
- Voice flow: `VoiceCoordinator` (hotkeys → recording → transcription → dictation, agents, live),
  `MCPClient`, `OAuthBrowserAuthorizer`, `HTTPAgentClient`, and the GPT-Live wire format in
  `LiveProtocol`.
- HTML handling: `RichTextHTMLParser` and `RichTextHTMLSanitizer` in
  `TinyAI/RichTextPayload.swift`. TinyAI parses HTML itself instead of using AppKit's importer,
  which crashes on macOS 27 for HTML with links.

## License

TinyAI is released under the [MIT License](LICENSE). The bundled transcribe.cpp and llama.cpp
frameworks and the downloaded models keep their own licenses.
