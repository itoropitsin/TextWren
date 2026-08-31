import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var translationService: TranslationService
    @EnvironmentObject var keyboardMonitor: KeyboardMonitor
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: SettingsTab = .api
    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var busyProviders: Set<LLMProvider> = []
    @State private var keyValidationTasks: [LLMProvider: Task<Void, Never>] = [:]
    @State private var keyValidationRequestTasks: [LLMProvider: Task<Void, Never>] = [:]
    @State private var apiAlert: APIAlert?
    @State private var pendingDelete: PendingDelete?
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
    @State private var draftModels: [LLMModelEntry] = []
    @State private var draftModelVisibility: [String: Bool] = [:]
    @State private var draftModelAvailability: [String: Bool] = [:]
    @State private var deletedModelKeys: Set<String> = []
    @State private var validatedKeyCandidates: [LLMProvider: String] = [:]
    @State private var keyValidationGeneration: [LLMProvider: Int] = [:]
    @State private var permissionRefreshToken = UUID()

    private let settingsLabelColumnWidth: CGFloat = 130
    private let settingsControlColumnWidth: CGFloat = 240
    private let customActionModelPickerWidth: CGFloat = 220
    private let autoTranslateLanguages = TranslationService.supportedLanguages
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.title2)
                .padding(.top)

            TabView(selection: $selectedTab) {
                primaryActionsTab
                    .tag(SettingsTab.primaryActions)
                    .tabItem { Label("Primary Actions", systemImage: "star.fill") }

                customActionsTab
                    .tag(SettingsTab.customActions)
                    .tabItem { Label("Custom Actions", systemImage: "bolt.fill") }

                styleContextTab
                    .tag(SettingsTab.styleContext)
                    .tabItem { Label("Style Context", systemImage: "text.quote") }

                hotkeysTab
                    .tag(SettingsTab.hotkeys)
                    .tabItem { Label("Hotkeys", systemImage: "keyboard") }

                apiTab
                    .tag(SettingsTab.api)
                    .tabItem { Label("API", systemImage: "key.fill") }
            }

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
                    translationService.commitModelCatalog(
                        models: draftModels,
                        visibility: draftModelVisibility,
                        availability: draftModelAvailability,
                        deletedKeys: deletedModelKeys
                    )

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
        .frame(width: 520, height: 720)
        .onAppear {
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
            draftModels = translationService.llmModels
            draftModelVisibility = translationService.llmModelVisibility
            draftModelAvailability = translationService.llmModelAvailability
            deletedModelKeys = translationService.deletedModelKeysForSettings
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
        .sheet(item: $pendingDelete) { pending in
            ModelReplacementSheet(
                pending: pending,
                candidates: draftReplacementCandidates(excluding: pending.model),
                onCancel: { pendingDelete = nil },
                onReplaceAndDelete: { replacement in
                    applyReplacementAndDelete(old: pending.model, replacement: replacement)
                    pendingDelete = nil
                }
            )
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Models")
                        .font(.headline)

                    Text("Use the checkboxes to control which models are shown in the Actions model dropdown.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    modelsList
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

                Button {
                    refreshProviderModels(provider)
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !hasDraftKey)
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

    private var modelsList: some View {
        let grouped = Dictionary(grouping: draftModels, by: { $0.model.provider })
        let providers = LLMProvider.allCases

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(providers) { provider in
                let models = (grouped[provider] ?? []).sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }

                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(provider.displayName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        ForEach(models) { entry in
                            modelRow(entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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

    private func refreshProviderModels(_ provider: LLMProvider) {
        guard !busyProviders.contains(provider) else { return }
        busyProviders.insert(provider)

        let key = provider == .openAI ? openAIKey : geminiKey
        let existingKeys = Set(draftModels.map(\.model.key))
        Task { @MainActor in
            defer { busyProviders.remove(provider) }

            let result = await translationService.fetchModelsForSettings(for: provider, apiKey: key)

            switch result {
            case .success(let models):
                applyFetchedModelsToDraft(models, for: provider)
                let addedCount = Set(draftModels.map(\.model.key)).subtracting(existingKeys).count

                if models.isEmpty {
                    apiAlert = APIAlert(
                        title: "No compatible models",
                        message: "\(provider.displayName) returned no models supported by TinyAI."
                    )
                } else if addedCount == 0 {
                    apiAlert = APIAlert(
                        title: "Models are up to date",
                        message: "No new \(provider.displayName) models were found for this API key."
                    )
                }
            case .failure(let error):
                apiAlert = APIAlert(
                    title: "Failed to refresh models",
                    message: error.errorDescription ?? "Unknown error"
                )
            }
        }
    }

    private func applyFetchedModelsToDraft(_ fetched: [LLMModelEntry], for provider: LLMProvider) {
        let merged = TranslationService.mergeFetchedModels(
            existing: draftModels,
            fetched: fetched,
            visibility: draftModelVisibility,
            availability: draftModelAvailability,
            provider: provider,
            deletedKeys: deletedModelKeys
        )
        draftModels = merged.models
        draftModelVisibility = merged.visibility
        draftModelAvailability = merged.availability
    }

    private func modelRow(_ entry: LLMModelEntry) -> some View {
        let isDeprecated = !(draftModelAvailability[entry.model.key] ?? true)

        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { draftModelVisibility[entry.model.key] ?? true },
                set: { draftModelVisibility[entry.model.key] = $0 }
            )) {
                Text(entry.displayName)
                    .foregroundColor(isDeprecated ? .red : .primary)
            }

            Spacer(minLength: 8)

            if isDeprecated {
                Button {
                    apiAlert = APIAlert(
                        title: "Model is no longer available",
                        message: "This model is not returned by the provider for your current API key, but it remains in the list for compatibility."
                    )
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("No longer available")
            }

            Button(role: .destructive) {
                requestDelete(entry.model)
            } label: {
                Text("Delete")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func requestDelete(_ model: LLMModel) {
        guard draftModels.count > 1 else {
            apiAlert = APIAlert(
                title: "Keep at least one model",
                message: "TinyAI needs one available model to run an action."
            )
            return
        }

        let usedInTranslate = builtInTranslateModel == model
        let actionIndexes = customActions.indices.filter { customActions[$0].model == model }

        if usedInTranslate || !actionIndexes.isEmpty {
            pendingDelete = PendingDelete(model: model, usedInTranslate: usedInTranslate, actionIndexes: actionIndexes)
            return
        }

        removeDraftModel(model)
    }

    private func applyReplacementAndDelete(old: LLMModel, replacement: LLMModel) {
        if builtInTranslateModel == old {
            builtInTranslateModel = replacement
        }

        if customActions.contains(where: { $0.model == old }) {
            customActions = customActions.map { action in
                if action.model == old {
                    var copy = action
                    copy.model = replacement
                    return copy
                }
                return action
            }
        }

        removeDraftModel(old)
    }

    private func removeDraftModel(_ model: LLMModel) {
        draftModels.removeAll { $0.model == model }
        draftModelVisibility.removeValue(forKey: model.key)
        draftModelAvailability.removeValue(forKey: model.key)
        deletedModelKeys.insert(model.key)
    }

    private func draftReplacementCandidates(excluding model: LLMModel) -> [LLMModelEntry] {
        draftModels
            .filter { $0.model != model }
            .filter { draftModelAvailability[$0.model.key] ?? true }
            .sorted { $0.displayNameWithProvider.localizedCaseInsensitiveCompare($1.displayNameWithProvider) == .orderedAscending }
    }

    private func draftModelsForActionsPickerIncluding(_ selection: LLMModel) -> [LLMModelEntry] {
        var list = draftModels
            .filter { draftModelVisibility[$0.model.key] ?? true }
            .sorted { $0.displayNameWithProvider.localizedCaseInsensitiveCompare($1.displayNameWithProvider) == .orderedAscending }
        if !list.contains(where: { $0.model == selection }) {
            let fallbackName = draftModels.first(where: { $0.model == selection })?.displayName ?? selection.name
            list.insert(LLMModelEntry(model: selection, displayName: fallbackName), at: 0)
        }
        return list
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
                }
                .id("\(permission.rawValue)-\(permissionRefreshToken.uuidString)")
                .padding(.vertical, 2)
            }

            HStack(alignment: .top, spacing: 12) {
                Color.clear
                    .frame(width: settingsLabelColumnWidth, height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Button("Request permission") {
                        _ = TinyAIPermissions.requestMissing(explicit: true)
                        _ = keyboardMonitor.startMonitoringIfPermitted()
                        permissionRefreshToken = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(TinyAIPermissions.allGranted)
                    Text("If a request was previously declined, use this button to try again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(width: settingsControlColumnWidth, alignment: .leading)
            }
        }
        .padding(.top, 8)
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
                        Picker("", selection: $builtInTranslateModel) {
                            ForEach(draftModelsForActionsPickerIncluding(builtInTranslateModel)) { entry in
                                Text(entry.displayNameWithProvider).tag(entry.model)
                            }
                        }
                        .pickerStyle(.menu)
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

                                    Picker("", selection: $customActions[index].model) {
                                        ForEach(draftModelsForActionsPickerIncluding(customActions[index].model)) { entry in
                                            Text(entry.displayNameWithProvider).tag(entry.model)
                                        }
                                    }
                                    .pickerStyle(.menu)
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

private enum SettingsTab: Hashable {
    case api
    case hotkeys
    case primaryActions
    case customActions
    case styleContext
}

private struct APIAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct PendingDelete: Identifiable {
    let id = UUID()
    let model: LLMModel
    let usedInTranslate: Bool
    let actionIndexes: [Int]
}

private struct ModelReplacementSheet: View {
    let pending: PendingDelete
    let candidates: [LLMModelEntry]
    let onCancel: () -> Void
    let onReplaceAndDelete: (LLMModel) -> Void

    @State private var selection: LLMModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace model before deleting")
                .font(.headline)

            Text(usageSummary)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Replacement model", selection: Binding(
                get: { selection ?? candidates.first?.model },
                set: { selection = $0 }
            )) {
                ForEach(candidates) { entry in
                    Text(entry.displayNameWithProvider).tag(Optional(entry.model))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Replace & Delete") {
                    if let selected = selection ?? candidates.first?.model {
                        onReplaceAndDelete(selected)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidates.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            selection = candidates.first?.model
        }
    }

    private var usageSummary: String {
        var parts: [String] = []
        if pending.usedInTranslate {
            parts.append("Translate")
        }
        if !pending.actionIndexes.isEmpty {
            let buttons = pending.actionIndexes
                .sorted()
                .map { "Button \($0 + 1)" }
                .joined(separator: ", ")
            parts.append(buttons)
        }
        if parts.isEmpty {
            return "This model is not currently used, but a replacement is still required."
        }
        return "This model is used by: \(parts.joined(separator: ", ")). Choose a replacement to continue."
    }
}

private struct KeyboardShortcutRecorder: View {
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

private struct InsetTextEditor: NSViewRepresentable {
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
