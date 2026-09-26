import SwiftUI
import AppKit

struct MainTranslationView: View {
    @EnvironmentObject var translationService: TranslationService
    @State private var sourceText: String = ""
    @State private var sourcePreparedInput: PreparedRichText = RichTextConverter.prepare(markdown: "")
    @State private var textChangeGeneration: Int = 0
    @State private var primaryOutputText: String = ""
    @State private var secondaryOutputText: String = ""
    @State private var primaryOutputPayload: RichTextPayload?
    @State private var secondaryOutputPayload: RichTextPayload?
    @State private var primaryPreparedOutput: PreparedRichText?
    @State private var secondaryPreparedOutput: PreparedRichText?
    @State private var showSettings: Bool = false
    @State private var showHelp: Bool = false
    @State private var processingTask: DispatchWorkItem?
    @State private var isPrimaryLoading: Bool = false
    @State private var isSecondaryLoading: Bool = false
    @State private var primaryRequestId: UUID = UUID()
    @State private var secondaryRequestId: UUID = UUID()
    @State private var primaryNetworkTask: URLSessionDataTask?
    @State private var secondaryNetworkTask: URLSessionDataTask?
    @State private var secondaryRunningActionId: UUID?
    @State private var primaryTitle: String = "Starred 1"
    @State private var secondaryTitle: String = "Starred 2"

    let languages = [TranslationService.languageAutoSelection] + TranslationService.supportedLanguages

    var body: some View {
        HSplitView {
            // Left panel - source text
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Source text")
                        .font(.headline)
                    Spacer()
                    Button(action: { clearSourceText() }) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .hoverHighlight()
                    .help("Clear")
                    .accessibilityLabel("Clear source text")
                    .disabled(sourceText.isEmpty)
                }

                ZStack(alignment: .topLeading) {
                    if sourceText.isEmpty {
                        // Outer padding (8) + the text view's container inset
                        // (10) puts the placeholder where the caret starts.
                        Text("Enter text to translate...")
                            .font(Font(NSFont.preferredFont(forTextStyle: .body)))
                            .foregroundColor(.secondary)
                            .padding(18)
                            .allowsHitTesting(false)
                    }

                    RichTextEditor(prepared: $sourcePreparedInput, onChange: handleSourceTextChange)
                        .frame(minWidth: 220)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
            .padding(16)
            .frame(minWidth: 340)

            // Right panel - results
            VStack(alignment: .leading, spacing: 12) {
                VSplitView {
                    primarySection
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .layoutPriority(1)
                    secondarySection
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .layoutPriority(1)
                }
            }
            .padding(16)
            .frame(minWidth: 340)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .hoverToolbarIcon()
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")

                Button(action: { showHelp = true }) {
                    Image(systemName: "questionmark.circle")
                        .hoverToolbarIcon()
                }
                .buttonStyle(.plain)
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .onAppear {
            refreshTitles()
        }
        .onChange(of: translationService.preferredTargetLanguage) { _, _ in
            guard translationService.isStarredPrimaryBuiltInTranslate else { return }
            refreshTitles()
            if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                processPrimaryText()
            }
        }
        .onChange(of: translationService.starredPrimarySelectionKey) { _, _ in
            refreshTitles()
            if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                processPrimaryText()
            }
        }
        .onChange(of: translationService.starredSecondaryActionId) { _, _ in
            refreshTitles()
            if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                processSecondaryText()
            }
        }
        .onChange(of: translationService.builtInTranslateModel) { _, _ in
            guard translationService.isStarredPrimaryBuiltInTranslate else { return }
            refreshTitles()
            if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                processPrimaryText()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(translationService)
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .alert("Error", isPresented: Binding(
            get: { translationService.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    translationService.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                translationService.errorMessage = nil
            }
            .hoverHighlight()
        } message: {
            Text(translationService.errorMessage ?? "")
        }
    }

    static func processingDelay(for oldValue: String, newValue: String) -> TimeInterval {
        let oldLength = oldValue.count
        let newLength = newValue.count

        // A transition from empty text or a multi-character change is most likely
        // a paste or a replacement of a selected range. Those edits can be sent
        // almost immediately without making normal typing issue one request per key.
        if (oldValue.isEmpty && newLength > 1) || abs(newLength - oldLength) > 1 {
            return 0.05
        }

        return 0.30
    }

    private func handleSourceTextChange(oldValue: String, newValue: PreparedRichText) {
        let newText = newValue.plain
        sourceText = newText
        processingTask?.cancel()
        textChangeGeneration += 1
        let generation = textChangeGeneration
        primaryNetworkTask?.cancel()
        secondaryNetworkTask?.cancel()
        primaryNetworkTask = nil
        secondaryNetworkTask = nil
        // Invalidate completion handlers immediately. URLSession cancellation is
        // cooperative, so this prevents an old response from updating the view
        // during that short window.
        primaryRequestId = UUID()
        secondaryRequestId = UUID()
        isPrimaryLoading = false
        isSecondaryLoading = false
        secondaryRunningActionId = nil
        primaryOutputText = ""
        secondaryOutputText = ""
        primaryOutputPayload = nil
        secondaryOutputPayload = nil
        primaryPreparedOutput = nil
        secondaryPreparedOutput = nil

        guard !newText.isEmpty else { return }

        // Keep the existing debounce behaviour: bulk edits such as a paste are
        // processed quickly, while ordinary typing waits a little longer.
        let delay = Self.processingDelay(for: oldValue, newValue: newText)
        let task = DispatchWorkItem {
            guard generation == self.textChangeGeneration else { return }
            self.processText()
        }
        processingTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func runBuiltInTranslate(target: OutputTarget, text: String, html: String?) {
        guard target == .primary else {
            return
        }

        primaryTitle = "Translate"
        let requestId = UUID()
        primaryRequestId = requestId
        primaryOutputPayload = nil
        primaryPreparedOutput = nil
        isPrimaryLoading = true

        let languageMode = translationService.translationLanguageMode(for: translationService.preferredTargetLanguage)
        primaryNetworkTask?.cancel()
        if !RichTextConverter.containsHumanReadableProse(in: sourcePreparedInput.attributed) {
            isPrimaryLoading = false
            primaryOutputText = sourcePreparedInput.plain
            primaryPreparedOutput = sourcePreparedInput
            primaryOutputPayload = sourcePreparedInput.payload
            return
        }

        if let html {
            primaryNetworkTask = requestBuiltInHTML(
                html: html,
                languageMode: languageMode,
                requestId: requestId
            )
        } else {
            primaryNetworkTask = requestBuiltInText(
                text: text,
                languageMode: languageMode,
                requestId: requestId
            )
        }
    }

    private func requestBuiltInText(
        text: String,
        languageMode: TranslationLanguageMode,
        requestId: UUID
    ) -> URLSessionDataTask? {
        translationService.translateText(
            text: text,
            languageMode: languageMode,
            modelOverride: translationService.builtInTranslateModel
        ) { result in
            guard primaryRequestId == requestId else { return }
            isPrimaryLoading = false
            switch result {
            case .success(let output):
                let prepared = RichTextConverter.prepare(markdown: output)
                primaryOutputText = prepared.plain
                primaryPreparedOutput = prepared
                primaryOutputPayload = prepared.payload
            case .failure(let error):
                if (error as? URLError)?.code == .cancelled { return }
                primaryOutputText = ""
                primaryOutputPayload = nil
                primaryPreparedOutput = nil
                translationService.errorMessage = error.localizedDescription
            }
        }
    }

    private func requestBuiltInHTML(
        html: String,
        languageMode: TranslationLanguageMode,
        requestId: UUID
    ) -> URLSessionDataTask? {
        translationService.translateHTML(
            html: html,
            languageMode: languageMode,
            modelOverride: translationService.builtInTranslateModel
        ) { result in
            guard primaryRequestId == requestId else { return }
            isPrimaryLoading = false
            switch result {
            case .success(let response):
                let prepared = preparedOutput(from: response, expectsHTML: true)
                primaryOutputText = prepared.plain
                primaryPreparedOutput = prepared
                primaryOutputPayload = prepared.payload
            case .failure(let error):
                if (error as? URLError)?.code == .cancelled { return }
                primaryOutputText = ""
                primaryOutputPayload = nil
                primaryPreparedOutput = nil
                translationService.errorMessage = error.localizedDescription
            }
        }
    }

    private func preparedOutput(from response: String, expectsHTML: Bool) -> PreparedRichText {
        if expectsHTML, let prepared = RichTextConverter.prepare(html: response) {
            return prepared
        }
        if expectsHTML {
            return RichTextConverter.prepare(
                attributed: NSAttributedString(string: response.normalizedPlainText())
            )
        }
        return RichTextConverter.prepare(markdown: response)
    }

    private var primarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(primaryTitle)
                    .font(.headline)
                Spacer()

                if translationService.isStarredPrimaryBuiltInTranslate {
                    Picker("", selection: $translationService.preferredTargetLanguage) {
                        ForEach(languages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }

                Button(action: { copyTextToClipboard(primaryOutputText, payload: primaryOutputPayload) }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help("Copy")
                .disabled(primaryOutputText.isEmpty || isPrimaryLoading)
            }

            .padding(.vertical, 2)

            if isPrimaryLoading {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .frame(width: 36, height: 36)
                    Text("Processing...")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            } else {
                MarkdownTextView(
                    markdown: primaryOutputText,
                    placeholder: "Result will appear here...",
                    prepared: primaryPreparedOutput
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var secondarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(secondaryTitle)
                    .font(.headline)
                Spacer()

                Button(action: { copyTextToClipboard(secondaryOutputText, payload: secondaryOutputPayload) }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help("Copy")
                .disabled(secondaryOutputText.isEmpty || isSecondaryLoading)
            }

            .padding(.top, 6)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(translationService.customActions.enumerated()), id: \.element.id) { index, action in
                        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Action \(index + 1)"
                        : action.title

                        Button(title) {
                            runSecondaryAction(at: index)
                        }
                        .buttonStyle(.bordered)
                        .hoverHighlight()
                        .disabled(
                            sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (isSecondaryLoading && secondaryRunningActionId == action.id)
                        )
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                    }
                }
                .padding(.vertical, 2)
            }

            if isSecondaryLoading {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .frame(width: 36, height: 36)
                    Text("Processing...")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            } else {
                MarkdownTextView(
                    markdown: secondaryOutputText,
                    placeholder: "Result will appear here...",
                    prepared: secondaryPreparedOutput
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func clearSourceText() {
        primaryNetworkTask?.cancel()
        secondaryNetworkTask?.cancel()
        processingTask?.cancel()
        primaryNetworkTask = nil
        secondaryNetworkTask = nil
        primaryRequestId = UUID()
        secondaryRequestId = UUID()
        sourceText = ""
        sourcePreparedInput = RichTextConverter.prepare(markdown: "")
        primaryOutputText = ""
        secondaryOutputText = ""
        primaryOutputPayload = nil
        secondaryOutputPayload = nil
        primaryPreparedOutput = nil
        secondaryPreparedOutput = nil
        isPrimaryLoading = false
        isSecondaryLoading = false
        secondaryRunningActionId = nil
    }

    private func copyTextToClipboard(_ text: String, payload: RichTextPayload? = nil) {
        let pasteboard = NSPasteboard.general
        let preparedPayload = payload ?? RichTextConverter.prepare(markdown: text).payload
        RichTextPasteboard.write(preparedPayload, to: pasteboard)
    }

    private func processText() {
        let normalized = RichTextConverter.normalizedMarkdown(sourceText.normalizedPlainText())
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            primaryNetworkTask?.cancel()
            secondaryNetworkTask?.cancel()
            primaryOutputText = ""
            secondaryOutputText = ""
            primaryOutputPayload = nil
            secondaryOutputPayload = nil
            primaryPreparedOutput = nil
            secondaryPreparedOutput = nil
            isPrimaryLoading = false
            isSecondaryLoading = false
            secondaryRunningActionId = nil
            return
        }

        let html = RichTextConverter.modelHTML(from: sourcePreparedInput)
        processPrimaryText(using: normalized, html: html)
        processSecondaryText(using: normalized, html: html)
    }

    private func processPrimaryText() {
        let normalized = RichTextConverter.normalizedMarkdown(sourceText.normalizedPlainText())
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        processPrimaryText(using: normalized, html: RichTextConverter.modelHTML(from: sourcePreparedInput))
    }

    private func processPrimaryText(using text: String, html: String?) {
        let primaryAction = translationService.starredPrimaryCustomAction()
        if translationService.isStarredPrimaryBuiltInTranslate {
            runBuiltInTranslate(target: .primary, text: text, html: html)
        } else {
            runAction(primaryAction, target: .primary, text: text, html: html)
        }
    }

    private func processSecondaryText() {
        let normalized = RichTextConverter.normalizedMarkdown(sourceText.normalizedPlainText())
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        processSecondaryText(using: normalized, html: RichTextConverter.modelHTML(from: sourcePreparedInput))
    }

    private func processSecondaryText(using text: String, html: String?) {
        let secondaryAction = translationService.customActions.first(where: { $0.id == translationService.starredSecondaryActionId })
        runAction(secondaryAction, target: .secondary, text: text, html: html)
    }

    private func refreshTitles() {
        if translationService.isStarredPrimaryBuiltInTranslate {
            primaryTitle = "Translate"
        } else {
            let primaryAction = translationService.starredPrimaryCustomAction()
            if let primaryAction {
                let title = primaryAction.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Action" : primaryAction.title
                primaryTitle = title
            } else {
                primaryTitle = "Starred 1"
            }
        }

        let secondaryAction = translationService.customActions.first(where: { $0.id == translationService.starredSecondaryActionId })
        if let secondaryAction {
            let title = secondaryAction.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Action" : secondaryAction.title
            secondaryTitle = title
        } else {
            secondaryTitle = "Starred 2"
        }
    }

    private enum OutputTarget {
        case primary
        case secondary
    }

    private func runAction(
        _ action: CustomAction?,
        target: OutputTarget,
        text: String,
        html: String?
    ) {
        guard let action else {
            switch target {
            case .primary:
                primaryTitle = "Starred 1"
                primaryOutputText = ""
                primaryOutputPayload = nil
                primaryPreparedOutput = nil
                isPrimaryLoading = false
            case .secondary:
                secondaryTitle = "Starred 2"
                secondaryOutputText = ""
                secondaryOutputPayload = nil
                secondaryPreparedOutput = nil
                isSecondaryLoading = false
            }
            return
        }

        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Action" : action.title
        let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let targetLanguagePromptValue = translationService.targetLanguagePromptValue(for: translationService.preferredTargetLanguage)
        let resolvedPrompt = prompt.replacingOccurrences(of: "{{targetLanguage}}", with: targetLanguagePromptValue)
        let emptyPromptMessage = "Configure the prompt and model for this action in Settings."

        switch target {
        case .primary:
            primaryTitle = title
            let requestId = UUID()
            primaryRequestId = requestId
            primaryOutputPayload = nil
            primaryPreparedOutput = nil
            primaryOutputText = ""
            if resolvedPrompt.isEmpty {
                isPrimaryLoading = false
                primaryOutputText = ""
                primaryPreparedOutput = nil
                primaryOutputPayload = nil
                translationService.errorMessage = emptyPromptMessage
                return
            }
            isPrimaryLoading = true
            primaryNetworkTask?.cancel()
            if let html {
                primaryNetworkTask = translationService.runCustomActionHTML(
                    html: html,
                    prompt: resolvedPrompt,
                    actionId: action.id,
                    modelOverride: action.model
                ) { result in
                    guard primaryRequestId == requestId else { return }
                    isPrimaryLoading = false
                    switch result {
                    case .success(let response):
                        let prepared = preparedOutput(from: response, expectsHTML: true)
                        primaryOutputText = prepared.plain
                        primaryPreparedOutput = prepared
                        primaryOutputPayload = prepared.payload
                    case .failure(let error):
                        if (error as? URLError)?.code == .cancelled { return }
                        primaryOutputText = ""
                        primaryOutputPayload = nil
                        primaryPreparedOutput = nil
                        translationService.errorMessage = error.localizedDescription
                    }
                }
            } else {
                primaryNetworkTask = translationService.runCustomAction(
                    text: text,
                    prompt: resolvedPrompt,
                    actionId: action.id,
                    modelOverride: action.model
                ) { result in
                    guard primaryRequestId == requestId else { return }
                    isPrimaryLoading = false
                    switch result {
                    case .success(let response):
                        let prepared = preparedOutput(from: response, expectsHTML: false)
                        primaryOutputText = prepared.plain
                        primaryPreparedOutput = prepared
                        primaryOutputPayload = prepared.payload
                    case .failure(let error):
                        if (error as? URLError)?.code == .cancelled { return }
                        primaryOutputText = ""
                        primaryOutputPayload = nil
                        primaryPreparedOutput = nil
                        translationService.errorMessage = error.localizedDescription
                    }
                }
            }
        case .secondary:
            secondaryTitle = title
            secondaryRunningActionId = action.id
            let requestId = UUID()
            secondaryRequestId = requestId
            secondaryOutputPayload = nil
            secondaryPreparedOutput = nil
            secondaryOutputText = ""
            if resolvedPrompt.isEmpty {
                isSecondaryLoading = false
                secondaryRunningActionId = nil
                secondaryOutputText = ""
                secondaryPreparedOutput = nil
                secondaryOutputPayload = nil
                translationService.errorMessage = emptyPromptMessage
                return
            }
            isSecondaryLoading = true
            secondaryNetworkTask?.cancel()
            if let html {
                secondaryNetworkTask = translationService.runCustomActionHTML(
                    html: html,
                    prompt: resolvedPrompt,
                    actionId: action.id,
                    modelOverride: action.model
                ) { result in
                    guard secondaryRequestId == requestId else { return }
                    isSecondaryLoading = false
                    secondaryRunningActionId = nil
                    switch result {
                    case .success(let response):
                        let prepared = preparedOutput(from: response, expectsHTML: true)
                        secondaryOutputText = prepared.plain
                        secondaryPreparedOutput = prepared
                        secondaryOutputPayload = prepared.payload
                    case .failure(let error):
                        if (error as? URLError)?.code == .cancelled { return }
                        secondaryOutputText = ""
                        secondaryOutputPayload = nil
                        secondaryPreparedOutput = nil
                        translationService.errorMessage = error.localizedDescription
                    }
                }
            } else {
                secondaryNetworkTask = translationService.runCustomAction(
                    text: text,
                    prompt: resolvedPrompt,
                    actionId: action.id,
                    modelOverride: action.model
                ) { result in
                    guard secondaryRequestId == requestId else { return }
                    isSecondaryLoading = false
                    secondaryRunningActionId = nil
                    switch result {
                    case .success(let response):
                        let prepared = preparedOutput(from: response, expectsHTML: false)
                        secondaryOutputText = prepared.plain
                        secondaryPreparedOutput = prepared
                        secondaryOutputPayload = prepared.payload
                    case .failure(let error):
                        if (error as? URLError)?.code == .cancelled { return }
                        secondaryOutputText = ""
                        secondaryOutputPayload = nil
                        secondaryPreparedOutput = nil
                        translationService.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func runSecondaryAction(at index: Int) {
        guard index >= 0 && index < translationService.customActions.count else {
            return
        }

        let normalized = RichTextConverter.normalizedMarkdown(sourceText.normalizedPlainText())
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let action = translationService.customActions[index]
        if isSecondaryLoading, secondaryRunningActionId == action.id {
            return
        }
        runAction(
            action,
            target: .secondary,
            text: normalized,
            html: RichTextConverter.modelHTML(from: sourcePreparedInput)
        )
    }
}
