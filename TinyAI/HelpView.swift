import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var voiceStore: VoiceSettingsStore

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !short.isEmpty else { return "" }
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("TextWren Help")
                    .font(.title2.weight(.semibold))
                Text("Translate, fix and rewrite text without leaving the app you are in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HelpSection(title: "Get started", systemImage: "sparkles") {
                        HelpStep(number: 1, text: "Open **Settings → API** and paste an OpenAI or Google Gemini API key. TextWren checks the key before saving it.")
                        HelpStep(number: 2, text: "In **Settings → Primary**, choose what the two result panels show: Translate or one of your actions.")
                        HelpStep(number: 3, text: "Allow **Accessibility** when macOS asks, so the popup hotkey and Replace work in other apps.")
                    }

                    HelpSection(title: "Popup in any app", systemImage: "cursorarrow.rays") {
                        HelpBullet("Select text and press **⌘C twice** to open the popup. You can change the hotkey in Settings → Hotkeys.")
                        HelpBullet("**Replace** puts the result back in place of your selection; **Copy** copies it with formatting.")
                        HelpBullet("Run other actions with the buttons or with **⌘1 … ⌘5**.")
                    }

                    HelpSection(title: "Main window", systemImage: "macwindow") {
                        HelpBullet("Paste or type into **Source text**. Results update shortly after you stop typing.")
                        HelpBullet("Pick a language in the menu, or **Auto** to switch between your main and additional languages.")
                        HelpBullet("Formatting is kept: lists, links, bold, italic and code.")
                    }

                    HelpSection(title: "Voice dictation", systemImage: "mic.fill") {
                        HelpBullet("Hold the dictation shortcut (**fn⌃** by default) and speak, or tap it to start and tap again to stop. **Esc** cancels. Change the shortcut in **Settings → Voice**.")
                        HelpBullet("The text is pasted where the cursor is. With no text field focused, it appears in the popup under the menu bar icon with **Copy**.")
                        HelpBullet("Choose a local model (audio stays on your Mac) or OpenAI in **Settings → Voice**. The menu bar icon keeps your last five transcripts.")
                    }

                    HelpSection(title: "Agents and live conversation (Beta)", systemImage: "person.wave.2.fill") {
                        HelpBullet("Ask remote agents (HTTP APIs or MCP servers) by voice and hear the answer, or talk live with GPT-Live-1 while it uses your tools.")
                        Toggle(isOn: $voiceStore.agentsBetaEnabled) {
                            Text("Enable agents and live conversation")
                        }
                        .toggleStyle(.switch)
                        Text("Adds the **Agents** and **Live** tabs to Settings. This is a beta and may change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HelpSection(title: "Custom actions", systemImage: "bolt.fill") {
                        HelpBullet("Create up to five actions in **Settings → Actions**: a title, a prompt, a model and a reasoning level.")
                        HelpBullet("Use **{{targetLanguage}}** in a prompt to insert the language chosen in the menu.")
                        HelpBullet("**Settings → Style** adds shared tone or terminology to the actions you select.")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Example prompts")
                                .font(.subheadline.weight(.semibold))
                            HelpExample(title: "Summary", prompt: "Summarize in 3 bullet points, under 60 words.")
                            HelpExample(title: "Polite email", prompt: "Rewrite as a polite, concise email. Keep names, dates and action items.")
                            HelpExample(title: "Shorter", prompt: "Make the text about half as long without losing meaning.")
                        }
                        .padding(.top, 4)
                    }

                    HelpSection(title: "Models and reasoning", systemImage: "cpu") {
                        HelpBullet("Choose a model and a reasoning level for Translate and for each action.")
                        HelpBullet("**Low** is fast and enough for translation and grammar. Use **Medium** or **High** for explanations and harder tasks.")
                    }

                    Label {
                        Text("API keys are stored in the macOS Keychain. Text is sent to the selected provider only when an action runs.")
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            Divider()

            HStack {
                if !appVersion.isEmpty {
                    Text("Version \(appVersion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .hoverHighlight()
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 640)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(.leading, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HelpStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpBullet: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpExample: View {
    let title: String
    let prompt: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 90, alignment: .leading)
            Text("“\(prompt)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
