import SwiftUI
import AppKit
import ApplicationServices
import Combine

struct TranslationPopupView: View {
    let selectedText: String
    let selectedPayload: RichTextPayload?
    let onClose: (() -> Void)?
    @EnvironmentObject var translationService: TranslationService
    @EnvironmentObject var keyboardMonitor: KeyboardMonitor
    @State private var primaryOutputText: String = ""
    @State private var secondaryOutputText: String = ""
    @State private var primaryOutputPayloadCache: RichTextPayload?
    @State private var secondaryOutputPayloadCache: RichTextPayload?
    @State private var primaryPreparedOutput: PreparedRichText?
    @State private var secondaryPreparedOutput: PreparedRichText?
    @State private var preparedSelectionHTML: String?
    @State private var preparedSelectionRichText: PreparedRichText?
    @State private var hasPreparedSelectionHTML: Bool = false
    @State private var isPreparingOutput: Bool = false
    @State private var showError: Bool = false
    @State private var isPrimaryLoading: Bool = false
    @State private var isSecondaryLoading: Bool = false
	    @State private var primaryRequestId: UUID = UUID()
	    @State private var secondaryRequestId: UUID = UUID()
	    @State private var primaryNetworkTask: URLSessionDataTask?
	    @State private var secondaryNetworkTask: URLSessionDataTask?
        @State private var secondaryRunningActionId: UUID?
	    @State private var primaryTitle: String = "Starred 1"
	    @State private var secondaryTitle: String = "Starred 2"
	    @State private var isLanguageMenuOpen: Bool = false
	    @State private var languageButtonFrame: CGRect = .zero
    
    init(selectedText: String, selectedPayload: RichTextPayload? = nil, onClose: (() -> Void)? = nil) {
        self.selectedText = selectedText
        self.selectedPayload = selectedPayload
        self.onClose = onClose
    }
    
    let languages = [TranslationService.languageAutoSelection] + TranslationService.supportedLanguages

    private struct FramePreferenceKey: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }

    private struct PopupLanguagePickerButton: View {
        @Binding var selectedLanguage: String
        @Binding var isOpen: Bool
        @Binding var buttonFrame: CGRect

        private let menuWidth: CGFloat = 160
        private let controlHeight: CGFloat = 28

        var body: some View {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(selectedLanguage)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(width: menuWidth, height: controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: FramePreferenceKey.self, value: proxy.frame(in: .named("PopupRoot")))
                }
            )
            .onPreferenceChange(FramePreferenceKey.self) { newValue in
                buttonFrame = newValue
            }
        }
    }

    private struct PopupLanguageMenu: View {
        @Binding var selectedLanguage: String
        let languages: [String]
        let onSelect: () -> Void
        private let menuWidth: CGFloat = 160
        @State private var hoveredLanguage: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(languages, id: \.self) { language in
                        Button {
                            selectedLanguage = language
                            onSelect()
                        } label: {
                            Text(language)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(language == selectedLanguage
                            ? Color(NSColor.selectedContentBackgroundColor).opacity(0.22)
                            : (hoveredLanguage == language
                                ? Color(NSColor.unemphasizedSelectedContentBackgroundColor).opacity(0.18)
                                : Color.clear))
                        .onHover { isHovering in
                            hoveredLanguage = isHovering ? language : (hoveredLanguage == language ? nil : hoveredLanguage)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: menuWidth, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .shadow(radius: 10, y: 6)
        }
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 12) {
                // Header - make it draggable
                HStack(spacing: 10) {
                    Text("TinyAI")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        onClose?()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }

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

            if isLanguageMenuOpen {
                GeometryReader { _ in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isLanguageMenuOpen = false
                            }

                        PopupLanguageMenu(
                            selectedLanguage: $translationService.preferredTargetLanguage,
                            languages: languages,
                            onSelect: { isLanguageMenuOpen = false }
                        )
                        .offset(x: languageButtonFrame.minX, y: languageButtonFrame.maxY + 6)
                    }
                }
                .zIndex(1000)
            }
        }
        .coordinateSpace(name: "PopupRoot")
        .frame(minWidth: 420, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .onAppear {
            keyboardMonitor.isCustomActionHotkeysEnabled = true
            refreshTitles()
            // Let the popup become visible before preparing rich selection data
            // and starting the network requests.
            DispatchQueue.main.async {
                processText()
            }
        }
	        .onDisappear {
	            keyboardMonitor.isCustomActionHotkeysEnabled = false
	            primaryNetworkTask?.cancel()
	            secondaryNetworkTask?.cancel()
                secondaryRunningActionId = nil
	        }
        .onReceive(keyboardMonitor.$customActionHotkey) { hotkey in
            guard let hotkey else { return }
            runSecondaryAction(at: hotkey - 1)
        }
	        .onChange(of: translationService.preferredTargetLanguage) { _, _ in
	            isLanguageMenuOpen = false
	            guard translationService.isStarredPrimaryBuiltInTranslate else { return }
	            refreshTitles()
	            processPrimaryText()
	        }
	        .onChange(of: translationService.starredPrimarySelectionKey) { _, _ in
	            isLanguageMenuOpen = false
	            refreshTitles()
	            processPrimaryText()
	        }
	        .onChange(of: translationService.starredSecondaryActionId) { _, _ in
	            isLanguageMenuOpen = false
	            refreshTitles()
	            processSecondaryText()
	        }
	        .onChange(of: translationService.builtInTranslateModel) { _, _ in
	            isLanguageMenuOpen = false
	            guard translationService.isStarredPrimaryBuiltInTranslate else { return }
	            refreshTitles()
	            processPrimaryText()
	        }
        .onReceive(translationService.$customActions) { _ in
            refreshTitles()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(translationService.errorMessage ?? "An error occurred during translation")
        }
    }

    private func refreshTitles() {
        if translationService.isStarredPrimaryBuiltInTranslate {
            primaryTitle = "Translate"
        } else {
            let primaryAction = translationService.starredPrimaryCustomAction()
            if let primaryAction {
                let fallbackTitle = translationService.customActions
                    .firstIndex(where: { $0.id == primaryAction.id })
                    .map { "Action \($0 + 1)" } ?? "Action 1"
                let title = primaryAction.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : primaryAction.title
                primaryTitle = title
            } else {
                primaryTitle = "Starred 1"
            }
        }

        let secondaryAction = translationService.customActions.first(where: { $0.id == translationService.starredSecondaryActionId })
        if let secondaryAction {
            let fallbackTitle = translationService.customActions
                .firstIndex(where: { $0.id == secondaryAction.id })
                .map { "Action \($0 + 1)" } ?? "Action 2"
            let title = secondaryAction.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : secondaryAction.title
            secondaryTitle = title
        } else {
            secondaryTitle = "Starred 2"
        }
    }

    private func outputView(text: String, prepared: PreparedRichText?, isLoading: Bool, emptyText: String) -> some View {
        ZStack {
            MarkdownTextView(markdown: text, placeholder: emptyText, prepared: prepared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }


    private var primarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(primaryTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()

                if translationService.isStarredPrimaryBuiltInTranslate {
                    PopupLanguagePickerButton(
                        selectedLanguage: $translationService.preferredTargetLanguage,
                        isOpen: $isLanguageMenuOpen,
                        buttonFrame: $languageButtonFrame
                    )
                }

                Button(action: {
                    copyOutput(target: .primary)
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help("Copy")
                .disabled(primaryOutputText.isEmpty || isPrimaryLoading || isPreparingOutput)

                Button("Replace") {
                    replaceOutput(target: .primary)
                }
                .buttonStyle(.borderedProminent)
                .hoverHighlight()
                .disabled(primaryOutputText.isEmpty || isPrimaryLoading || isPreparingOutput)
            }

            outputView(text: primaryOutputText, prepared: primaryPreparedOutput, isLoading: isPrimaryLoading, emptyText: "Result will appear here...")
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var secondarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
	                            selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	                            || (isSecondaryLoading && secondaryRunningActionId == action.id)
	                        )
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 10) {
                Text(secondaryTitle)
                    .font(.headline)
                Spacer()

                Button(action: {
                    copyOutput(target: .secondary)
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help("Copy")
                .disabled(secondaryOutputText.isEmpty || isSecondaryLoading || isPreparingOutput)

                Button("Replace") {
                    replaceOutput(target: .secondary)
                }
                .buttonStyle(.borderedProminent)
                .hoverHighlight()
                .disabled(secondaryOutputText.isEmpty || isSecondaryLoading || isPreparingOutput)
            }

            outputView(text: secondaryOutputText, prepared: secondaryPreparedOutput, isLoading: isSecondaryLoading, emptyText: "Result will appear here...")
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(1)
    }

	    private func processText() {
	        let normalized = RichTextConverter.normalizedMarkdown(selectedText.normalizedPlainText())
	        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            primaryNetworkTask?.cancel()
            secondaryNetworkTask?.cancel()
            primaryOutputText = ""
            secondaryOutputText = ""
            primaryOutputPayloadCache = nil
            secondaryOutputPayloadCache = nil
            primaryPreparedOutput = nil
            secondaryPreparedOutput = nil
            isPrimaryLoading = false
            isSecondaryLoading = false
            secondaryRunningActionId = nil
	            return
	        }

	        processPrimaryText(using: normalized)
	        processSecondaryText(using: normalized)
	    }

	    private func processPrimaryText() {
	        let normalized = RichTextConverter.normalizedMarkdown(selectedText.normalizedPlainText())
	        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
	        processPrimaryText(using: normalized)
	    }

	    private func processPrimaryText(using text: String) {
	        let primaryAction = translationService.starredPrimaryCustomAction()
	        if translationService.isStarredPrimaryBuiltInTranslate {
	            runBuiltInTranslate(target: .primary, text: text)
	        } else {
	            runAction(primaryAction, target: .primary, text: text)
	        }
	    }

	    private func processSecondaryText() {
	        let normalized = RichTextConverter.normalizedMarkdown(selectedText.normalizedPlainText())
	        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
	        processSecondaryText(using: normalized)
	    }

	    private func processSecondaryText(using text: String) {
	        let secondaryAction = translationService.customActions.first(where: { $0.id == translationService.starredSecondaryActionId })
	        runAction(secondaryAction, target: .secondary, text: text)
	    }

	    private enum OutputTarget {
	        case primary
	        case secondary
	    }

    private func runAction(
        _ action: CustomAction?,
        target: OutputTarget,
        text: String
    ) {
        guard let action else {
            switch target {
            case .primary:
                primaryTitle = "Starred 1"
                primaryOutputText = ""
                primaryOutputPayloadCache = nil
                primaryPreparedOutput = nil
                isPrimaryLoading = false
	            case .secondary:
                secondaryTitle = "Starred 2"
                secondaryOutputText = ""
	                secondaryOutputPayloadCache = nil
	                secondaryPreparedOutput = nil
	                isSecondaryLoading = false
                    secondaryRunningActionId = nil
	            }
	            return
	        }

        let fallbackTitle: String = {
            let index = translationService.customActions.firstIndex(where: { $0.id == action.id })
            let defaultIndex = (target == .primary) ? 0 : 1
            return "Action \((index ?? defaultIndex) + 1)"
        }()
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : action.title
        let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLanguagePromptValue = translationService.targetLanguagePromptValue(for: translationService.preferredTargetLanguage)
        let resolvedPrompt = prompt.replacingOccurrences(of: "{{targetLanguage}}", with: targetLanguagePromptValue)
        let emptyPromptMessage = "Configure the prompt and model for this action in Settings."
        let selectionHTML = preparedModelInputHTML()
	        switch target {
	        case .primary:
            primaryTitle = title
            let requestId = UUID()
            primaryRequestId = requestId
            primaryOutputPayloadCache = nil
            primaryPreparedOutput = nil
            primaryOutputText = ""
            if resolvedPrompt.isEmpty {
                isPrimaryLoading = false
                primaryOutputText = ""
                primaryPreparedOutput = nil
                primaryOutputPayloadCache = nil
                translationService.errorMessage = emptyPromptMessage
                showError = true
                return
            }
	            isPrimaryLoading = true
	            primaryNetworkTask?.cancel()
	            if let selectionHTML {
	                primaryNetworkTask = translationService.runCustomActionHTML(html: selectionHTML, prompt: resolvedPrompt, actionId: action.id, modelOverride: action.model) { result in
	                    guard primaryRequestId == requestId else { return }
	                    isPrimaryLoading = false
                    switch result {
                    case .success(let output):
                        let prepared = preparedOutput(from: output, expectsHTML: true)
                        primaryOutputText = prepared.plain
                        primaryPreparedOutput = prepared
                        primaryOutputPayloadCache = prepared.payload
	                    case .failure(let error):
	                        if (error as? URLError)?.code == .cancelled { return }
	                        primaryOutputText = ""
                        primaryOutputPayloadCache = nil
                        primaryPreparedOutput = nil
                        translationService.errorMessage = error.localizedDescription
                        showError = true
                    }
                }
	            } else {
	                primaryNetworkTask = translationService.runCustomAction(text: text, prompt: resolvedPrompt, actionId: action.id, modelOverride: action.model) { result in
	                    guard primaryRequestId == requestId else { return }
	                    isPrimaryLoading = false
                    switch result {
                    case .success(let text):
                        let prepared = RichTextConverter.prepare(markdown: text)
                        primaryOutputText = prepared.plain
                        primaryPreparedOutput = prepared
                        primaryOutputPayloadCache = prepared.payload
                    case .failure(let error):
	                        if (error as? URLError)?.code == .cancelled { return }
                        primaryOutputText = ""
                        primaryOutputPayloadCache = nil
                        primaryPreparedOutput = nil
                        translationService.errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
	        case .secondary:
            secondaryTitle = title
                secondaryRunningActionId = action.id
            let requestId = UUID()
            secondaryRequestId = requestId
            secondaryOutputPayloadCache = nil
            secondaryPreparedOutput = nil
            secondaryOutputText = ""
            if resolvedPrompt.isEmpty {
	                isSecondaryLoading = false
                    secondaryRunningActionId = nil
	                secondaryOutputText = ""
	                secondaryPreparedOutput = nil
	                secondaryOutputPayloadCache = nil
	                translationService.errorMessage = emptyPromptMessage
	                showError = true
	                return
	            }
	            isSecondaryLoading = true
	            secondaryNetworkTask?.cancel()
                if let selectionHTML {
	                    secondaryNetworkTask = translationService.runCustomActionHTML(html: selectionHTML, prompt: resolvedPrompt, actionId: action.id, modelOverride: action.model) { result in
                        guard secondaryRequestId == requestId else { return }
                        isSecondaryLoading = false
                        secondaryRunningActionId = nil
                        switch result {
                        case .success(let output):
                            let prepared = preparedOutput(from: output, expectsHTML: true)
	                            secondaryOutputText = prepared.plain
                            secondaryPreparedOutput = prepared
                            secondaryOutputPayloadCache = prepared.payload
		                        case .failure(let error):
		                            if (error as? URLError)?.code == .cancelled { return }
	                            secondaryOutputText = ""
	                        secondaryOutputPayloadCache = nil
                        secondaryPreparedOutput = nil
                            translationService.errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                } else {
	                    secondaryNetworkTask = translationService.runCustomAction(text: text, prompt: resolvedPrompt, actionId: action.id, modelOverride: action.model) { result in
                        guard secondaryRequestId == requestId else { return }
                        isSecondaryLoading = false
                        secondaryRunningActionId = nil
                        switch result {
                        case .success(let text):
                            let prepared = RichTextConverter.prepare(markdown: text)
	                            secondaryOutputText = prepared.plain
                            secondaryPreparedOutput = prepared
                            secondaryOutputPayloadCache = prepared.payload
                        case .failure(let error):
                            if (error as? URLError)?.code == .cancelled { return }
                            secondaryOutputText = ""
                        secondaryOutputPayloadCache = nil
                        secondaryPreparedOutput = nil
                            translationService.errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
        }
    }

    private func runBuiltInTranslate(target: OutputTarget, text: String) {
        guard target == .primary else {
            return
        }

        primaryTitle = "Translate"
        let requestId = UUID()
        primaryRequestId = requestId
        primaryOutputPayloadCache = nil
        primaryPreparedOutput = nil
        isPrimaryLoading = true
        primaryNetworkTask?.cancel()

        let languageMode = translationService.translationLanguageMode(for: translationService.preferredTargetLanguage)
        if let html = preparedModelInputHTML() {
            if let source = preparedSelectionRichText,
               !RichTextConverter.containsHumanReadableProse(in: source.attributed) {
                isPrimaryLoading = false
                primaryOutputText = source.plain
                primaryPreparedOutput = source
                primaryOutputPayloadCache = source.payload
                return
            }

            primaryNetworkTask = requestBuiltInHTML(
                html: html,
                languageMode: languageMode,
                requestId: requestId
            )
        } else {
            let source = RichTextConverter.prepare(markdown: text)
            if !RichTextConverter.containsHumanReadableProse(in: source.attributed) {
                isPrimaryLoading = false
                primaryOutputText = source.plain
                primaryPreparedOutput = source
                primaryOutputPayloadCache = source.payload
                return
            }

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
	            switch result {
	            case .success(let output):
	                let prepared = RichTextConverter.prepare(markdown: output)
	                isPrimaryLoading = false
	                primaryOutputText = prepared.plain
	                primaryPreparedOutput = prepared
	                primaryOutputPayloadCache = prepared.payload
	            case .failure(let error):
	                if (error as? URLError)?.code == .cancelled { return }
	                isPrimaryLoading = false
	                primaryOutputText = ""
	                primaryOutputPayloadCache = nil
	                primaryPreparedOutput = nil
	                translationService.errorMessage = error.localizedDescription
	                showError = true
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
            switch result {
            case .success(let output):
                let prepared = preparedOutput(from: output, expectsHTML: true)
                isPrimaryLoading = false
                primaryOutputText = prepared.plain
                primaryPreparedOutput = prepared
                primaryOutputPayloadCache = prepared.payload
            case .failure(let error):
                if (error as? URLError)?.code == .cancelled { return }
                isPrimaryLoading = false
                primaryOutputText = ""
                primaryOutputPayloadCache = nil
                primaryPreparedOutput = nil
                translationService.errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func preparedModelInputHTML() -> String? {
        if hasPreparedSelectionHTML {
            return preparedSelectionHTML
        }

        hasPreparedSelectionHTML = true
        guard let selectedPayload else { return nil }

        if let html = selectedPayload.html?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
            if let prepared = RichTextConverter.prepare(html: html),
               let sanitized = RichTextConverter.modelHTML(from: prepared) {
                preparedSelectionRichText = prepared
                preparedSelectionHTML = sanitized
                return sanitized
            }
        }

        if selectedPayload.rtf != nil {
            let prepared = RichTextConverter.prepare(payload: selectedPayload)
            guard let html = RichTextConverter.modelHTML(from: prepared) else { return nil }
            preparedSelectionRichText = prepared
            preparedSelectionHTML = html
            return html
        }

        return nil
    }

	    private func runSecondaryAction(at index: Int) {
        guard index >= 0 && index < translationService.customActions.count else {
            return
        }

        let normalized = RichTextConverter.normalizedMarkdown(selectedText.normalizedPlainText())
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

	        let action = translationService.customActions[index]
            if isSecondaryLoading, secondaryRunningActionId == action.id {
                return
            }
		    runAction(action, target: .secondary, text: normalized)
	    }

    private func outputPayload(for target: OutputTarget) -> RichTextPayload {
        switch target {
        case .primary:
            if let prepared = primaryPreparedOutput {
                primaryOutputPayloadCache = prepared.payload
                return prepared.payload
            }
            if let cached = primaryOutputPayloadCache {
                return cached
            }
            let payload = RichTextConverter.prepare(markdown: primaryOutputText).payload
            primaryOutputPayloadCache = payload
            return payload
        case .secondary:
            if let prepared = secondaryPreparedOutput {
                secondaryOutputPayloadCache = prepared.payload
                return prepared.payload
            }
            if let cached = secondaryOutputPayloadCache {
                return cached
            }
            let payload = RichTextConverter.prepare(markdown: secondaryOutputText).payload
            secondaryOutputPayloadCache = payload
            return payload
        }
    }

    private func copyOutput(target: OutputTarget) {
        guard !isPreparingOutput else { return }
        isPreparingOutput = true
        defer { isPreparingOutput = false }
        copyToClipboard(outputPayload(for: target))
    }

    private func replaceOutput(target: OutputTarget) {
        guard !isPreparingOutput else { return }
        isPreparingOutput = true
        defer { isPreparingOutput = false }
        replaceText(with: outputPayload(for: target))
    }

    private func replaceText(with payload: RichTextPayload) {
        guard let target = selectedPayload?.replacementTarget,
              let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            translationService.errorMessage = "The original text application is no longer available."
            return
        }

        let pasteboard = NSPasteboard.general
        var replacementPayload = payload
        replacementPayload.replacementTarget = target
        RichTextPasteboard.write(replacementPayload, to: pasteboard)
        let expectedPasteboardChangeCount = pasteboard.changeCount

        // Restore focus to the app and only paste after it is frontmost. This keeps
        // Replace from inserting text into whichever app the user clicked meanwhile.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            application.activate(options: [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  pasteboard.changeCount == expectedPasteboardChangeCount else {
                self.translationService.errorMessage = "The original text application is no longer focused; nothing was replaced."
                return
            }

            // Re-focus the exact control captured before the popup opened when
            // the source application exposes that accessibility attribute.
            // Some applications reject this request; the frontmost-process
            // check above remains the hard safety boundary in that case.
            _ = AXUIElementSetAttributeValue(
                target.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )

            // Paste text (Command-V)
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            self.onClose?()
        }
    }

    private func copyToClipboard(_ payload: RichTextPayload) {
        let pasteboard = NSPasteboard.general
        RichTextPasteboard.write(payload, to: pasteboard)
    }
}
