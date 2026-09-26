import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let short, !short.isEmpty {
            if let build, !build.isEmpty, build != short {
                return "\(short) (\(build))"
            }
            return short
        }

        return "1.21"
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Help")
                .font(.title2)
                .padding(.top)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("What TinyAI does") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TinyAI is a small macOS utility that sends your text to OpenAI or Google Gemini and shows the result in two panels:")
                            Text("• Starred 1: your primary action (for example, “Translate”).")
                            Text("• Starred 2: a custom action you choose (plus extra buttons to run other custom actions).")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Getting started") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1) Open Settings and paste an OpenAI or Google Gemini API key.")
                            Text("2) Choose what “Starred 1” does (built‑in Translate or one of your custom actions).")
                            Text("3) Create custom actions: give each button a title, pick a model and reasoning level, and write a short prompt.")
                            Text("Tip: In the main window you can trigger custom actions with ⌘1, ⌘2, ⌘3, …")
                            Text("Tip: Use {{targetLanguage}} in prompts to reuse the language picker (for example: “Translate to {{targetLanguage}} and fix grammar.”).")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Examples (custom action prompts)") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Example 1 — Summary")
                                    .font(.headline)
                                Text("Prompt: “Summarize the text in 3 bullet points. Keep it under 60 words.”")
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Example 2 — Rewrite")
                                    .font(.headline)
                                Text("Prompt: “Rewrite the text as a polite and concise email. Preserve key details and names.”")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Popup window") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("You can also use the Popup hotkey from any app to open a compact window for the selected text.")
                            Text("Configure the hotkey and its trigger mode (single / double press) in Settings.")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Your API keys are stored locally in macOS Keychain. Requests are sent when an action runs; editing text in the main window starts its configured actions after a short pause. Settings changes are applied after you press Save.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            HStack {
                Text("Version \(appVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
                Button("Close") {
                    dismiss()
                }
                .hoverHighlight()
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 560, height: 620)
    }
}
