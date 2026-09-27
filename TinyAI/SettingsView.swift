import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var translationService: TranslationService
    @EnvironmentObject var keyboardMonitor: KeyboardMonitor
    @EnvironmentObject var voiceStore: VoiceSettingsStore
    @EnvironmentObject var voiceCoordinator: VoiceCoordinator
    @EnvironmentObject var localModelManager: LocalModelManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: SettingsTab = .api
    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var busyProviders: Set<LLMProvider> = []
    @State private var keyValidationTasks: [LLMProvider: Task<Void, Never>] = [:]
    @State private var keyValidationRequestTasks: [LLMProvider: Task<Void, Never>] = [:]
    @State private var apiAlert: APIAlert?
    @State private var customActions: [CustomAction] = []
    @State private var starredPrimarySelectionKey: String = TranslationService.builtInTranslateSelectionKey
    @State private var starredSecondaryActionId: UUID?
    @State private var builtInTranslateModel: LLMModel = TranslationService.defaultModel
    @State private var autoTranslateMainLanguage: String = "Russian"
    @State private var autoTranslateAdditionalLanguage: String = "English"
    @State private var translationStyleContext: String = ""
    @State private var actionStyleContext: String = ""
    @State private var actionStyleContextActionKeys: Set<String> = []
    @State private var popupHotkey: KeyboardShortcut = KeyboardShortcut(keyCode: 8, modifiers: [.command])
    @State private var popupHotkeyPressMode: PopupHotkeyPressMode = .doublePress
    @State private var popupHotkeyError: String?
    @State private var validatedKeyCandidates: [LLMProvider: String] = [:]
    @State private var keyValidationGeneration: [LLMProvider: Int] = [:]
    @State private var permissionRefreshToken = UUID()
    @State private var voiceDraft = VoiceConfiguration()
    @State private var headerSecretDrafts: [UUID: String] = [:]

    private let settingsLabelColumnWidth: CGFloat = 130
    private let settingsControlColumnWidth: CGFloat = 240
    private let customActionModelPickerWidth: CGFloat = 220
    private let autoTranslateLanguages = TranslationService.supportedLanguages

    var body: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.title2)
                .padding(.top)

            // A custom segmented header: the system TabView tab bar collapses
            // into overlapping, truncated labels in this sheet on macOS 27.
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases.filter { voiceStore.agentsBetaEnabled || !$0.isAgentsBeta }, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)

            Group {
                switch selectedTab {
                case .primaryActions: primaryActionsTab
                case .customActions: customActionsTab
                case .styleContext: styleContextTab
                case .hotkeys: hotkeysTab
                case .api: apiTab
                case .voice:
                    VoiceSettingsTab(draft: $voiceDraft, modelManager: localModelManager, popupHotkey: popupHotkey)
                case .agents:
                    AgentsSettingsTab(draft: $voiceDraft, headerSecrets: $headerSecretDrafts, store: voiceStore,
                                      coordinator: voiceCoordinator, popupHotkey: popupHotkey)
                case .live:
                    LiveSettingsTab(draft: $voiceDraft, popupHotkey: popupHotkey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Button("Cancel") {
                    keyValidationTasks.values.forEach { $0.cancel() }
                    keyValidationRequestTasks.values.forEach { $0.cancel() }
                    dismiss()
                }
                .hoverHighlight()
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    guard draftKeysAreReadyForSave else {
                        apiAlert = APIAlert(
                            title: "Validate API keys first",
                            message: "Wait for key validation to finish, or correct the key and try again."
                        )
                        return
                    }

                    if let hotkeyError = keyboardMonitor.validatePopupHotkey(popupHotkey, pressMode: popupHotkeyPressMode) {
                        popupHotkeyError = hotkeyError
                        return
                    }

                    if let voiceHotkeyError = VoiceHotkeySlots.firstError(in: voiceDraft, popupHotkey: popupHotkey) {
                        apiAlert = APIAlert(title: "Voice shortcut conflict", message: voiceHotkeyError)
                        return
                    }

                    let normalizedActions = customActions.map { action in
                        var copy = action
                        copy.title = String(copy.title.prefix(25))
                        return copy
                    }
                    customActions = normalizedActions
                    translationService.saveCustomActions(normalizedActions)
                    translationService.saveStarredPrimarySelectionKey(starredPrimarySelectionKey)
                    translationService.saveBuiltInTranslateModel(builtInTranslateModel)
                    translationService.saveStarredSecondaryActionId(starredSecondaryActionId)
                    translationService.saveAutoTranslateMainLanguage(autoTranslateMainLanguage)
                    translationService.saveAutoTranslateAdditionalLanguage(autoTranslateAdditionalLanguage)
                    translationService.saveTranslationStyleContext(translationStyleContext)
                    translationService.saveActionStyleContext(actionStyleContext)
                    translationService.saveActionStyleContextActionKeys(actionStyleContextActionKeys)
                    translationService.saveAPIKey(openAIKey, for: .openAI)
                    translationService.saveAPIKey(geminiKey, for: .gemini)
                    for connection in voiceDraft.connections {
                        if let secret = headerSecretDrafts[connection.id] {
                            voiceStore.setHeaderSecret(connection.auth == .header ? secret : "", for: connection)
                        }
                    }
                    voiceStore.save(voiceDraft)

                    if let error = keyboardMonitor.applyPopupHotkeySettings(shortcut: popupHotkey, pressMode: popupHotkeyPressMode) {
                        popupHotkeyError = error
                        return
                    }

                    dismiss()
                }
                .hoverHighlight()
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 660, height: 760)
        .onAppear {
            voiceDraft = voiceStore.configuration
            headerSecretDrafts = [:]
            localModelManager.refresh()
            openAIKey = translationService.apiKey
            geminiKey = translationService.geminiAPIKey
            customActions = translationService.customActions.map { action in
                var copy = action
                copy.title = String(copy.title.prefix(25))
                return copy
            }
            starredPrimarySelectionKey = translationService.starredPrimarySelectionKey
            starredSecondaryActionId = translationService.starredSecondaryActionId
            builtInTranslateModel = translationService.builtInTranslateModel
            autoTranslateMainLanguage = translationService.autoTranslateMainLanguage
            autoTranslateAdditionalLanguage = translationService.autoTranslateAdditionalLanguage
            translationStyleContext = translationService.translationStyleContext
            actionStyleContext = translationService.actionStyleContext
            actionStyleContextActionKeys = translationService.actionStyleContextActionKeys
            popupHotkey = keyboardMonitor.popupHotkey
            popupHotkeyPressMode = keyboardMonitor.popupHotkeyPressMode
            popupHotkeyError = nil
            validatedKeyCandidates = [
                .openAI: openAIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                .gemini: geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }
        .onDisappear {
            keyValidationTasks.values.forEach { $0.cancel() }
            keyValidationRequestTasks.values.forEach { $0.cancel() }
        }
        .alert(item: $apiAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var apiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Providers")
                        .font(.headline)

                    providerRow(
                        provider: .openAI,
                        key: $openAIKey,
                        getKeyURL: URL(string: "https://platform.openai.com/api-keys")!
                    )

                    providerRow(
                        provider: .gemini,
                        key: $geminiKey,
                        getKeyURL: URL(string: "https://aistudio.google.com/app/apikey")!
                    )

                    Text("Keys are tested before saving. A failed check leaves the draft untouched and shows the provider error.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var draftKeysAreReadyForSave: Bool {
        for provider in LLMProvider.allCases {
            let candidate = (provider == .openAI ? openAIKey : geminiKey)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = translationService.apiKey(for: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty,
               candidate != saved,
               validatedKeyCandidates[provider] != candidate {
                return false
            }
        }
        return true
    }

    private func providerRow(provider: LLMProvider, key: Binding<String>, getKeyURL: URL) -> some View {
        let isBusy = busyProviders.contains(provider)
        let hasDraftKey = !key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSavedKey = translationService.hasAPIKey(for: provider)
        let keychainStatus = translationService.keychainStatus(for: provider)
        let needsKeychainRetry: Bool = {
            guard let keychainStatus else { return false }
            if case .interactionRequired = keychainStatus { return true }
            if case .failure = keychainStatus { return true }
            return false
        }()
        let statusColor: Color = hasDraftKey ? .green : .red

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(provider.displayName)
                    .frame(minWidth: 120, alignment: .leading)

                SecureField("Enter API key", text: key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { validateProviderKey(provider, candidate: key.wrappedValue) }
                    .onChange(of: key.wrappedValue) { _, newValue in
                        scheduleProviderKeyValidation(provider, candidate: newValue)
                    }
            }

            HStack(spacing: 10) {
                Text(hasDraftKey ? (hasDraftKey == hasSavedKey ? "Active" : "Ready to save") : "Inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link("Get an API key", destination: getKeyURL)
                    .font(.caption)
                Spacer()

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking key…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if needsKeychainRetry {
                HStack(spacing: 8) {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("Keychain access needs your confirmation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        let result = translationService.retryKeychainAccess(for: provider)
                        switch result {
                        case .value(let value):
                            key.wrappedValue = value
                            validatedKeyCandidates[provider] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        case .missing:
                            apiAlert = APIAlert(title: "Key not found", message: "No saved \(provider.displayName) key was found in Keychain.")
                        case .interactionRequired, .failure:
                            apiAlert = APIAlert(title: "Keychain access unavailable", message: "Allow access to the TinyAI Keychain item, then try again.")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 6)
        .hoverRowHighlight()
    }

    private func scheduleProviderKeyValidation(_ provider: LLMProvider, candidate: String) {
        keyValidationTasks[provider]?.cancel()
        keyValidationRequestTasks[provider]?.cancel()
        busyProviders.remove(provider)
        let snapshot = candidate
        validatedKeyCandidates.removeValue(forKey: provider)
        keyValidationTasks[provider] = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                return
            }

            let current = provider == .openAI ? openAIKey : geminiKey
            guard current == snapshot else { return }

            let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = translationService.apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                validatedKeyCandidates[provider] = ""
                return
            }

            guard trimmed != saved else { return }

            validateProviderKey(provider, candidate: trimmed)
        }
    }

    private func validateProviderKey(_ provider: LLMProvider, candidate: String) {
        let generation = (keyValidationGeneration[provider] ?? 0) + 1
        keyValidationGeneration[provider] = generation
        busyProviders.insert(provider)

        let task = Task { @MainActor in
            defer {
                if keyValidationGeneration[provider] == generation {
                    keyValidationRequestTasks[provider] = nil
                }
            }

            let result = await translationService.validateAPIKeyOnly(candidate, for: provider)
            guard !Task.isCancelled else { return }
            let current = provider == .openAI ? openAIKey : geminiKey
            let isCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines) == candidate
                && keyValidationGeneration[provider] == generation
            if keyValidationGeneration[provider] == generation {
                busyProviders.remove(provider)
            }

            guard isCurrent else { return }
            switch result {
            case .success:
                validatedKeyCandidates[provider] = candidate
            case .failure(let error):
                validatedKeyCandidates.removeValue(forKey: provider)
                apiAlert = APIAlert(
                    title: "Key validation failed",
                    message: error.errorDescription ?? "Unknown error"
                )
            }
        }
        keyValidationRequestTasks[provider] = task
    }

    private var actionStyleOptions: [(key: String, title: String)] {
        var options: [(key: String, title: String)] = [
            (TranslationService.builtInTranslateSelectionKey, "Translate")
        ]
        options.append(contentsOf: customActions.enumerated().map { index, action in
            let trimmed = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? "Action \(index + 1)" : trimmed
            return (action.id.uuidString, title)
        })
        return options
    }

    private func actionStyleToggleBinding(for actionKey: String) -> Binding<Bool> {
        Binding(
            get: { actionStyleContextActionKeys.contains(actionKey) },
            set: { isOn in
                if isOn {
                    actionStyleContextActionKeys.insert(actionKey)
                } else {
                    actionStyleContextActionKeys.remove(actionKey)
                }
            }
        )
    }

    private var hotkeysTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hotkeys")
                        .font(.headline)

                    HStack(alignment: .center, spacing: 12) {
                        Text("Popup")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)

                        KeyboardShortcutRecorder(
                            shortcut: popupHotkey,
                            isInvalid: popupHotkeyError != nil,
                            width: settingsControlColumnWidth
                        ) { candidate in
                            if let error = keyboardMonitor.validatePopupHotkey(candidate, pressMode: popupHotkeyPressMode) {
                                popupHotkeyError = error
                                return
                            }
                            popupHotkey = candidate
                            popupHotkeyError = nil
                        }
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Trigger")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { popupHotkeyPressMode },
                            set: { newMode in
                                if let error = keyboardMonitor.validatePopupHotkey(popupHotkey, pressMode: newMode) {
                                    popupHotkeyError = error
                                    return
                                }
                                popupHotkeyPressMode = newMode
                                popupHotkeyError = nil
                            }
                        )) {
                            ForEach(PopupHotkeyPressMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .top, spacing: 12) {
                        Color.clear
                            .frame(width: settingsLabelColumnWidth, height: 1)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Note: ⌘1, ⌘2, ⌘3, … are static shortcuts and can’t be reassigned.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let popupHotkeyError {
                                Text(popupHotkeyError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .frame(width: settingsControlColumnWidth, alignment: .leading)
                    }

                    permissionsSection
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)

            ForEach(TinyAIPermissions.Permission.allCases) { permission in
                let granted = TinyAIPermissions.isGranted(permission)
                HStack(spacing: 12) {
                    Text(permission.title)
                        .foregroundColor(.secondary)
                        .frame(width: settingsLabelColumnWidth, alignment: .leading)
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(granted ? .green : .orange)
                    Text(granted ? "Granted" : "Required for global hotkeys")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(permission.systemSettingsURL)
                    }
                    .controlSize(.small)
                    .help("Open System Settings → Privacy & Security → \(permission.title)")
                }
                .id("\(permission.rawValue)-\(permissionRefreshToken.uuidString)")
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 8)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshToken = UUID()
        }
    }

    private var primaryActionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Primary actions")
                        .font(.headline)

                    HStack(alignment: .center, spacing: 12) {
                        Text("Starred 1")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { starredPrimarySelectionKey },
                            set: { starredPrimarySelectionKey = $0 }
                        )) {
                            Text("Translate").tag(TranslationService.builtInTranslateSelectionKey)
                            ForEach(customActions) { action in
                                let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Action"
                                : action.title
                                Text(title).tag(action.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Starred 2")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { starredSecondaryActionId ?? customActions.first?.id },
                            set: { starredSecondaryActionId = $0 }
                        )) {
                            ForEach(customActions) { action in
                                let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Action"
                                : action.title
                                Text(title).tag(Optional(action.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Translation")
                        .font(.headline)

                    HStack(alignment: .center, spacing: 12) {
                        Text("Model")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)
                        ModelPicker(selection: $builtInTranslateModel)
                            .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Reasoning")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)
                        ReasoningEffortPicker(selection: $builtInTranslateModel)
                            .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Auto: Main")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)
                        Picker("", selection: $autoTranslateMainLanguage) {
                            ForEach(autoTranslateLanguages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Auto: Add.")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)
                        Picker("", selection: $autoTranslateAdditionalLanguage) {
                            ForEach(autoTranslateLanguages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: settingsControlColumnWidth)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .top, spacing: 12) {
                        Color.clear
                            .frame(width: settingsLabelColumnWidth, height: 1)
                        Text("Used only when the language menu is set to Auto.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: settingsControlColumnWidth, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("Style")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)

                        InsetTextEditor(text: $translationStyleContext)
                            .frame(width: settingsControlColumnWidth, height: 120, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .top, spacing: 12) {
                        Color.clear
                            .frame(width: settingsLabelColumnWidth, height: 1)
                        Text("Optional: add terminology, preferred tone, product names, or any extra context to improve translation quality.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: settingsControlColumnWidth, alignment: .leading)
                    }
                }

            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var styleContextTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Additional style context")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 12) {
                        Text("Context")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)

                        InsetTextEditor(text: $actionStyleContext)
                            .frame(width: settingsControlColumnWidth, height: 120, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()

                    HStack(alignment: .top, spacing: 12) {
                        Color.clear
                            .frame(width: settingsLabelColumnWidth, height: 1)
                        Text("Optional: add tone guidance, preferred terminology, or translation examples.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: settingsControlColumnWidth, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("Applies to")
                            .foregroundColor(.secondary)
                            .frame(width: settingsLabelColumnWidth, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(actionStyleOptions, id: \.key) { option in
                                Toggle(option.title, isOn: actionStyleToggleBinding(for: option.key))
                            }
                        }
                        .frame(width: settingsControlColumnWidth, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .hoverRowHighlight()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var customActionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom actions")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(customActions.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Button \(index + 1)")
                                    .foregroundColor(.secondary)
                                    .font(.callout)

                                HStack(alignment: .center, spacing: 12) {
                                    TextField(
                                        "Title",
                                        text: Binding(
                                            get: { customActions[index].title },
                                            set: { customActions[index].title = String($0.prefix(25)) }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 180)

                                    ModelPicker(selection: $customActions[index].model)
                                        .frame(width: customActionModelPickerWidth)
                                }

                                HStack(alignment: .center, spacing: 12) {
                                    Spacer()
                                    Text("Reasoning")
                                        .foregroundColor(.secondary)
                                    ReasoningEffortPicker(selection: $customActions[index].model)
                                        .frame(width: customActionModelPickerWidth)
                                }

                                InsetTextEditor(text: $customActions[index].prompt)
                                    .frame(height: 90)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                    )
                            }
                            .hoverRowHighlight()
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

private enum SettingsTab: Hashable, CaseIterable {
    case primaryActions
    case customActions
    case styleContext
    case hotkeys
    case api
    case voice
    case agents
    case live

    /// Hidden until agents are enabled in Help.
    var isAgentsBeta: Bool { self == .agents || self == .live }

    var title: String {
        switch self {
        case .primaryActions: return "Primary"
        case .customActions: return "Actions"
        case .styleContext: return "Style"
        case .hotkeys: return "Hotkeys"
        case .api: return "API"
        case .voice: return "Voice"
        case .agents: return "Agents"
        case .live: return "Live"
        }
    }

    var systemImage: String {
        switch self {
        case .primaryActions: return "star.fill"
        case .customActions: return "bolt.fill"
        case .styleContext: return "text.quote"
        case .hotkeys: return "keyboard"
        case .api: return "key.fill"
        case .voice: return "mic.fill"
        case .agents: return "person.wave.2.fill"
        case .live: return "waveform"
        }
    }
}

private struct APIAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct KeyboardShortcutRecorder: View {
    let shortcut: KeyboardShortcut
    let isInvalid: Bool
    let width: CGFloat
    let onCaptured: (KeyboardShortcut) -> Void

    @State private var isRecording: Bool = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            HStack(spacing: 8) {
                Text(isRecording ? "Press shortcut…" : shortcut.displayString)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("Change")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isInvalid ? Color.red : Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .background(
            KeyCaptureViewRepresentable(isRecording: $isRecording) { keyCode, modifiers in
                let candidate = KeyboardShortcut(keyCode: Int64(keyCode), modifiers: modifiers)
                onCaptured(candidate)
            }
            .frame(width: 0, height: 0)
        )
    }
}

struct InsetTextEditor: NSViewRepresentable {
    @Binding var text: String
    var inset: CGSize = CGSize(width: 6, height: 8)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InsetTextEditor
        weak var textView: NSTextView?

        init(_ parent: InsetTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.string = text
        textView.textContainerInset = inset
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
    }
}

private struct KeyCaptureViewRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt16, ShortcutModifiers) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onCapture = { keyCode, modifiers in
            onCapture(keyCode, modifiers)
            DispatchQueue.main.async {
                isRecording = false
            }
        }
        view.onCancel = {
            DispatchQueue.main.async {
                isRecording = false
            }
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.isRecording = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class KeyCaptureView: NSView {
    var onCapture: ((UInt16, ShortcutModifiers) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        let ignoredKeyCodes: Set<UInt16> = [
            54, 55, // ⌘
            56, 60, // ⇧
            58, 61, // ⌥
            59, 62  // ⌃
        ]
        if ignoredKeyCodes.contains(event.keyCode) {
            return
        }

        let modifiers = ShortcutModifiers(modifierFlags: event.modifierFlags)
        onCapture?(event.keyCode, modifiers)
    }
}

/// Picks a model from the supported catalog.  Changing the model keeps the
/// current reasoning effort when the new model accepts it, otherwise it
/// switches to the new model's default effort.
private struct ModelPicker: View {
    @Binding var selection: LLMModel

    var body: some View {
        Picker("", selection: Binding(
            get: { selection.key },
            set: { key in
                guard let entry = ModelCatalog.all.first(where: { $0.model.key == key }) else { return }
                selection = entry.model.withReasoningEffort(entry.resolvedEffort(selection.reasoningEffort))
            }
        )) {
            ForEach(LLMProvider.allCases) { provider in
                Section(provider.displayName) {
                    ForEach(ModelCatalog.models(for: provider)) { entry in
                        Text(entry.displayName).tag(entry.model.key)
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }
}

/// Picks one of the reasoning efforts the selected model supports.
private struct ReasoningEffortPicker: View {
    @Binding var selection: LLMModel

    var body: some View {
        let entry = ModelCatalog.entry(for: selection)
        let efforts = entry?.reasoningEfforts ?? []
        Picker("", selection: Binding(
            get: { entry?.resolvedEffort(selection.reasoningEffort) ?? .medium },
            set: { selection = selection.withReasoningEffort($0) }
        )) {
            ForEach(efforts) { effort in
                Text(effort == entry?.defaultReasoningEffort ? "\(effort.displayName) (default)" : effort.displayName)
                    .tag(effort)
            }
        }
        .pickerStyle(.menu)
        .disabled(efforts.count < 2)
    }
}
