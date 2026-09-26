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

## Requirements

- macOS 14.6 or later
- An OpenAI or Google Gemini API key

## Install

Build and install into `/Applications` (replaces an older version and relaunches the app):

```bash
zsh scripts/build_and_install.sh
```

The script needs an Apple Development certificate for team `Y29LYS5D8M` and refuses to install a
version that is not newer than the installed one. Bump `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in Xcode and the matching `version` and `build_number` at the top of the
script together. Use `--build-only` for an unsigned test build.

You can also build and run `TinyAI.xcodeproj` from Xcode.

## Set up

1. Open **Settings → API** and paste an OpenAI and/or Gemini key. Keys are checked before they are
   saved.
2. In **Settings → Primary**, choose what the two result panels show: the built-in Translate or
   one of your actions.
3. When macOS asks, allow **Accessibility** and **Input Monitoring** for TinyAI (System Settings →
   Privacy & Security). The popup hotkey and Replace need both. Relaunch TinyAI after granting them.

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

The default is **GPT-6 Luna** with **Low** reasoning. In testing it was as accurate as higher
levels for translation and grammar, and faster. Use Medium or High for explanations and harder
tasks. Settings that refer to a model that is no longer supported switch to the default.

Model output has em dashes (—) replaced with hyphens (-); code is left unchanged.

## Privacy

- API keys are stored in the macOS Keychain.
- Text is sent to the selected provider only when an action runs: when you open the popup, or
  after a short pause while editing in the main window.

## Development

- Unit tests: `xcodebuild test -scheme TinyAI-UnitTests -destination 'platform=macOS'`
- Manual checks: open `scripts/manual-test-kit.html` in a browser. It has rich-text samples
  (lists, links, code, tables, a long text) with the expected result for each.
- Model catalog and request rules (reasoning, token budget): `ModelCatalog` and
  `LLMRequestPolicy` in `TinyAI/TranslationService.swift`.
- HTML handling: `RichTextHTMLParser` and `RichTextHTMLSanitizer` in
  `TinyAI/RichTextPayload.swift`. TinyAI parses HTML itself instead of using AppKit's importer,
  which crashes on macOS 27 for HTML with links.
