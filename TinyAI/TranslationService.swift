import Foundation
import Combine

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Hashable {
    case openAI = "openai"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .gemini:
            return "Google Gemini"
        }
    }

    var keychainAccount: String {
        switch self {
        case .openAI:
            return "OpenAIAPIKey"
        case .gemini:
            return "GeminiAPIKey"
        }
    }
}

struct LLMModel: Codable, Hashable, Identifiable {
    var provider: LLMProvider
    var name: String

    var id: String { key }
    var key: String { "\(provider.rawValue):\(name)" }
}

struct LLMModelEntry: Codable, Hashable, Identifiable {
    var model: LLMModel
    var displayName: String

    var id: String { model.key }

    var displayNameWithProvider: String {
        "\(model.provider.displayName): \(displayName)"
    }
}

struct LLMModelCatalogMergeResult {
    var models: [LLMModelEntry]
    var visibility: [String: Bool]
    var availability: [String: Bool]
}

struct LLMKeyValidationError: LocalizedError, Equatable {
    let provider: LLMProvider
    let statusCode: Int?
    let message: String

    var errorDescription: String? {
        if let statusCode {
            return "\(provider.displayName) key validation failed (\(statusCode)): \(message)"
        }
        return "\(provider.displayName) key validation failed: \(message)"
    }
}

enum OpenAIModel: String, CaseIterable, Identifiable, Codable {
    case gpt52 = "gpt-5.2"
    case gpt5Mini = "gpt-5-mini"
    case gpt5Nano = "gpt-5-nano"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt52:
            return "gpt-5.2"
        case .gpt5Mini:
            return "gpt-5-mini"
        case .gpt5Nano:
            return "gpt-5-nano"
        }
    }
}

struct CustomAction: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var prompt: String
    var model: LLMModel

    init(
        id: UUID = UUID(),
        title: String = "",
        prompt: String = "",
        model: LLMModel = TranslationService.defaultModel
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case prompt
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        prompt = (try? container.decode(String.self, forKey: .prompt)) ?? ""
        if let decoded = try? container.decode(LLMModel.self, forKey: .model) {
            model = decoded
        } else if let legacy = try? container.decode(OpenAIModel.self, forKey: .model) {
            model = LLMModel(provider: .openAI, name: legacy.rawValue)
        } else {
            model = TranslationService.defaultModel
        }

    }
}

enum TranslationLanguageMode: Equatable {
    case fixed(String)
    case automatic(main: String, additional: String)
}

class TranslationService: ObservableObject {
    static let languageAutoSelection = "Auto"
    static let supportedLanguages: [String] = [
        "English", "Russian", "Spanish", "French", "German", "Italian",
        "Portuguese", "Chinese", "Japanese", "Korean", "Arabic", "Dutch",
        "Polish", "Turkish", "Swedish", "Norwegian", "Danish", "Finnish"
    ]
    static let defaultModel = LLMModel(provider: .openAI, name: OpenAIModel.gpt5Mini.rawValue)

    @Published var apiKey: String = "" {
        didSet {
            guard !isLoadingAPIKeys else { return }
            let needsExplicitSave = providersNeedingExplicitKeychainSave.contains(.openAI)
            guard apiKey != oldValue || needsExplicitSave else { return }

            if persistAPIKey(apiKey, provider: .openAI) {
                markKeychainPersistenceSucceeded(for: .openAI)
            } else if !apiKey.isEmpty {
                errorMessage = "Could not save the OpenAI API key in Keychain."
                providersNeedingExplicitKeychainSave.insert(.openAI)
            }
        }
    }

    @Published var geminiAPIKey: String = "" {
        didSet {
            guard !isLoadingAPIKeys else { return }
            let needsExplicitSave = providersNeedingExplicitKeychainSave.contains(.gemini)
            guard geminiAPIKey != oldValue || needsExplicitSave else { return }

            if persistAPIKey(geminiAPIKey, provider: .gemini) {
                markKeychainPersistenceSucceeded(for: .gemini)
            } else if !geminiAPIKey.isEmpty {
                errorMessage = "Could not save the Gemini API key in Keychain."
                providersNeedingExplicitKeychainSave.insert(.gemini)
            }
        }
    }

    @Published var customActions: [CustomAction] = [] {
        didSet {
            saveCustomActionsToDefaults(customActions)
        }
    }

    static let builtInTranslateSelectionKey = "builtin_translate"

    @Published var starredPrimarySelectionKey: String = TranslationService.builtInTranslateSelectionKey {
        didSet {
            saveStarredPrimarySelectionKeyToDefaults(starredPrimarySelectionKey)
        }
    }

    @Published var starredSecondaryActionId: UUID? {
        didSet {
            saveStarredActionIdToDefaults(starredSecondaryActionId, key: starredSecondaryDefaultsKey)
        }
    }

    @Published var builtInTranslateModel: LLMModel = TranslationService.defaultModel {
        didSet {
            defaults.set(builtInTranslateModel.key, forKey: builtInTranslateModelDefaultsKey)
        }
    }

    @Published private(set) var llmModels: [LLMModelEntry] = []
    @Published var llmModelVisibility: [String: Bool] = [:] {
        didSet {
            saveModelVisibilityToDefaults(llmModelVisibility)
        }
    }
    @Published var llmModelAvailability: [String: Bool] = [:] {
        didSet {
            saveModelAvailabilityToDefaults(llmModelAvailability)
        }
    }

    var deletedModelKeysForSettings: Set<String> {
        deletedModelKeys
    }

    @Published var preferredTargetLanguage: String = "English" {
        didSet {
            let normalized = normalizedLanguageSelection(preferredTargetLanguage)
            if normalized != preferredTargetLanguage {
                preferredTargetLanguage = normalized
                return
            }
            defaults.set(preferredTargetLanguage, forKey: preferredTargetLanguageDefaultsKey)
        }
    }

    @Published var autoTranslateMainLanguage: String = "Russian" {
        didSet {
            let normalized = normalizedSupportedLanguage(autoTranslateMainLanguage, fallback: "Russian")
            if normalized != autoTranslateMainLanguage {
                autoTranslateMainLanguage = normalized
                return
            }
            defaults.set(autoTranslateMainLanguage, forKey: autoTranslateMainLanguageDefaultsKey)
        }
    }

    @Published var autoTranslateAdditionalLanguage: String = "English" {
        didSet {
            let normalized = normalizedSupportedLanguage(autoTranslateAdditionalLanguage, fallback: "English")
            if normalized != autoTranslateAdditionalLanguage {
                autoTranslateAdditionalLanguage = normalized
                return
            }
            defaults.set(autoTranslateAdditionalLanguage, forKey: autoTranslateAdditionalLanguageDefaultsKey)
        }
    }

    @Published var translationStyleContext: String = "" {
        didSet {
            defaults.set(translationStyleContext, forKey: translationStyleContextDefaultsKey)
        }
    }

    @Published var actionStyleContext: String = "" {
        didSet {
            defaults.set(actionStyleContext, forKey: actionStyleContextDefaultsKey)
        }
    }

    @Published var actionStyleContextActionKeys: Set<String> = [] {
        didSet {
            defaults.set(Array(actionStyleContextActionKeys), forKey: actionStyleContextActionKeysDefaultsKey)
        }
    }

    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    /// Result of the last non-destructive Keychain read. A protected item is
    /// kept distinct from a missing item so startup never overwrites it.
    @Published private(set) var keychainReadStatuses: [LLMProvider: KeychainReadResult] = [:]

    private let openAIChatCompletionsURLString = "https://api.openai.com/v1/chat/completions"
    private let openAIResponsesURLString = "https://api.openai.com/v1/responses"
    private let keychainService: String
    private let keychainClient: KeychainClient
    private let defaults: UserDefaults
    private let session: URLSession
    private let jsonDecoder = JSONDecoder()
    private var isLoadingAPIKeys = false
    private var providersNeedingExplicitKeychainSave: Set<LLMProvider> = []
    private var legacyOpenAIKeyNeedsRemoval = false

    private let apiKeyDefaultsKey = "OpenAIAPIKey"
    private let legacyModelDefaultsKey = "OpenAIModel"
    private let customActionsDefaultsKey = "CustomActionsV1"
    private let starredPrimaryDefaultsKey = "StarredPrimaryActionIdV1"
    private let starredSecondaryDefaultsKey = "StarredSecondaryActionIdV1"
    private let starredPrimarySelectionDefaultsKeyV2 = "StarredPrimarySelectionKeyV2"
    private let builtInTranslateModelDefaultsKey = "BuiltInTranslateModelV1"
    private let autoTranslateMainLanguageDefaultsKey = "AutoTranslateMainLanguageV1"
    private let autoTranslateAdditionalLanguageDefaultsKey = "AutoTranslateAdditionalLanguageV1"
    private let translationStyleContextDefaultsKey = "TranslationStyleContextV1"
    private let actionStyleContextDefaultsKey = "ActionStyleContextV1"
    private let actionStyleContextActionKeysDefaultsKey = "ActionStyleContextActionKeysV1"
    private let preferredTargetLanguageDefaultsKey = "PreferredTargetLanguageV1"
    private let llmModelsDefaultsKey = "LLMModelsV1"
    private let llmModelVisibilityDefaultsKey = "LLMModelVisibilityV1"
    private let llmModelAvailabilityDefaultsKey = "LLMModelAvailabilityV1"
    private let deletedLLMModelsDefaultsKey = "DeletedLLMModelsV1"
    private var deletedModelKeys: Set<String> = []
    
    init(keychainClient: KeychainClient? = nil, defaults: UserDefaults = TinyAIRuntime.userDefaults) {
        keychainService = "IT.TinyAI"
        self.keychainClient = keychainClient ?? KeychainStore.client
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)

        isLoadingAPIKeys = true
        if TinyAIRuntime.isTestEnvironment, keychainClient == nil {
            apiKey = ""
            geminiAPIKey = ""
        } else {
            apiKey = loadOrMigrateAPIKey(provider: .openAI)
            geminiAPIKey = loadOrMigrateAPIKey(provider: .gemini)
        }
        isLoadingAPIKeys = false

        builtInTranslateModel = loadBuiltInTranslateModel()

        llmModels = loadModelsFromDefaults()
        llmModelVisibility = loadModelVisibilityFromDefaults()
        llmModelAvailability = loadModelAvailabilityFromDefaults()
        deletedModelKeys = Set(defaults.stringArray(forKey: deletedLLMModelsDefaultsKey) ?? [])
        normalizeModelsAndVisibility()

        preferredTargetLanguage = normalizedLanguageSelection(
            defaults.string(forKey: preferredTargetLanguageDefaultsKey) ?? preferredTargetLanguage
        )

        autoTranslateMainLanguage = normalizedSupportedLanguage(
            defaults.string(forKey: autoTranslateMainLanguageDefaultsKey) ?? autoTranslateMainLanguage,
            fallback: "Russian"
        )
        autoTranslateAdditionalLanguage = normalizedSupportedLanguage(
            defaults.string(forKey: autoTranslateAdditionalLanguageDefaultsKey) ?? autoTranslateAdditionalLanguage,
            fallback: "English"
        )

        translationStyleContext = defaults.string(forKey: translationStyleContextDefaultsKey) ?? ""
        actionStyleContext = defaults.string(forKey: actionStyleContextDefaultsKey) ?? ""
        actionStyleContextActionKeys = Set(
            defaults.array(forKey: actionStyleContextActionKeysDefaultsKey) as? [String] ?? []
        )

        let loadedActions = loadCustomActionsFromDefaults()
        if let loadedActions {
            customActions = normalizeCustomActions(loadedActions)
        } else {
            customActions = normalizeCustomActions([])
        }

        if loadedActions == nil {
            applyBuiltInDefaultsIfNeeded(force: true)
        } else {
            applyBuiltInDefaultsIfNeeded(force: false)
        }

        starredPrimarySelectionKey = loadOrMigrateStarredPrimarySelectionKey(legacyPrimaryId: loadStarredActionIdFromDefaults(key: starredPrimaryDefaultsKey))
        starredSecondaryActionId = loadStarredActionIdFromDefaults(key: starredSecondaryDefaultsKey)

        clearLegacyDefaultTranslationActionIfPresent()
        applyBuiltInDefaultsIfNeeded(force: false)
        normalizeStarredActionIds()
        normalizeActionStyleContextActionKeys()
    }
    
    func saveAPIKey(_ key: String) {
        saveAPIKey(key, for: .openAI)
    }

    func saveAPIKey(_ key: String, for provider: LLMProvider) {
        setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
    }

    func apiKey(for provider: LLMProvider) -> String {
        switch provider {
        case .openAI:
            return apiKey
        case .gemini:
            return geminiAPIKey
        }
    }

    func hasAPIKey(for provider: LLMProvider) -> Bool {
        !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func keychainStatus(for provider: LLMProvider) -> KeychainReadResult? {
        keychainReadStatuses[provider]
    }

    /// Retry a protected Keychain read only after an explicit Settings action.
    /// The cache deliberately bypasses an interaction-required result for this
    /// call, while normal startup reads remain non-interactive and cached.
    @discardableResult
    func retryKeychainAccess(for provider: LLMProvider) -> KeychainReadResult {
        let result = keychainClient.readString(
            service: keychainService,
            account: provider.keychainAccount,
            allowInteraction: true
        )
        keychainReadStatuses[provider] = result

        // A missing legacy item can be migrated during this explicit retry.
        // Return the effective result of that operation, rather than the
        // intermediate Keychain read, so callers can update their state from
        // the value that is now actually available.
        var effectiveResult = result

        switch result {
        case .value(let value):
            isLoadingAPIKeys = true
            setAPIKey(value, for: provider)
            isLoadingAPIKeys = false
            // A successful explicit read proves that the protected item is
            // available. Clear any pending migration marker so reopening
            // Settings does not schedule another write, and remove the old
            // UserDefaults copy only after the Keychain value is confirmed.
            markKeychainPersistenceSucceeded(for: provider)
        case .missing:
            // A user-triggered read is also a safe point to finish a legacy
            // migration. The startup path uses the same helper with
            // interaction disabled; here the user has explicitly asked us to
            // retry, so a protected Keychain write may be allowed to ask once.
            if provider == .openAI,
               let legacyKey = defaults.string(forKey: apiKeyDefaultsKey) {
                let migrated = keychainClient.saveString(
                    legacyKey,
                    service: keychainService,
                    account: provider.keychainAccount,
                    allowInteraction: true
                )
                if migrated {
                    defaults.removeObject(forKey: apiKeyDefaultsKey)
                    keychainReadStatuses[provider] = .value(legacyKey)
                    effectiveResult = .value(legacyKey)
                    isLoadingAPIKeys = true
                    setAPIKey(legacyKey, for: provider)
                    isLoadingAPIKeys = false
                    markKeychainPersistenceSucceeded(for: provider)
                } else {
                    providersNeedingExplicitKeychainSave.insert(provider)
                    legacyOpenAIKeyNeedsRemoval = true
                    keychainReadStatuses[provider] = .interactionRequired
                    effectiveResult = .interactionRequired
                }
            }
        case .interactionRequired, .failure:
            break
        }
        return effectiveResult
    }

    @MainActor
    func validateAndSaveAPIKey(_ key: String, for provider: LLMProvider) async -> Result<Void, LLMKeyValidationError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            setAPIKey("", for: provider)
            return .success(())
        }

        let result = await validateAPIKey(trimmed, for: provider)
        switch result {
        case .success:
            setAPIKey(trimmed, for: provider)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Validate a draft key without changing the saved key or model catalog.
    @MainActor
    func validateAPIKeyOnly(_ key: String, for provider: LLMProvider) async -> Result<Void, LLMKeyValidationError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .success(())
        }
        return await validateAPIKey(trimmed, for: provider)
    }

    @MainActor
    func refreshModels(for provider: LLMProvider) async -> Result<Void, LLMKeyValidationError> {
        let key = apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(LLMKeyValidationError(provider: provider, statusCode: nil, message: "API key is not set"))
        }

        do {
            let fetched = try await fetchModels(provider: provider, apiKey: key)
            applyFetchedModels(fetched, for: provider)
            return .success(())
        } catch let error as LLMKeyValidationError {
            return .failure(error)
        } catch {
            return .failure(LLMKeyValidationError(provider: provider, statusCode: nil, message: error.localizedDescription))
        }
    }

    /// Fetch models for the Settings draft without applying them to the live service.
    @MainActor
    func fetchModelsForSettings(for provider: LLMProvider, apiKey: String) async -> Result<[LLMModelEntry], LLMKeyValidationError> {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(LLMKeyValidationError(provider: provider, statusCode: nil, message: "API key is not set"))
        }

        do {
            return .success(try await fetchModels(provider: provider, apiKey: trimmed))
        } catch let error as LLMKeyValidationError {
            return .failure(error)
        } catch {
            return .failure(LLMKeyValidationError(provider: provider, statusCode: nil, message: error.localizedDescription))
        }
    }

    func saveCustomActions(_ actions: [CustomAction]) {
        customActions = normalizeCustomActions(actions)
        applyBuiltInDefaultsIfNeeded(force: false)
        clearLegacyDefaultTranslationActionIfPresent()
        normalizeStarredActionIds()
        normalizeActionStyleContextActionKeys()
    }

    func saveStarredPrimarySelectionKey(_ key: String) {
        starredPrimarySelectionKey = key
        normalizeStarredActionIds()
    }

    func saveStarredSecondaryActionId(_ id: UUID?) {
        starredSecondaryActionId = id
        normalizeStarredActionIds()
    }

    func saveBuiltInTranslateModel(_ model: LLMModel) {
        builtInTranslateModel = model
    }

    func saveAutoTranslateMainLanguage(_ language: String) {
        autoTranslateMainLanguage = normalizedSupportedLanguage(language, fallback: "Russian")
    }

    func saveAutoTranslateAdditionalLanguage(_ language: String) {
        autoTranslateAdditionalLanguage = normalizedSupportedLanguage(language, fallback: "English")
    }

    func saveTranslationStyleContext(_ context: String) {
        translationStyleContext = context
    }

    func saveActionStyleContext(_ context: String) {
        actionStyleContext = context
    }

    func saveActionStyleContextActionKeys(_ keys: Set<String>) {
        actionStyleContextActionKeys = keys
        normalizeActionStyleContextActionKeys()
    }

    func translationLanguageMode(for selectedLanguage: String) -> TranslationLanguageMode {
        guard selectedLanguage == Self.languageAutoSelection else {
            return .fixed(selectedLanguage)
        }
        return .automatic(
            main: autoTranslateMainLanguage,
            additional: autoTranslateAdditionalLanguage
        )
    }

    func targetLanguagePromptValue(for selectedLanguage: String) -> String {
        switch translationLanguageMode(for: selectedLanguage) {
        case .fixed(let language):
            return language
        case .automatic(let main, let additional):
            return "\(additional) when the source is predominantly \(main); otherwise \(main) (choose from the complete human-readable prose; preserve URLs, domains, paths, code, identifiers, product names, and markup without letting them decide the language alone)"
        }
    }

    private func normalizedSupportedLanguage(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard Self.supportedLanguages.contains(trimmed) else { return fallback }
        return trimmed
    }

    private func normalizedLanguageSelection(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "English" }
        if trimmed == Self.languageAutoSelection {
            return trimmed
        }
        return normalizedSupportedLanguage(trimmed, fallback: "English")
    }

    private func normalizeCustomActions(_ actions: [CustomAction]) -> [CustomAction] {
        var result = Array(actions.prefix(5))
        while result.count < 5 {
            result.append(CustomAction())
        }
        return result
    }

    private func normalizeActionStyleContextActionKeys() {
        let allowedKeys = Set([TranslationService.builtInTranslateSelectionKey] + customActions.map { $0.id.uuidString })
        let normalized = actionStyleContextActionKeys.intersection(allowedKeys)
        if normalized != actionStyleContextActionKeys {
            actionStyleContextActionKeys = normalized
        }
    }

    private func normalizeStarredActionIds() {
        if starredPrimarySelectionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            starredPrimarySelectionKey = TranslationService.builtInTranslateSelectionKey
        }

        if starredPrimarySelectionKey != TranslationService.builtInTranslateSelectionKey {
            if UUID(uuidString: starredPrimarySelectionKey) == nil {
                starredPrimarySelectionKey = TranslationService.builtInTranslateSelectionKey
            } else if customActions.first(where: { $0.id.uuidString == starredPrimarySelectionKey }) == nil {
                starredPrimarySelectionKey = customActions.first?.id.uuidString ?? TranslationService.builtInTranslateSelectionKey
            }
        }

        if starredSecondaryActionId == nil {
            starredSecondaryActionId = customActions.first?.id
        }

        if starredPrimarySelectionKey != TranslationService.builtInTranslateSelectionKey,
           let primary = UUID(uuidString: starredPrimarySelectionKey),
           let secondary = starredSecondaryActionId,
           primary == secondary {
            starredSecondaryActionId = customActions.first(where: { $0.id != primary })?.id
        }
    }

    private func applyBuiltInDefaultsIfNeeded(force: Bool) {
        guard customActions.count >= 1 else {
            return
        }

        let defaultModel = resolveLegacyDefaultLLMModel()

        let hasAnyConfigured = customActions.contains { action in
            !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !force && hasAnyConfigured {
            return
        }

        let defaultGrammarPrompt = """
You are an expert editor.
Fix punctuation, grammar, and awkward or unclear constructions while preserving the original meaning and writing style.

Rules:
- Keep the original language.
- Preserve tone (formal/informal), voice, and intent.
- Preserve formatting: line breaks, lists, numbering, emojis, code blocks, and URLs.
- Preserve every Markdown link destination exactly. You may correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Do not add explanations, notes, or commentary.
- Output only the corrected version of the text.
"""

        customActions[0].title = "Grammar"
        customActions[0].prompt = defaultGrammarPrompt
        customActions[0].model = defaultModel
    }

    private func resolveLegacyDefaultModel() -> OpenAIModel {
        if let savedLegacyModelRaw = defaults.string(forKey: legacyModelDefaultsKey),
           let savedModel = OpenAIModel(rawValue: savedLegacyModelRaw) {
            return savedModel
        }
        return .gpt5Mini
    }

    private func resolveLegacyDefaultLLMModel() -> LLMModel {
        LLMModel(provider: .openAI, name: resolveLegacyDefaultModel().rawValue)
    }

    @discardableResult
    private func persistAPIKey(_ value: String, provider: LLMProvider) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return keychainClient.delete(service: keychainService, account: provider.keychainAccount, allowInteraction: true)
        } else {
            return keychainClient.saveString(trimmed, service: keychainService, account: provider.keychainAccount, allowInteraction: true)
        }
    }

    private func loadOrMigrateAPIKey(provider: LLMProvider) -> String {
        let readResult = keychainClient.readString(
            service: keychainService,
            account: provider.keychainAccount,
            allowInteraction: false
        )
        keychainReadStatuses[provider] = readResult

        switch readResult {
        case .value(let savedKey):
            return savedKey
        case .interactionRequired, .failure:
            // A protected item must not be treated as missing. In particular,
            // do not overwrite it or repeatedly retry a request that could show
            // a Keychain dialog during application startup.
            if provider == .openAI, defaults.string(forKey: apiKeyDefaultsKey) != nil {
                legacyOpenAIKeyNeedsRemoval = true
            }
            return ""
        case .missing:
            guard provider == .openAI,
                  let legacySavedKey = defaults.string(forKey: apiKeyDefaultsKey) else {
                return ""
            }

            let migrated = keychainClient.saveString(
                legacySavedKey,
                service: keychainService,
                account: provider.keychainAccount,
                allowInteraction: false
            )
            if migrated {
                defaults.removeObject(forKey: apiKeyDefaultsKey)
                keychainReadStatuses[provider] = .value(legacySavedKey)
            } else {
                // Keep the legacy value available in memory, but let the next
                // explicit Settings save retry the Keychain write even when
                // the user leaves the text unchanged.
                providersNeedingExplicitKeychainSave.insert(provider)
                legacyOpenAIKeyNeedsRemoval = true
                // The read was non-interactive and correctly reported a
                // missing item, but the guarded migration write may itself
                // require confirmation. Surface that distinction in Settings
                // instead of silently presenting a healthy-looking key.
                keychainReadStatuses[provider] = .interactionRequired
            }
            return legacySavedKey
        }
    }

    private func markKeychainPersistenceSucceeded(for provider: LLMProvider) {
        providersNeedingExplicitKeychainSave.remove(provider)
        // A successful Settings save is also a successful read for the
        // purpose of the status shown in Settings.  Clear a stale
        // "confirmation required" marker so reopening Settings does not keep
        // offering a retry after the item is already available.
        let persistedValue = apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        keychainReadStatuses[provider] = persistedValue.isEmpty
            ? .missing
            : .value(persistedValue)
        if provider == .openAI, legacyOpenAIKeyNeedsRemoval {
            defaults.removeObject(forKey: apiKeyDefaultsKey)
            legacyOpenAIKeyNeedsRemoval = false
        }
    }

    private func setAPIKey(_ key: String, for provider: LLMProvider) {
        switch provider {
        case .openAI:
            apiKey = key
        case .gemini:
            geminiAPIKey = key
        }
    }

    private func loadBuiltInTranslateModel() -> LLMModel {
        if let savedKey = defaults.string(forKey: builtInTranslateModelDefaultsKey),
           let parsed = parseModelKey(savedKey) {
            return parsed
        }

        if let savedLegacyModelRaw = defaults.string(forKey: builtInTranslateModelDefaultsKey),
           let legacy = OpenAIModel(rawValue: savedLegacyModelRaw) {
            return LLMModel(provider: .openAI, name: legacy.rawValue)
        }

        return resolveLegacyDefaultLLMModel()
    }

    private func parseModelKey(_ key: String) -> LLMModel? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let provider = LLMProvider(rawValue: parts[0]),
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LLMModel(provider: provider, name: parts[1])
    }

    var modelsForActionsPicker: [LLMModelEntry] {
        let filtered = llmModels.filter { llmModelVisibility[$0.model.key] ?? true }
        return filtered.sorted { $0.displayNameWithProvider.localizedCaseInsensitiveCompare($1.displayNameWithProvider) == .orderedAscending }
    }

    func modelsForActionsPickerIncluding(_ selection: LLMModel) -> [LLMModelEntry] {
        var list = modelsForActionsPicker
        if !list.contains(where: { $0.model == selection }) {
            let fallbackName = llmModels.first(where: { $0.model == selection })?.displayName ?? selection.name
            list.insert(LLMModelEntry(model: selection, displayName: fallbackName), at: 0)
        }
        return list
    }

    func setModelVisible(_ model: LLMModel, visible: Bool) {
        llmModelVisibility[model.key] = visible
    }

    func isModelVisible(_ model: LLMModel) -> Bool {
        llmModelVisibility[model.key] ?? true
    }

	    func isModelAvailable(_ model: LLMModel) -> Bool {
	        llmModelAvailability[model.key] ?? true
	    }

	    private func displayNameWithProvider(for model: LLMModel) -> String {
	        if let entry = llmModels.first(where: { $0.model == model }) {
	            return entry.displayNameWithProvider
	        }
	        return "\(model.provider.displayName): \(model.name)"
	    }

	    private func guardModelAvailable(_ model: LLMModel, completion: @escaping (Result<String, Error>) -> Void) -> Bool {
	        guard isModelAvailable(model) else {
	            completion(.failure(TranslationError.modelUnavailable(displayNameWithProvider(for: model))))
	            return false
	        }
	        return true
	    }

    func replacementCandidates(excluding model: LLMModel) -> [LLMModelEntry] {
        llmModels
            .filter { $0.model != model }
            .filter { isModelAvailable($0.model) }
            .sorted { $0.displayNameWithProvider.localizedCaseInsensitiveCompare($1.displayNameWithProvider) == .orderedAscending }
    }

    func deleteModel(_ model: LLMModel) {
        guard llmModels.count > 1 else {
            errorMessage = "Keep at least one model configured."
            return
        }

        deletedModelKeys.insert(model.key)
        defaults.set(Array(deletedModelKeys), forKey: deletedLLMModelsDefaultsKey)
        llmModels.removeAll { $0.model == model }
        llmModelVisibility.removeValue(forKey: model.key)
        llmModelAvailability.removeValue(forKey: model.key)

        if builtInTranslateModel == model {
            builtInTranslateModel = Self.defaultModel
        }

        if customActions.contains(where: { $0.model == model }) {
            let updated = customActions.map { action -> CustomAction in
                if action.model == model {
                    var copy = action
                    copy.model = Self.defaultModel
                    return copy
                }
                return action
            }
            customActions = updated
        }

        saveModelsToDefaults(llmModels)
        saveModelVisibilityToDefaults(llmModelVisibility)
        saveModelAvailabilityToDefaults(llmModelAvailability)
    }

    @MainActor
    func commitModelCatalog(
        models: [LLMModelEntry],
        visibility: [String: Bool],
        availability: [String: Bool],
        deletedKeys: Set<String>
    ) {
        deletedModelKeys.formUnion(deletedKeys)
        defaults.set(Array(deletedModelKeys), forKey: deletedLLMModelsDefaultsKey)

        llmModels = Self.dedupModels(models).filter { !deletedModelKeys.contains($0.model.key) }
        llmModelVisibility = visibility.filter { !deletedModelKeys.contains($0.key) }
        llmModelAvailability = availability.filter { !deletedModelKeys.contains($0.key) }
        normalizeModelsAndVisibility()
    }

    private func loadModelsFromDefaults() -> [LLMModelEntry] {
        guard let data = defaults.data(forKey: llmModelsDefaultsKey),
              let decoded = try? JSONDecoder().decode([LLMModelEntry].self, from: data) else {
            return OpenAIModel.allCases.map { legacy in
                LLMModelEntry(model: LLMModel(provider: .openAI, name: legacy.rawValue), displayName: legacy.displayName)
            }
        }
        return decoded
    }

    private func saveModelsToDefaults(_ models: [LLMModelEntry]) {
        guard let data = try? JSONEncoder().encode(models) else {
            return
        }
        defaults.set(data, forKey: llmModelsDefaultsKey)
    }

    private func loadModelVisibilityFromDefaults() -> [String: Bool] {
        guard let data = defaults.data(forKey: llmModelVisibilityDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveModelVisibilityToDefaults(_ map: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(map) else {
            return
        }
        defaults.set(data, forKey: llmModelVisibilityDefaultsKey)
    }

    private func loadModelAvailabilityFromDefaults() -> [String: Bool] {
        guard let data = defaults.data(forKey: llmModelAvailabilityDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveModelAvailabilityToDefaults(_ map: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(map) else {
            return
        }
        defaults.set(data, forKey: llmModelAvailabilityDefaultsKey)
    }

    private func normalizeModelsAndVisibility() {
        if llmModels.isEmpty {
            llmModels = OpenAIModel.allCases.map { legacy in
                LLMModelEntry(model: LLMModel(provider: .openAI, name: legacy.rawValue), displayName: legacy.displayName)
            }
        }

        llmModels = llmModels
            .filter { !deletedModelKeys.contains($0.model.key) }
            .filter { entry in
                entry.model.provider != .openAI || Self.isSupportedOpenAITextModel(entry.model.name)
            }

        var visibility = llmModelVisibility.filter { !deletedModelKeys.contains($0.key) }
        var availability = llmModelAvailability.filter { !deletedModelKeys.contains($0.key) }
        for entry in llmModels {
            if visibility[entry.model.key] == nil {
                visibility[entry.model.key] = true
            }
            if availability[entry.model.key] == nil {
                availability[entry.model.key] = true
            }
        }
        llmModelVisibility = visibility
        llmModelAvailability = availability

        llmModels = Self.dedupModels(llmModels)
        saveModelsToDefaults(llmModels)
    }

    private static func dedupModels(_ models: [LLMModelEntry]) -> [LLMModelEntry] {
        var seen: Set<String> = []
        var result: [LLMModelEntry] = []
        for entry in models {
            if seen.insert(entry.model.key).inserted {
                result.append(entry)
            }
        }
        return result
    }

    private func applyFetchedModels(_ fetched: [LLMModelEntry], for provider: LLMProvider) {
        let merged = Self.mergeFetchedModels(
            existing: llmModels,
            fetched: fetched,
            visibility: llmModelVisibility,
            availability: llmModelAvailability,
            provider: provider,
            deletedKeys: deletedModelKeys
        )
        llmModels = merged.models
        llmModelVisibility = merged.visibility
        llmModelAvailability = merged.availability

        saveModelsToDefaults(llmModels)
    }

    static func mergeFetchedModels(
        existing: [LLMModelEntry],
        fetched: [LLMModelEntry],
        visibility: [String: Bool],
        availability: [String: Bool],
        provider: LLMProvider,
        deletedKeys: Set<String>
    ) -> LLMModelCatalogMergeResult {
        let existingModels = existing.filter { !deletedKeys.contains($0.model.key) }
        let fetchedModels = fetched.filter {
            $0.model.provider == provider && !deletedKeys.contains($0.model.key)
        }

        let existingKeys = Set(existingModels.map(\.model.key))
        let mergedModels = Self.dedupModels(existingModels + fetchedModels)

        var mergedVisibility = visibility.filter { !deletedKeys.contains($0.key) }
        for entry in mergedModels where mergedVisibility[entry.model.key] == nil {
            mergedVisibility[entry.model.key] = true
        }
        for entry in fetchedModels where !existingKeys.contains(entry.model.key) {
            mergedVisibility[entry.model.key] = true
        }

        let fetchedKeys = Set(fetchedModels.map(\.model.key))
        var mergedAvailability = availability.filter { !deletedKeys.contains($0.key) }
        for entry in mergedModels where mergedAvailability[entry.model.key] == nil {
            mergedAvailability[entry.model.key] = true
        }
        for entry in mergedModels where entry.model.provider == provider {
            mergedAvailability[entry.model.key] = fetchedKeys.contains(entry.model.key)
        }

        return LLMModelCatalogMergeResult(
            models: mergedModels,
            visibility: mergedVisibility,
            availability: mergedAvailability
        )
    }

    private func validateAPIKey(_ key: String, for provider: LLMProvider) async -> Result<Void, LLMKeyValidationError> {
        do {
            _ = try await fetchModels(provider: provider, apiKey: key)
            return .success(())
        } catch let error as LLMKeyValidationError {
            return .failure(error)
        } catch {
            return .failure(LLMKeyValidationError(provider: provider, statusCode: nil, message: error.localizedDescription))
        }
    }

    private func fetchModels(provider: LLMProvider, apiKey: String) async throws -> [LLMModelEntry] {
        switch provider {
        case .openAI:
            return try await fetchOpenAIModels(apiKey: apiKey)
        case .gemini:
            return try await fetchGeminiModels(apiKey: apiKey)
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private func fetchOpenAIModels(apiKey: String) async throws -> [LLMModelEntry] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw LLMKeyValidationError(provider: .openAI, statusCode: nil, message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard statusCode == 200 else {
            let message = parseOpenAIErrorMessage(from: data) ?? "HTTP error"
            throw LLMKeyValidationError(provider: .openAI, statusCode: statusCode, message: message)
        }

        return try Self.parseOpenAIModelEntries(data)
    }

    static func parseOpenAIModelEntries(_ data: Data) throws -> [LLMModelEntry] {
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let entries = decoded.data
            .filter { Self.isSupportedOpenAITextModel($0.id) }
            .map { LLMModelEntry(model: LLMModel(provider: .openAI, name: $0.id), displayName: $0.id) }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        return entries
    }

    static func isSupportedOpenAITextModel(_ modelName: String) -> Bool {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseName = name.hasPrefix("ft:") ? String(name.dropFirst(3)) : name
        let hasTextFamilyPrefix = baseName.hasPrefix("gpt-")
            || baseName.hasPrefix("o1")
            || baseName.hasPrefix("o3")
            || baseName.hasPrefix("o4")
            || baseName.hasPrefix("chatgpt-")
        guard hasTextFamilyPrefix else { return false }

        let blockedFragments = [
            "audio", "realtime", "image", "embedding", "dall-e", "whisper",
            "moderation", "computer-use", "transcribe", "tts"
        ]
        return !blockedFragments.contains(where: { baseName.contains($0) })
    }

    private struct GeminiModelsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]?
    }

    private struct GeminiErrorResponse: Decodable {
        struct GeminiError: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }
        let error: GeminiError
    }

    private func fetchGeminiModels(apiKey: String) async throws -> [LLMModelEntry] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)") else {
            throw LLMKeyValidationError(provider: .gemini, statusCode: nil, message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard statusCode == 200 else {
            let message = parseGeminiErrorMessage(from: data) ?? "HTTP error"
            throw LLMKeyValidationError(provider: .gemini, statusCode: statusCode, message: message)
        }

        let decoded = try jsonDecoder.decode(GeminiModelsResponse.self, from: data)
        let rawModels: [GeminiModelsResponse.Model] = decoded.models ?? []
        let mapped: [LLMModelEntry] = rawModels
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { model in
                let id = model.name.replacingOccurrences(of: "models/", with: "")
                return LLMModelEntry(model: LLMModel(provider: .gemini, name: id), displayName: model.displayName ?? id)
            }
        let entries = mapped.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return entries
    }

    private func parseOpenAIErrorMessage(from data: Data) -> String? {
        if let apiError = try? jsonDecoder.decode(APIErrorResponse.self, from: data) {
            return apiError.error.message
        }
        return nil
    }

    private func parseGeminiErrorMessage(from data: Data) -> String? {
        if let apiError = try? jsonDecoder.decode(GeminiErrorResponse.self, from: data) {
            let status = apiError.error.status ?? "Error"
            let message = apiError.error.message ?? "Unknown error"
            return "\(status): \(message)"
        }
        return nil
    }

    private func loadOrMigrateStarredPrimarySelectionKey(legacyPrimaryId: UUID?) -> String {
        if let v2 = defaults.string(forKey: starredPrimarySelectionDefaultsKeyV2) {
            return v2
        }

        let migrated: String
        if let legacyPrimaryId {
            if isLegacyDefaultTranslationActionId(legacyPrimaryId) {
                migrated = TranslationService.builtInTranslateSelectionKey
            } else {
                migrated = legacyPrimaryId.uuidString
            }
        } else {
            migrated = TranslationService.builtInTranslateSelectionKey
        }

        saveStarredPrimarySelectionKeyToDefaults(migrated)
        return migrated
    }

    private func saveStarredPrimarySelectionKeyToDefaults(_ key: String) {
        defaults.set(key, forKey: starredPrimarySelectionDefaultsKeyV2)
    }

    private func isLegacyDefaultTranslationActionId(_ id: UUID) -> Bool {
        guard let first = customActions.first, first.id == id else {
            return false
        }
        let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = first.prompt
        if (title == "Translate" || title == "Перевод") && prompt.contains("You are a professional translator") {
            return true
        }
        if prompt.contains("Translate from Auto-detect") && prompt.contains("{{targetLanguage}}") {
            return true
        }
        return false
    }

    private func clearLegacyDefaultTranslationActionIfPresent() {
        guard customActions.count >= 1 else {
            return
        }
        let title = customActions[0].title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = customActions[0].prompt

        let looksLikeLegacyDefaultTranslation =
            ((title == "Translate" || title == "Перевод") && prompt.contains("You are a professional translator"))
            || (prompt.contains("Translate from Auto-detect") && prompt.contains("{{targetLanguage}}"))

        guard looksLikeLegacyDefaultTranslation else {
            return
        }

        customActions[0].title = ""
        customActions[0].prompt = ""

        if customActions.count >= 2 {
            let secondTitle = customActions[1].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let secondPrompt = customActions[1].prompt
            let looksLikeLegacyDefaultGrammar =
                ((secondTitle == "Grammar" || secondTitle == "Грамматика") && secondPrompt.contains("You are an expert editor"))
                || (secondPrompt.contains("Fix punctuation, grammar") && secondPrompt.contains("Output only the corrected version"))

            if looksLikeLegacyDefaultGrammar {
                customActions[0] = customActions[1]
                customActions[1] = CustomAction()
            }
        }

        let hasAnyConfigured = customActions.contains { action in
            !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !hasAnyConfigured {
            applyBuiltInDefaultsIfNeeded(force: true)
        }
    }

    var isStarredPrimaryBuiltInTranslate: Bool {
        starredPrimarySelectionKey == TranslationService.builtInTranslateSelectionKey
    }

    func starredPrimaryCustomAction() -> CustomAction? {
        guard !isStarredPrimaryBuiltInTranslate,
              let id = UUID(uuidString: starredPrimarySelectionKey) else {
            return nil
        }
        return customActions.first(where: { $0.id == id })
    }

    private func loadCustomActionsFromDefaults() -> [CustomAction]? {
        guard let data = defaults.data(forKey: customActionsDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([CustomAction].self, from: data)
    }

    private func saveCustomActionsToDefaults(_ actions: [CustomAction]) {
        guard let data = try? JSONEncoder().encode(actions) else {
            return
        }
        defaults.set(data, forKey: customActionsDefaultsKey)
    }

    private func loadStarredActionIdFromDefaults(key: String) -> UUID? {
        guard let raw = defaults.string(forKey: key) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func saveStarredActionIdToDefaults(_ id: UUID?, key: String) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func translationDirectionInstruction(for mode: TranslationLanguageMode) -> String {
        switch mode {
        case .fixed(let targetLanguage):
            return "Translate from the detected source language to \(targetLanguage) naturally and clearly."
        case .automatic(let main, let additional):
            return """
            Choose the translation direction from these two configured languages:
            - Main language: \(main)
            - Additional language: \(additional)
            Determine the dominant language from the human-readable prose in the complete input. If the prose is predominantly \(main), translate to \(additional). If it is predominantly \(additional), translate to \(main). If it is another language or the result is uncertain, translate to \(main). URLs, domains, paths, code, identifiers, product names, and markup are content to preserve; they must not decide the language by themselves. If the input contains no human-readable prose, return it unchanged.
            """
        }
    }

    private func translateSystemPrompt(
        languageMode: TranslationLanguageMode,
        actionKey: String?
    ) -> String {
        var prompt = """
You are a professional translator. Your priority is to preserve meaning and intent.
\(Self.translationDirectionInstruction(for: languageMode))

Rules:
- Preserve meaning over literal wording.
- Keep tone (formal/informal), politeness, and emotional nuance.
- Preserve formatting exactly: keep all line breaks, paragraph boundaries, list structure, and leading indentation. Do not reflow or merge lines.
- Outside code blocks and inline code, use the standard Markdown marker "- " for unordered lists; never use a private-use font glyph or unknown placeholder as a list marker.
- Preserve code blocks and code spans exactly, including private-use characters that are part of code.
- Preserve every Markdown link destination exactly. You may translate or correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Do not add explanations, notes, or commentary.
- Do not censor or soften content.
- If a term is ambiguous, choose the most likely meaning from context. If truly unclear, keep the original term in parentheses after the translation.
- Keep names, product names, and IDs unchanged unless there is a widely accepted translation.
Output only the translation.
"""
        let style = translationStyleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            prompt += "\n\nTranslation style context:\n\(style)"
        }
        if let actionStyle = actionStyleContextIfEnabled(forActionKey: actionKey) {
            prompt += "\n\nAdditional style context:\n\(actionStyle)"
        }
        return prompt
    }

    private func translateSystemPrompt(targetLanguage: String, actionKey: String?) -> String {
        translateSystemPrompt(languageMode: .fixed(targetLanguage), actionKey: actionKey)
    }

    private func translateHTMLSystemPrompt(languageMode: TranslationLanguageMode, actionKey: String?) -> String {
        var prompt = """
You are a professional translator.

Input is HTML.
\(Self.translationDirectionInstruction(for: languageMode))

Rules:
- For automatic direction, inspect text nodes for the dominant language; do not infer it from tags, attributes, URLs, or other markup.
- Preserve the HTML structure exactly: keep tags, attributes, links, code tags, lists, and nesting.
- Keep every link destination exactly as provided. You may translate or correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Translate only the human-readable text content (text nodes).
- Preserve emphasis/formatting exactly as represented in HTML (e.g. keep <b>/<strong> tags and any inline font-weight styles; do not drop them).
- Preserve whitespace and line breaks as represented in the HTML.
- Do not add explanations, notes, or commentary.
- Output must be valid HTML and must start with '<' (no Markdown, no code fences, no plain text).
- If you cannot comply with the rules, output the original input HTML unchanged.
"""
        let style = translationStyleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            prompt += "\n\nTranslation style context:\n\(style)"
        }
        if let actionStyle = actionStyleContextIfEnabled(forActionKey: actionKey) {
            prompt += "\n\nAdditional style context:\n\(actionStyle)"
        }
        return prompt
    }

    private func translateHTMLSystemPrompt(targetLanguage: String, actionKey: String?) -> String {
        translateHTMLSystemPrompt(languageMode: .fixed(targetLanguage), actionKey: actionKey)
    }

    private func translateHTMLToMarkdownSystemPrompt(languageMode: TranslationLanguageMode, actionKey: String?) -> String {
        var prompt = """
You are a professional translator.

Input is HTML.
\(Self.translationDirectionInstruction(for: languageMode))

Rules:
- For automatic direction, inspect text nodes for the dominant language; do not infer it from tags, attributes, URLs, or other markup.
- Use the HTML input only as formatting guidance.
- Preserve lists, numbering, headings, and emphasis from the input (bold/italic/links) using Markdown.
- Preserve every link destination exactly. You may translate or correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Outside code blocks and inline code, use the standard Markdown marker "- " for unordered lists; never use a private-use font glyph or unknown placeholder as a list marker.
- Preserve code blocks and code spans exactly, including private-use characters that are part of code.
- Preserve link destinations exactly when converting links to Markdown. You may translate or correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Do not invent emphasis that wasn't present unless required for clarity.
- Preserve line breaks and paragraph structure.
- Output only Markdown (no HTML, no code fences).
"""
        let style = translationStyleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            prompt += "\n\nTranslation style context:\n\(style)"
        }
        if let actionStyle = actionStyleContextIfEnabled(forActionKey: actionKey) {
            prompt += "\n\nAdditional style context:\n\(actionStyle)"
        }
        return prompt
    }

    private func translateHTMLToMarkdownSystemPrompt(targetLanguage: String, actionKey: String?) -> String {
        translateHTMLToMarkdownSystemPrompt(languageMode: .fixed(targetLanguage), actionKey: actionKey)
    }

    private func grammarSystemPrompt() -> String {
        """
You are an expert editor.
Fix punctuation, grammar, and awkward or unclear constructions while preserving the original meaning and writing style.

Rules:
- Keep the original language.
- Preserve tone (formal/informal), voice, and intent.
- Preserve formatting exactly: keep all line breaks, paragraph boundaries, list structure, and leading indentation. Do not reflow or merge lines.
- Outside code blocks and inline code, use the standard Markdown marker "- " for unordered lists; never use a private-use font glyph or unknown placeholder as a list marker.
- Preserve code blocks and code spans exactly, including private-use characters that are part of code.
- Preserve every Markdown link destination exactly. You may correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Do not add explanations, notes, or commentary.
- Output only the corrected version of the text.
"""
    }

    private func grammarHTMLSystemPrompt() -> String {
        """
You are an expert editor.

Input is HTML.
Fix punctuation, grammar, and awkward or unclear constructions while preserving the original meaning and writing style.

Rules:
- Keep the original language.
- Preserve the HTML structure exactly: keep tags, attributes, links, code tags, lists, and nesting.
- Keep every link destination exactly as provided. You may correct the visible link label, but never change its hidden address. Remove a link only when its linked content is removed or the user explicitly asks for it.
- Edit only the human-readable text content (text nodes).
- Preserve emphasis/formatting exactly as represented in HTML (e.g. keep <b>/<strong> tags and any inline font-weight styles; do not drop them).
- Preserve whitespace and line breaks as represented in the HTML.
- Treat a private-use glyph that appears only as a list marker as list structure, not as visible text.
- Do not add explanations, notes, or commentary.
- Output must be valid HTML and must start with '<' (no Markdown, no code fences, no plain text).
- If you cannot comply with the rules, output the original input HTML unchanged.
"""
    }

    private func buildHTMLTranslateRequestBody(html: String, languageMode: TranslationLanguageMode, modelName: String, actionKey: String?) -> [String: Any] {
        let systemPrompt = translateHTMLSystemPrompt(languageMode: languageMode, actionKey: actionKey)

        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": html
                ]
            ],
            "max_completion_tokens": 1500
        ]

        if modelName == OpenAIModel.gpt52.rawValue {
            requestBody["temperature"] = 0.2
        }

        return requestBody
    }

    private func buildHTMLTranslateRequestBody(html: String, targetLanguage: String, modelName: String, actionKey: String?) -> [String: Any] {
        buildHTMLTranslateRequestBody(
            html: html,
            languageMode: .fixed(targetLanguage),
            modelName: modelName,
            actionKey: actionKey
        )
    }

    private func buildHTMLToMarkdownTranslateRequestBody(html: String, languageMode: TranslationLanguageMode, modelName: String, actionKey: String?) -> [String: Any] {
        let systemPrompt = translateHTMLToMarkdownSystemPrompt(languageMode: languageMode, actionKey: actionKey)

        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": html
                ]
            ],
            "max_completion_tokens": 1500
        ]

        if modelName == OpenAIModel.gpt52.rawValue {
            requestBody["temperature"] = 0.2
        }

        return requestBody
    }

    private func buildHTMLToMarkdownTranslateRequestBody(html: String, targetLanguage: String, modelName: String, actionKey: String?) -> [String: Any] {
        buildHTMLToMarkdownTranslateRequestBody(
            html: html,
            languageMode: .fixed(targetLanguage),
            modelName: modelName,
            actionKey: actionKey
        )
    }

    private func buildCustomActionRequestBody(text: String, prompt: String, modelName: String) -> [String: Any] {
        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": prompt
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ],
            "max_completion_tokens": 1500
        ]

        if modelName == OpenAIModel.gpt52.rawValue {
            requestBody["temperature"] = 0.2
        }

        return requestBody
    }

    private func actionStyleContextIfEnabled(forActionKey actionKey: String?) -> String? {
        guard let actionKey, actionStyleContextActionKeys.contains(actionKey) else {
            return nil
        }
        let trimmed = actionStyleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func appendActionStyleContext(to prompt: String, actionKey: String?) -> String {
        guard let actionStyle = actionStyleContextIfEnabled(forActionKey: actionKey) else {
            return prompt
        }
        return "\(prompt)\n\nAdditional style context:\n\(actionStyle)"
    }

    private func buildHTMLGrammarFixRequestBody(html: String, modelName: String) -> [String: Any] {
        let systemPrompt = grammarHTMLSystemPrompt()

        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": html
                ]
            ],
            "max_completion_tokens": 1500
        ]

        if modelName == OpenAIModel.gpt52.rawValue {
            requestBody["temperature"] = 0.2
        }

        return requestBody
    }

    private func buildRequestBody(
        text: String,
        languageMode: TranslationLanguageMode,
        modelName: String,
        actionKey: String?
    ) -> [String: Any] {
        let systemPrompt = translateSystemPrompt(
            languageMode: languageMode,
            actionKey: actionKey
        )

        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ],
            "max_completion_tokens": 1000
        ]

        if modelName == OpenAIModel.gpt52.rawValue {
            requestBody["temperature"] = 0.3
        }

        return requestBody
    }

    private func buildRequestBody(text: String, targetLanguage: String, modelName: String, actionKey: String?) -> [String: Any] {
        buildRequestBody(
            text: text,
            languageMode: .fixed(targetLanguage),
            modelName: modelName,
            actionKey: actionKey
        )
    }

    private func buildGrammarFixRequestBody(text: String, modelName: String) -> [String: Any] {
        let systemPrompt = grammarSystemPrompt()

        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ],
            "max_completion_tokens": 1000
        ]

        if modelName == OpenAIModel.gpt52.rawValue {
            requestBody["temperature"] = 0.2
        }

        return requestBody
    }

	    private struct ChatCompletionResponse: Decodable {
	        struct Choice: Decodable {
	            struct Message: Decodable {
	                let content: String
	            }
	            let message: Message
	        }
	        let choices: [Choice]
	    }

	    private struct OpenAIResponsesResponse: Decodable {
	        struct OutputItem: Decodable {
	            struct ContentItem: Decodable {
	                let type: String?
	                let text: String?
	            }
	            let type: String?
	            let content: [ContentItem]?
	        }
	        let output_text: String?
	        let output: [OutputItem]?
	    }

	    private struct APIErrorResponse: Decodable {
	        struct APIError: Decodable {
	            let message: String
	        }
	        let error: APIError
	    }

	    private func shouldUseOpenAIResponsesAPI(modelName: String) -> Bool {
	        modelName.hasPrefix("gpt-5")
	    }

	    private func buildOpenAIResponsesBody(fromChatBody chatBody: [String: Any]) -> [String: Any]? {
	        guard let model = chatBody["model"] as? String else { return nil }
	        guard let messages = chatBody["messages"] as? [[String: Any]] else { return nil }

	        let input: [[String: Any]] = messages.compactMap { message in
	            guard let role = message["role"] as? String else { return nil }
	            guard let content = message["content"] as? String else { return nil }
	            return [
	                "role": role,
	                "content": [
	                    [
	                        "type": "input_text",
	                        "text": content
	                    ]
	                ]
	            ]
	        }

	        guard !input.isEmpty else { return nil }

	        var body: [String: Any] = [
	            "model": model,
	            "input": input
	        ]

	        if let maxCompletion = chatBody["max_completion_tokens"] as? Int {
	            body["max_output_tokens"] = maxCompletion
	        }

	        if let temperature = chatBody["temperature"] {
	            body["temperature"] = temperature
	        }

	        return body
	    }

	    private func extractText(from response: OpenAIResponsesResponse) -> String? {
	        if let outputText = response.output_text?.normalizedPlainText(),
	           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
	            return outputText
	        }

	        let text = (response.output ?? [])
	            .flatMap { $0.content ?? [] }
	            .compactMap { $0.text }
	            .joined(separator: "\n")
	            .normalizedPlainText()

	        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
	    }

	    @discardableResult
	    private func performOpenAIChatCompletion(apiKey: String, requestBody: [String: Any], completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
	        guard !apiKey.isEmpty else {
	            completion(.failure(TranslationError.apiKeyMissing))
	            return nil
	        }

	        if let modelName = requestBody["model"] as? String,
	           shouldUseOpenAIResponsesAPI(modelName: modelName),
	           let responsesBody = buildOpenAIResponsesBody(fromChatBody: requestBody) {
	            return performOpenAIResponses(apiKey: apiKey, requestBody: responsesBody, completion: completion)
	        }

	        guard let url = URL(string: openAIChatCompletionsURLString) else {
	            completion(.failure(TranslationError.invalidURL))
	            return nil
	        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            completion(.failure(error))
            return nil
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode

            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    completion(.failure(error))
                    return
                }

                guard let data else {
                    completion(.failure(TranslationError.noData))
                    return
                }

                if let statusCode, statusCode != 200 {
                    if let apiError = try? self.jsonDecoder.decode(APIErrorResponse.self, from: data) {
                        completion(.failure(TranslationError.apiError(apiError.error.message)))
                    } else {
                        completion(.failure(TranslationError.httpError(statusCode)))
                    }
                    return
                }

                do {
                    let decoded = try self.jsonDecoder.decode(ChatCompletionResponse.self, from: data)
                    guard let content = decoded.choices.first?.message.content else {
                        completion(.failure(TranslationError.invalidResponse))
                        return
                    }
                    completion(.success(content.normalizedPlainText()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
	        task.resume()
	        return task
	    }

	    @discardableResult
	    private func performOpenAIResponses(apiKey: String, requestBody: [String: Any], completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
	        guard !apiKey.isEmpty else {
	            completion(.failure(TranslationError.apiKeyMissing))
	            return nil
	        }

	        guard let url = URL(string: openAIResponsesURLString) else {
	            completion(.failure(TranslationError.invalidURL))
	            return nil
	        }

	        var request = URLRequest(url: url)
	        request.httpMethod = "POST"
	        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
	        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

	        do {
	            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
	        } catch {
	            completion(.failure(error))
	            return nil
	        }

	        let task = session.dataTask(with: request) { [weak self] data, response, error in
	            let statusCode = (response as? HTTPURLResponse)?.statusCode

	            Task { @MainActor [weak self] in
	                guard let self else { return }

	                if let error {
	                    completion(.failure(error))
	                    return
	                }

	                guard let data else {
	                    completion(.failure(TranslationError.noData))
	                    return
	                }

	                if let statusCode, statusCode != 200 {
	                    let message = self.parseOpenAIErrorMessage(from: data)
	                    if let message {
	                        completion(.failure(TranslationError.apiError(message)))
	                    } else {
	                        completion(.failure(TranslationError.httpError(statusCode)))
	                    }
	                    return
	                }

	                do {
	                    let decoded = try self.jsonDecoder.decode(OpenAIResponsesResponse.self, from: data)
	                    guard let content = self.extractText(from: decoded) else {
	                        completion(.failure(TranslationError.invalidResponse))
	                        return
	                    }
	                    completion(.success(content.normalizedPlainText()))
	                } catch {
	                    completion(.failure(error))
	                }
	            }
	        }
	        task.resume()
	        return task
	    }

    private struct GeminiGenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    @discardableResult
    private func performGeminiGenerateContent(apiKey: String, modelName: String, systemPrompt: String, userText: String, maxOutputTokens: Int, temperature: Double?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard !apiKey.isEmpty else {
            completion(.failure(TranslationError.apiKeyMissing))
            return nil
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
            completion(.failure(TranslationError.invalidURL))
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = [
            "maxOutputTokens": maxOutputTokens
        ]
        if let temperature {
            generationConfig["temperature"] = temperature
        }

        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": userText]
                    ]
                ]
            ],
            "generationConfig": generationConfig
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            completion(.failure(error))
            return nil
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode

            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    completion(.failure(error))
                    return
                }

                guard let data else {
                    completion(.failure(TranslationError.noData))
                    return
                }

                if let statusCode, statusCode != 200 {
                    if let apiError = try? self.jsonDecoder.decode(GeminiErrorResponse.self, from: data) {
                        let status = apiError.error.status ?? "Error"
                        let message = apiError.error.message ?? "Unknown error"
                        completion(.failure(TranslationError.apiError("\(status): \(message)")))
                    } else {
                        completion(.failure(TranslationError.httpError(statusCode)))
                    }
                    return
                }

	                do {
	                    let decoded = try self.jsonDecoder.decode(GeminiGenerateContentResponse.self, from: data)
	                    let text = (decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined(separator: "\n") ?? "").normalizedPlainText()
	                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
	                        completion(.failure(TranslationError.invalidResponse))
	                        return
	                    }
	                    completion(.success(text))
	                } catch {
	                    completion(.failure(error))
	                }
            }
        }
        task.resume()
        return task
    }
    
    func translate(text: String, targetLanguage: String, completion: @escaping (Result<String, Error>) -> Void) {
        translate(text: text, targetLanguage: targetLanguage, modelOverride: nil, completion: completion)
    }

	    func translate(text: String, targetLanguage: String, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(TranslationError.emptyText))
            return
        }
        
        isTranslating = true
        errorMessage = nil

	        let modelToUse = modelOverride ?? builtInTranslateModel
	        let languageMode = translationLanguageMode(for: targetLanguage)
		        translateText(text: text, languageMode: languageMode, modelOverride: modelToUse) { [weak self] result in
		            self?.isTranslating = false
		            switch result {
	            case .success:
	                completion(result)
	            case .failure(let error):
	                if self?.isCancellationError(error) == true {
	                    completion(result)
	                    return
	                }
	                if let localizedError = error as? LocalizedError {
	                    self?.errorMessage = localizedError.errorDescription
	                } else {
	                    self?.errorMessage = error.localizedDescription
	                }
	                completion(result)
	            }
	        }
		    }

    @discardableResult
    func translateText(
        text: String,
        targetLanguage: String,
        modelOverride: LLMModel?,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        translateText(
            text: text,
            languageMode: translationLanguageMode(for: targetLanguage),
            modelOverride: modelOverride,
            completion: completion
        )
    }

    @discardableResult
    func translateText(
        text: String,
        languageMode: TranslationLanguageMode,
        modelOverride: LLMModel?,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
	        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
	            completion(.failure(TranslationError.emptyText))
	            return nil
	        }

	        let modelToUse = modelOverride ?? builtInTranslateModel
	        let actionKey = TranslationService.builtInTranslateSelectionKey
	        guard guardModelAvailable(modelToUse, completion: completion) else { return nil }
	        switch modelToUse.provider {
	        case .openAI:
	            let requestBody = buildRequestBody(
                text: text,
                languageMode: languageMode,
                modelName: modelToUse.name,
                actionKey: actionKey
            )
            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody, completion: completion)
	        case .gemini:
            return performGeminiGenerateContent(
	                apiKey: geminiAPIKey,
	                modelName: modelToUse.name,
	                systemPrompt: translateSystemPrompt(
                    languageMode: languageMode,
                    actionKey: actionKey
	                ),
	                userText: text,
                maxOutputTokens: 1000,
                temperature: 0.3,
                completion: completion
            )
        }
    }

    @discardableResult
    func translateHTML(html: String, targetLanguage: String, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        translateHTML(
            html: html,
            languageMode: translationLanguageMode(for: targetLanguage),
            modelOverride: modelOverride,
            completion: completion
        )
    }

    @discardableResult
    func translateHTML(html: String, languageMode: TranslationLanguageMode, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
	        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
	            completion(.failure(TranslationError.emptyText))
	            return nil
	        }

	        let modelToUse = modelOverride ?? builtInTranslateModel
	        let actionKey = TranslationService.builtInTranslateSelectionKey
	        guard guardModelAvailable(modelToUse, completion: completion) else { return nil }
	        switch modelToUse.provider {
	        case .openAI:
            let requestBody = buildHTMLTranslateRequestBody(html: html, languageMode: languageMode, modelName: modelToUse.name, actionKey: actionKey)
	            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody, completion: completion)
	        case .gemini:
            return performGeminiGenerateContent(
	                apiKey: geminiAPIKey,
	                modelName: modelToUse.name,
                    systemPrompt: translateHTMLSystemPrompt(languageMode: languageMode, actionKey: actionKey),
	                userText: html,
                maxOutputTokens: 1500,
                temperature: 0.2,
                completion: completion
            )
        }
    }

    @discardableResult
    func translateHTMLToMarkdown(html: String, targetLanguage: String, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        translateHTMLToMarkdown(
            html: html,
            languageMode: translationLanguageMode(for: targetLanguage),
            modelOverride: modelOverride,
            completion: completion
        )
    }

    @discardableResult
    func translateHTMLToMarkdown(html: String, languageMode: TranslationLanguageMode, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(TranslationError.emptyText))
            return nil
        }

        let modelToUse = modelOverride ?? builtInTranslateModel
        let actionKey = TranslationService.builtInTranslateSelectionKey
        guard guardModelAvailable(modelToUse, completion: completion) else { return nil }
        switch modelToUse.provider {
        case .openAI:
            let requestBody = buildHTMLToMarkdownTranslateRequestBody(html: html, languageMode: languageMode, modelName: modelToUse.name, actionKey: actionKey)
            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody, completion: completion)
        case .gemini:
            return performGeminiGenerateContent(
                apiKey: geminiAPIKey,
                modelName: modelToUse.name,
                systemPrompt: translateHTMLToMarkdownSystemPrompt(languageMode: languageMode, actionKey: actionKey),
                userText: html,
                maxOutputTokens: 1500,
                temperature: 0.2,
                completion: completion
            )
        }
    }

    @discardableResult
	    func grammarFix(text: String, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
	        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
	            completion(.failure(TranslationError.emptyText))
	            return nil
	        }

	        let modelToUse = modelOverride ?? builtInTranslateModel
	        guard guardModelAvailable(modelToUse, completion: completion) else { return nil }
	        switch modelToUse.provider {
	        case .openAI:
	            let requestBody = buildGrammarFixRequestBody(text: text, modelName: modelToUse.name)
	            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody, completion: completion)
	        case .gemini:
            return performGeminiGenerateContent(
                apiKey: geminiAPIKey,
                modelName: modelToUse.name,
                systemPrompt: grammarSystemPrompt(),
                userText: text,
                maxOutputTokens: 1000,
                temperature: 0.2,
                completion: completion
            )
        }
    }

    @discardableResult
    func runCustomAction(
        text: String,
        prompt: String,
        actionId: UUID?,
        modelOverride: LLMModel?,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
	        let normalizedText = text.normalizedPlainText()
	        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
	            completion(.failure(TranslationError.emptyText))
	            return nil
	        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            completion(.failure(TranslationError.customPromptMissing))
            return nil
        }
        let actionKey = actionId?.uuidString
        let formattingPrompt = """
        \(trimmedPrompt)

        Output requirements:
        - Follow the task prompt when it requests a new structure, such as a summary,
          reordered sections, or a different number of paragraphs.
        - If the task does not request a structural change, preserve line breaks,
          paragraph boundaries, and list structure.
        - Outside code blocks and inline code, use the standard Markdown marker "- " for unordered lists; never use a private-use font glyph or unknown placeholder as a list marker.
        - Preserve code blocks and code spans exactly, including private-use characters that are part of code.
        - Preserve every Markdown link destination exactly. You may edit the visible link label, but never change its hidden address. Change or remove a link only when the task explicitly asks for it or removes that content.
        """
        let styledPrompt = appendActionStyleContext(to: formattingPrompt, actionKey: actionKey)

	        isTranslating = true
	        errorMessage = nil

	        let modelToUse = modelOverride ?? builtInTranslateModel
	        guard guardModelAvailable(modelToUse, completion: completion) else {
	            isTranslating = false
	            return nil
	        }
	        switch modelToUse.provider {
	        case .openAI:
	            let requestBody = buildCustomActionRequestBody(text: normalizedText, prompt: styledPrompt, modelName: modelToUse.name)
	            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody) { [weak self] result in
                self?.isTranslating = false
                switch result {
                case .success:
                    completion(result)
                case .failure(let error):
                    if self?.isCancellationError(error) == true {
                        completion(result)
                        return
                    }
                    if let localizedError = error as? LocalizedError {
                        self?.errorMessage = localizedError.errorDescription
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    completion(result)
                }
	        }
	        case .gemini:
            return performGeminiGenerateContent(
                apiKey: geminiAPIKey,
                modelName: modelToUse.name,
                systemPrompt: styledPrompt,
                userText: normalizedText,
                maxOutputTokens: 1500,
                temperature: 0.2,
                completion: { [weak self] result in
                    self?.isTranslating = false
                    switch result {
                    case .success:
                        completion(result)
                    case .failure(let error):
                        if self?.isCancellationError(error) == true {
                            completion(result)
                            return
                        }
                        if let localizedError = error as? LocalizedError {
                            self?.errorMessage = localizedError.errorDescription
                        } else {
                            self?.errorMessage = error.localizedDescription
                        }
                        completion(result)
                    }
                }
            )
        }
		    }

    @discardableResult
    func runCustomActionHTML(
        html: String,
        prompt: String,
        actionId: UUID?,
        modelOverride: LLMModel?,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else {
            completion(.failure(TranslationError.emptyText))
            return nil
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            completion(.failure(TranslationError.customPromptMissing))
            return nil
        }
        let actionKey = actionId?.uuidString

        isTranslating = true
        errorMessage = nil

        let modelToUse = modelOverride ?? builtInTranslateModel
        guard guardModelAvailable(modelToUse, completion: completion) else {
            isTranslating = false
            return nil
        }

        let htmlPrompt = """
        System requirements (highest priority):
        - Input is HTML and output must be valid HTML that starts with '<'.
        - The task prompt is authoritative about the requested content and structure. It may
          intentionally add, remove, reorder, summarize, or otherwise restructure content.
        - For content that the task keeps, preserve semantic formatting and links unless the
          task explicitly asks to change them. Source-app fonts, sizes and colours are not
          meaningful and should not be copied.
        - Keep every link destination exactly as provided. You may edit the visible link label,
          but never change its hidden address. Change or remove a link only when the task explicitly asks for it or removes that content.
        - If the task does not ask for a structural change, keep the existing paragraphs,
          lists, links, code and emphasis.

        Task:
        \(trimmedPrompt)

        Rules:
        - Change the human-readable content and HTML structure as required by the task.
        - Keep the result parseable HTML. Do not put Markdown or a code fence around it.
        """
        let styledPrompt = appendActionStyleContext(to: htmlPrompt, actionKey: actionKey)

        switch modelToUse.provider {
        case .openAI:
            let requestBody = buildCustomActionRequestBody(text: trimmedHTML, prompt: styledPrompt, modelName: modelToUse.name)
            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody) { [weak self] result in
                self?.isTranslating = false
                switch result {
                case .success:
                    completion(result)
                case .failure(let error):
                    if self?.isCancellationError(error) == true {
                        completion(result)
                        return
                    }
                    if let localizedError = error as? LocalizedError {
                        self?.errorMessage = localizedError.errorDescription
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    completion(result)
                }
            }
        case .gemini:
            return performGeminiGenerateContent(
                apiKey: geminiAPIKey,
                modelName: modelToUse.name,
                systemPrompt: styledPrompt,
                userText: trimmedHTML,
                maxOutputTokens: 1500,
                temperature: 0.2,
                completion: { [weak self] result in
                    self?.isTranslating = false
                    switch result {
                    case .success:
                        completion(result)
                    case .failure(let error):
                        if self?.isCancellationError(error) == true {
                            completion(result)
                            return
                        }
                        if let localizedError = error as? LocalizedError {
                            self?.errorMessage = localizedError.errorDescription
                        } else {
                            self?.errorMessage = error.localizedDescription
                        }
                        completion(result)
                    }
                }
            )
        }
    }

    @discardableResult
    func runCustomActionMarkdownFromHTML(html: String, prompt: String, actionId: UUID?, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else {
            completion(.failure(TranslationError.emptyText))
            return nil
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            completion(.failure(TranslationError.customPromptMissing))
            return nil
        }
        let actionKey = actionId?.uuidString

        isTranslating = true
        errorMessage = nil

        let modelToUse = modelOverride ?? builtInTranslateModel
        guard guardModelAvailable(modelToUse, completion: completion) else {
            isTranslating = false
            return nil
        }

        let markdownPrompt = """
System requirements (highest priority):
- Input is HTML and output must be Markdown (no HTML, no code fences).
- Use the HTML only as formatting guidance.
- Preserve lists, numbering, headings, links, and emphasis from the input using Markdown.
- Preserve every link destination exactly; edit only the visible link label and never change its hidden address. Change or remove a link only when the task explicitly asks for it or removes that content.
- Outside code blocks and inline code, use the standard Markdown marker "- " for unordered lists; never use a private-use font glyph or unknown placeholder as a list marker.
- Preserve code blocks and code spans exactly, including private-use characters that are part of code.
- Keep the output readable and neatly formatted.

Task:
\(trimmedPrompt)
"""
        let styledPrompt = appendActionStyleContext(to: markdownPrompt, actionKey: actionKey)

        switch modelToUse.provider {
        case .openAI:
            let requestBody = buildCustomActionRequestBody(text: trimmedHTML, prompt: styledPrompt, modelName: modelToUse.name)
            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody) { [weak self] result in
                self?.isTranslating = false
                switch result {
                case .success:
                    completion(result)
                case .failure(let error):
                    if self?.isCancellationError(error) == true {
                        completion(result)
                        return
                    }
                    if let localizedError = error as? LocalizedError {
                        self?.errorMessage = localizedError.errorDescription
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    completion(result)
                }
            }
        case .gemini:
            return performGeminiGenerateContent(
                apiKey: geminiAPIKey,
                modelName: modelToUse.name,
                systemPrompt: styledPrompt,
                userText: trimmedHTML,
                maxOutputTokens: 1500,
                temperature: 0.2,
                completion: { [weak self] result in
                    self?.isTranslating = false
                    switch result {
                    case .success:
                        completion(result)
                    case .failure(let error):
                        if self?.isCancellationError(error) == true {
                            completion(result)
                            return
                        }
                        if let localizedError = error as? LocalizedError {
                            self?.errorMessage = localizedError.errorDescription
                        } else {
                            self?.errorMessage = error.localizedDescription
                        }
                        completion(result)
                    }
                }
            )
        }
    }

	    private func isCancellationError(_ error: Error) -> Bool {
	        let nsError = error as NSError
	        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
	    }

    @discardableResult
	    func grammarFixHTML(html: String, modelOverride: LLMModel?, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
	        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
	            completion(.failure(TranslationError.emptyText))
	            return nil
	        }

	        let modelToUse = modelOverride ?? builtInTranslateModel
	        guard guardModelAvailable(modelToUse, completion: completion) else { return nil }
	        switch modelToUse.provider {
	        case .openAI:
	            let requestBody = buildHTMLGrammarFixRequestBody(html: html, modelName: modelToUse.name)
	            return performOpenAIChatCompletion(apiKey: apiKey, requestBody: requestBody, completion: completion)
	        case .gemini:
            return performGeminiGenerateContent(
                apiKey: geminiAPIKey,
                modelName: modelToUse.name,
                systemPrompt: grammarHTMLSystemPrompt(),
                userText: html,
                maxOutputTokens: 1500,
                temperature: 0.2,
                completion: completion
            )
        }
    }
}

	enum TranslationError: LocalizedError {
	    case apiKeyMissing
	    case emptyText
	    case customPromptMissing
	    case modelUnavailable(String)
	    case invalidURL
	    case noData
	    case invalidResponse
	    case httpError(Int)
	    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "API key is not set"
        case .emptyText:
            return "Text to translate is empty"
	        case .customPromptMissing:
	            return "Custom prompt is not set"
	        case .modelUnavailable(let model):
	            return "Model is not available: \(model). Refresh models or choose another one in Settings."
	        case .invalidURL:
	            return "Invalid URL"
	        case .noData:
	            return "No data received from the server"
        case .invalidResponse:
            return "Invalid response format"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return message
        }
    }
}
