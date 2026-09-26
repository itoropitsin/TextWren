//
//  TinyAITests.swift
//  TinyAITests
//
//  Created by Ivan on 12/12/2025.
//

import Testing
import Foundation
import AppKit
import Security
@testable import TinyAI

@MainActor
private final class CountingKeychainClient: KeychainClient {
    var values: [String: String] = [:]
    var forcedResults: [String: KeychainReadResult] = [:]
    var saveSucceeds = true
    private(set) var readCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult {
        readCount += 1
        if let forced = forcedResults[account] {
            return forced
        }
        guard let value = values[account] else { return .missing }
        return .value(value)
    }

    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool {
        saveCount += 1
        guard saveSucceeds else { return false }
        values[account] = value
        return true
    }

    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        deleteCount += 1
        values.removeValue(forKey: account)
        return true
    }
}

@MainActor
struct TinyAITests {

    @Test func testEnvironment_disablesGlobalSideEffects() {
        #expect(TinyAIRuntime.isTestEnvironment(arguments: ["TinyAI", "--ui-testing"], environment: [:]))
        #expect(TinyAIRuntime.isTestEnvironment(arguments: ["TinyAI"], environment: ["TINYAI_TEST_MODE": "1"]))
        #expect(TinyAIRuntime.isTestEnvironment(arguments: ["TinyAI"], environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        #expect(!TinyAIRuntime.isTestEnvironment(arguments: ["TinyAI"], environment: [:]))
        #expect(!KeyboardMonitor.shouldEnableGlobalMonitoring(arguments: ["TinyAI", "--ui-testing"], environment: [:]))
        #expect(KeyboardMonitor.shouldEnableGlobalMonitoring(arguments: ["TinyAI"], environment: [:]))
        #expect(KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: false, setupAlreadyAttempted: true) == false)
        #expect(KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: true, setupAlreadyAttempted: false) == false)
        #expect(KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: true, setupAlreadyAttempted: true) == true)
        #expect(TinyAIPermissions.requestablePermissions(
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            requested: [.accessibility]
        ) == [.inputMonitoring])
    }

    @Test @MainActor func keyboardMonitor_testModeDoesNotInstallGlobalHook() {
        let defaultMonitor = KeyboardMonitor()
        #expect(!defaultMonitor.isGlobalMonitoringEnabled)
        defaultMonitor.stopMonitoring()

        let monitor = KeyboardMonitor(globalMonitoringEnabled: false)
        #expect(!monitor.isGlobalMonitoringEnabled)
        monitor.stopMonitoring()
    }

    @Test @MainActor func keychainClient_readsEachAccountOnce_andInvalidatesAfterWrite() {
        let base = CountingKeychainClient()
        base.values["OpenAIAPIKey"] = "first"
        let client = CachingKeychainClient(base: base)

        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .value("first"))
        // The interaction flag must not create a second read for the same key.
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: true) == .value("first"))
        #expect(base.readCount == 1)

        #expect(client.saveString("second", service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: true))
        #expect(base.saveCount == 1)
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .value("second"))
        #expect(base.readCount == 2)

        #expect(client.delete(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: true))
        #expect(base.deleteCount == 1)
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .missing)
        #expect(base.readCount == 3)
    }

    @Test @MainActor func keychainClient_explicitRetryBypassesCachedInteractionFailure() {
        let base = CountingKeychainClient()
        base.forcedResults["OpenAIAPIKey"] = .interactionRequired
        let client = CachingKeychainClient(base: base)

        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .interactionRequired)
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .interactionRequired)
        #expect(base.readCount == 1)

        base.forcedResults["OpenAIAPIKey"] = .value("confirmed-key")
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: true) == .value("confirmed-key"))
        #expect(base.readCount == 2)
        // A successful explicit read is cached for all later non-interactive
        // callers, so reopening Settings cannot prompt again.
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .value("confirmed-key"))
        #expect(base.readCount == 2)
    }

    @Test func keychainUpdate_addsOnlyAfterConfirmedMissingItem() {
        #expect(SystemKeychainClient.shouldAddAfterUpdate(errSecItemNotFound))
        #expect(!SystemKeychainClient.shouldAddAfterUpdate(errSecSuccess))
        #expect(!SystemKeychainClient.shouldAddAfterUpdate(errSecAuthFailed))
    }

    @Test @MainActor func customAction_decodesLegacyFields_withoutStructureMetadata() throws {
        let data = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Grammar","prompt":"Fix grammar while preserving formatting","model":"gpt-5-mini","structurePolicy":"preserve"}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(CustomAction.self, from: data)

        #expect(action.title == "Grammar")
        #expect(action.prompt == "Fix grammar while preserving formatting")
        // A legacy bare OpenAI name is outside the supported catalog.
        #expect(action.model == ModelCatalog.defaultModel)

        let encoded = try JSONEncoder().encode(action)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!encodedString.contains("structurePolicy"))
    }

    @Test @MainActor func translationService_readsKeysOnce_andSkipsUnchangedWrites() {
        let suiteName = "IT.TinyAI.Tests.Keys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychain = CountingKeychainClient()
        keychain.values[LLMProvider.openAI.keychainAccount] = "openai-key"
        keychain.values[LLMProvider.gemini.keychainAccount] = "gemini-key"
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        #expect(service.apiKey == "openai-key")
        #expect(service.geminiAPIKey == "gemini-key")
        #expect(keychain.readCount == 2)

        service.saveAPIKey("openai-key", for: .openAI)
        service.saveAPIKey("gemini-key", for: .gemini)
        #expect(keychain.saveCount == 0)

        service.saveAPIKey("new-openai-key", for: .openAI)
        #expect(keychain.saveCount == 1)
        #expect(keychain.values[LLMProvider.openAI.keychainAccount] == "new-openai-key")
    }

    @Test @MainActor func translationService_migratesLegacyKey_onlyAfterConfirmedMissing() {
        let suiteName = "IT.TinyAI.Tests.Migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-openai-key", forKey: "OpenAIAPIKey")

        let keychain = CountingKeychainClient()
        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .missing
        keychain.forcedResults[LLMProvider.gemini.keychainAccount] = .missing
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        #expect(service.apiKey == "legacy-openai-key")
        #expect(keychain.saveCount == 1)
        #expect(defaults.string(forKey: "OpenAIAPIKey") == nil)
    }

    @Test @MainActor func translationService_doesNotMigrateWhenKeychainNeedsInteraction() {
        for readResult in [KeychainReadResult.interactionRequired, .failure(-1)] {
            let suiteName = "IT.TinyAI.Tests.Interaction.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set("legacy-openai-key", forKey: "OpenAIAPIKey")

            let keychain = CountingKeychainClient()
            keychain.forcedResults[LLMProvider.openAI.keychainAccount] = readResult
            keychain.forcedResults[LLMProvider.gemini.keychainAccount] = .missing
            let service = TranslationService(keychainClient: keychain, defaults: defaults)

            #expect(service.apiKey.isEmpty)
            #expect(keychain.saveCount == 0)
            #expect(defaults.string(forKey: "OpenAIAPIKey") == "legacy-openai-key")
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test @MainActor func translationService_retriesFailedMigrationOnExplicitUnchangedSave() {
        let suiteName = "IT.TinyAI.Tests.RetryMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-openai-key", forKey: "OpenAIAPIKey")

        let keychain = CountingKeychainClient()
        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .missing
        keychain.forcedResults[LLMProvider.gemini.keychainAccount] = .missing
        keychain.saveSucceeds = false
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        #expect(service.apiKey == "legacy-openai-key")
        #expect(keychain.saveCount == 1)
        #expect(defaults.string(forKey: "OpenAIAPIKey") == "legacy-openai-key")
        #expect(service.keychainStatus(for: .openAI) == .interactionRequired)

        keychain.saveSucceeds = true
        service.saveAPIKey("legacy-openai-key", for: .openAI)
        #expect(keychain.saveCount == 2)
        #expect(defaults.string(forKey: "OpenAIAPIKey") == nil)
        #expect(service.keychainStatus(for: .openAI) == .value("legacy-openai-key"))
    }

    @Test @MainActor func translationService_explicitKeychainRetryClearsConfirmedLegacyCopy() {
        let suiteName = "IT.TinyAI.Tests.ExplicitRetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-openai-key", forKey: "OpenAIAPIKey")

        let keychain = CountingKeychainClient()
        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .interactionRequired
        keychain.forcedResults[LLMProvider.gemini.keychainAccount] = .missing
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        #expect(service.apiKey.isEmpty)
        #expect(defaults.string(forKey: "OpenAIAPIKey") == "legacy-openai-key")

        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .value("confirmed-key")
        #expect(service.retryKeychainAccess(for: .openAI) == .value("confirmed-key"))
        #expect(service.apiKey == "confirmed-key")
        #expect(defaults.string(forKey: "OpenAIAPIKey") == nil)
    }

    @Test @MainActor func translationService_explicitMissingReadFinishesLegacyMigration() {
        let suiteName = "IT.TinyAI.Tests.ExplicitMissingMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-openai-key", forKey: "OpenAIAPIKey")

        let keychain = CountingKeychainClient()
        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .interactionRequired
        keychain.forcedResults[LLMProvider.gemini.keychainAccount] = .missing
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .missing
        #expect(service.retryKeychainAccess(for: .openAI) == .value("legacy-openai-key"))
        #expect(service.apiKey == "legacy-openai-key")
        #expect(defaults.string(forKey: "OpenAIAPIKey") == nil)
        #expect(keychain.saveCount == 1)
    }

    @Test @MainActor func translationService_explicitMissingMigrationFailureReportsInteractionRequired() {
        let suiteName = "IT.TinyAI.Tests.ExplicitMissingFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-openai-key", forKey: "OpenAIAPIKey")

        let keychain = CountingKeychainClient()
        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .interactionRequired
        keychain.forcedResults[LLMProvider.gemini.keychainAccount] = .missing
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        keychain.forcedResults[LLMProvider.openAI.keychainAccount] = .missing
        keychain.saveSucceeds = false
        #expect(service.retryKeychainAccess(for: .openAI) == .interactionRequired)
        #expect(service.keychainStatus(for: .openAI) == .interactionRequired)
        #expect(defaults.string(forKey: "OpenAIAPIKey") == "legacy-openai-key")
    }

    @Test @MainActor func ax_fullscreen_detection_does_not_crash() {
        let delegate = AppDelegate()
        let value = delegate.isFrontmostWindowFullscreen()
        #expect(value == true || value == false)
    }

    @Test func normalizedMarkdown_preservesIndentation_whenConvertingBullets() {
        let input = "  • First\n\t• Second\n    • Third"
        let output = RichTextConverter.normalizedMarkdown(input)
        #expect(output.contains("  - First"))
        #expect(output.contains("\t- Second"))
        #expect(output.contains("    - Third"))
    }

    @Test func normalizedMarkdown_convertsSlackPrivateUseBullets_butProtectsTextAndCode() {
        let marker = RichTextListMarkers.slackPrivateUseBullet
        let input = "\(marker) First\n  \(marker) Second\nkeep\(marker)inside\n```\n\(marker) code\n```"
        let output = RichTextConverter.normalizedMarkdown(input)

        #expect(output == "- First\n  - Second\nkeep\(marker)inside\n```\n\(marker) code\n```")
        #expect(RichTextConverter.normalizedMarkdown("\(marker)without-space") == "\(marker)without-space")
        #expect(RichTextConverter.normalizedMarkdown("\(marker)\nnext") == "\(marker)\nnext")
    }

    @Test func proseStartingWithLetters_isNotParsedAsAnOrderedList() {
        let source = "As we discussed on the call with security - let's update the columns naming in RBAC:\n- System Admins\n- Role Admin"
        let prepared = RichTextConverter.prepare(markdown: source)

        #expect(prepared.plain == "As we discussed on the call with security - let's update the columns naming in RBAC:\n• System Admins\n• Role Admin")
        #expect(RichTextConverter.structureSignature(of: prepared.attributed).blocks == [
            "paragraph",
            "list:unordered:1:item",
            "list:unordered:1:item"
        ])

        let firstParagraphRange = (prepared.attributed.string as NSString).paragraphRange(
            for: NSRange(location: 0, length: 0)
        )
        let firstParagraphStyle = prepared.attributed.attribute(
            .paragraphStyle,
            at: firstParagraphRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(firstParagraphStyle?.textLists.isEmpty != false)
    }

    @Test func htmlSanitizer_removesSlackMarkers_onlyInListPositions() {
        let marker = RichTextListMarkers.slackPrivateUseBullet
        let html = "<ul><li>\(marker) <strong>First</strong></li><li><span><b>\(marker)</b></span> Second</li></ul>"
            + "<p><span>\(marker)</span> Standalone</p><p>keep\(marker)inside</p>"
            + "<ul><li>&#58630; Third</li><li>&#xE506; Fourth</li></ul><pre>\(marker) code</pre>"

        let sanitized = RichTextHTMLSanitizer.sanitize(html)

        #expect(!sanitized.contains("&#58630;"))
        #expect(!sanitized.contains("&#xE506;"))
        #expect(sanitized.contains("<strong>First</strong>"))
        #expect(sanitized.contains("•"))
        #expect(!sanitized.contains("<span></span>"))
        #expect(!sanitized.contains("<b></b>"))
        #expect(sanitized.contains("<pre>\(marker) code</pre>"))
        #expect(sanitized.contains("<p>keep\(marker)inside</p>"))
        let withoutCode = sanitized.replacingOccurrences(of: "<pre>\(marker) code</pre>", with: "")
        let withoutOrdinaryText = withoutCode.replacingOccurrences(of: "<p>keep\(marker)inside</p>", with: "")
        #expect(!withoutOrdinaryText.contains(marker))
    }

    @Test func htmlSanitizer_stripsSourceTypographyAndColors() {
        let html = #"<p style="font-family: SlackFont; font-size: 48px; color: #ff00aa; background-color: yellow; border-color: black"><strong>Text</strong></p>"#
        let sanitized = RichTextHTMLSanitizer.sanitize(html)

        #expect(!sanitized.contains("font-family"))
        #expect(!sanitized.contains("font-size"))
        #expect(!sanitized.contains("color: #ff00aa"))
        #expect(!sanitized.contains("background-color"))
        #expect(sanitized.contains("border-color: black"))
        #expect(sanitized.contains("<strong>Text</strong>"))
    }

    @Test func plainHTML_preservesPrivateUseCharacters_insideCodeBlocks() {
        let marker = RichTextListMarkers.slackPrivateUseBullet
        let plain = RichTextConverter.plain(fromHTML: "<p>\(marker) item</p><pre>\(marker) code</pre>")

        #expect(plain.contains("- item"))
        #expect(plain.contains("\(marker) code"))
    }

    @Test func markdownPayload_usesVisibleBullets_andKeepsInlineFormatting() {
        let payload = RichTextConverter.payload(fromMarkdown: "Intro\n\n- **One**\n  - [Two](https://example.com)\n1. Three")

        #expect(payload.plain == "Intro\n\n• One\n  • Two\n1. Three")
        #expect(payload.html?.contains("One") == true)
        #expect(payload.html?.contains("https://example.com") == true)
    }

    @Test func attributedPayload_replacesPrivateUseBulletBeforeFontNormalization() {
        let marker = RichTextListMarkers.slackPrivateUseBullet
        let source = NSAttributedString(string: "\(marker) First\n")
        let rtf = RichTextConverter.rtf(from: source)
        let payload = RichTextPayload(plain: "\(marker) First", html: nil, rtf: rtf)
        let converted = RichTextConverter.attributedString(from: payload).string

        #expect(converted.contains("• First"))
        #expect(!converted.contains(marker))
    }

    @Test func accessibilityAttributedSelection_usesVisibleListFallback() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        let source = NSMutableAttributedString(string: "First\nSecond")
        source.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: source.length)
        )

        let prepared = RichTextConverter.prepare(attributed: source)
        #expect(prepared.plain == "• First\n• Second")
        #expect(prepared.payload.html?.contains("<ul>") == true)
        #expect(RichTextConverter.structureSignature(of: prepared.attributed).listGroups == [
            "unordered:1:group0",
            "unordered:1:group0"
        ])
    }

    @Test func preferredPopupPayload_prefersRichRepresentation_beforePlainFallback() {
        let pending = RichTextPayload(plain: "pending", html: nil, rtf: nil)
        let fresh = RichTextPayload(plain: "fresh", html: "<p>fresh</p>", rtf: nil)
        let accessibility = RichTextPayload(plain: "accessibility", html: nil, rtf: nil)

        #expect(KeyboardMonitor.preferredPopupPayload(
            pendingClipboard: pending,
            freshClipboard: fresh,
            accessibility: accessibility
        )?.plain == "fresh")
        #expect(KeyboardMonitor.preferredPopupPayload(
            pendingClipboard: nil,
            freshClipboard: fresh,
            accessibility: accessibility
        )?.plain == "fresh")
        #expect(KeyboardMonitor.preferredPopupPayload(
            pendingClipboard: pending,
            freshClipboard: nil,
            accessibility: RichTextPayload(plain: "rich accessibility", html: nil, rtf: Data([1]))
        )?.plain == "rich accessibility")
        #expect(KeyboardMonitor.preferredPopupPayload(
            pendingClipboard: RichTextPayload(plain: " ", html: nil, rtf: nil),
            freshClipboard: nil,
            accessibility: accessibility
        )?.plain == "accessibility")
    }

    @Test func translationLanguageMode_autoPromptDelegatesDirectionToModel() {
        let mode = TranslationLanguageMode.automatic(main: "Russian", additional: "English")
        let instruction = TranslationService.translationDirectionInstruction(for: mode)

        #expect(instruction.contains("Main language: Russian"))
        #expect(instruction.contains("Additional language: English"))
        #expect(instruction.contains("predominantly Russian"))
        #expect(instruction.contains("translate to English"))
        #expect(instruction.contains("predominantly English"))
        #expect(instruction.contains("translate to Russian"))
        #expect(instruction.contains("human-readable prose"))
        #expect(instruction.contains("URLs, domains, paths, code"))
        #expect(instruction.contains("return it unchanged"))
    }

    @Test func translationLanguageMode_fixedPromptKeepsExplicitTarget() {
        let instruction = TranslationService.translationDirectionInstruction(for: .fixed("German"))
        #expect(instruction == "Translate from the detected source language to German naturally and clearly.")
    }

    @Test func translationWithoutHumanProse_isKeptUnchanged() {
        let linkOnly = RichTextConverter.prepare(markdown: "https://example.com/reference/path")
        let codeOnly = RichTextConverter.prepare(markdown: "```\nlet value = 1\n```")
        let prose = RichTextConverter.prepare(markdown: "Please review this paragraph")

        #expect(!RichTextConverter.containsHumanReadableProse(in: linkOnly.attributed))
        #expect(!RichTextConverter.containsHumanReadableProse(in: codeOnly.attributed))
        #expect(RichTextConverter.containsHumanReadableProse(in: prose.attributed))
    }

    @Test func sharedRichPayload_preservesFormattingForDisplayAndPaste() {
        let payload = RichTextConverter.payload(fromMarkdown: "Intro\n\n- **One**\n  - [Two](https://example.com)\n1. Three")
        let displayed = RichTextConverter.attributedString(from: payload)
        let oneLocation = (displayed.string as NSString).range(of: "One").location
        let twoLocation = (displayed.string as NSString).range(of: "Two").location
        let oneStyle = displayed.attribute(.paragraphStyle, at: oneLocation, effectiveRange: nil) as? NSParagraphStyle
        let twoStyle = displayed.attribute(.paragraphStyle, at: twoLocation, effectiveRange: nil) as? NSParagraphStyle

        #expect(displayed.string.contains("One"))
        #expect(displayed.string.contains("Two"))
        #expect(oneStyle?.textLists.count == 1)
        #expect(twoStyle?.textLists.count == 2)
        #expect(payload.html?.contains("https://example.com") == true)
        #expect(payload.html?.contains("strong") == true)
        #expect(payload.rtf != nil)
    }

    @Test func hyperlinks_surviveHTMLCopyReadAndPreparedModelOutput() throws {
        let sourceHTML = """
        <html><body>
        <p>Я окей, если мы оставим <a href="https://example.com/model"><strong>всю работу модели</strong></a> без заскриптованных проверок.</p>
        <p>Нынешний функционал должен продолжить работать:</p>
        <ul>
          <li><a href="https://github.com/manychat-internal-it/docs/pull/25">docs #25</a> — rename-stale Barcelona link</li>
          <li><a href="https://github.com/manychat-internal-it/scripts_manychat/pull/11"><em>scripts_manychat #11</em></a> — stale replacement path</li>
        </ul>
        <p><code>keep-this-code()</code></p>
        </body></html>
        """
        let prepared = try #require(RichTextConverter.prepare(html: sourceHTML))

        func links(in attributed: NSAttributedString) -> [String] {
            var result: [String] = []
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
                if let url = value as? URL {
                    result.append(url.absoluteString)
                } else if let url = value as? NSURL, let absoluteString = url.absoluteString {
                    result.append(absoluteString)
                }
            }
            return result
        }

        let destinations = links(in: prepared.attributed)
        #expect(destinations == [
            "https://example.com/model",
            "https://github.com/manychat-internal-it/docs/pull/25",
            "https://github.com/manychat-internal-it/scripts_manychat/pull/11"
        ])
        #expect(RichTextConverter.modelHTML(from: prepared)?.contains("https://example.com/model") == true)
        #expect(RichTextConverter.modelHTML(from: prepared)?.contains("<ul>") == true)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.Links.\(UUID().uuidString)"))
        RichTextPasteboard.write(prepared.payload, to: pasteboard)
        let reread = try #require(RichTextPasteboard.read(from: pasteboard))
        let rereadPrepared = RichTextConverter.prepare(payload: reread)
        #expect(links(in: rereadPrepared.attributed) == destinations)
        #expect(rereadPrepared.plain.contains("docs #25"))
        #expect(rereadPrepared.plain.contains("scripts_manychat #11"))

        // A model may translate the visible labels while leaving href values
        // untouched.  The prepared response remains safe to Copy/Replace.
        let modelHTML = """
        <html><body><p><a href="https://example.com/model">всю работу модели</a></p>
        <p><a href="https://github.com/manychat-internal-it/docs/pull/25">документация №25</a></p>
        <p><a href="https://github.com/manychat-internal-it/scripts_manychat/pull/11">скрипты manychat №11</a></p></body></html>
        """
        let modelPrepared = try #require(RichTextConverter.prepare(html: modelHTML))
        #expect(links(in: modelPrepared.attributed) == destinations)
        #expect(modelPrepared.plain.contains("документация №25"))

        // The model response follows the same Copy -> pasteboard -> read path
        // as the visible Copy button. Labels may change, but destinations do
        // not.
        let modelPasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.ModelCopy.\(UUID().uuidString)"))
        RichTextPasteboard.write(modelPrepared.payload, to: modelPasteboard)
        let modelReread = try #require(RichTextPasteboard.read(from: modelPasteboard))
        let modelRereadPrepared = RichTextConverter.prepare(payload: modelReread)
        #expect(links(in: modelRereadPrepared.attributed) == destinations)
    }

    @Test func htmlPreparation_keepsExactRootLinkDestination() throws {
        let sourceHTML = "<html><body><p><a href=\"https://example.com\">Главная страница</a></p></body></html>"
        let prepared = try #require(RichTextConverter.prepare(html: sourceHTML))
        let html = try #require(prepared.payload.html)

        #expect(html.contains("href=\"https://example.com\""))
        #expect(!html.contains("href=\"https://example.com/\""))

        let roundTrip = RichTextConverter.prepare(payload: prepared.payload)
        let roundTripHTML = try #require(roundTrip.payload.html)
        #expect(roundTripHTML.contains("href=\"https://example.com\""))
        #expect(!roundTripHTML.contains("href=\"https://example.com/\""))
    }

    @Test func plainInput_doesNotCreateHiddenLinks() {
        let prepared = RichTextConverter.prepare(
            attributed: NSAttributedString(string: "Visible URL: https://github.com/example/project/pull/11")
        )
        let literalMarkdownPayload = RichTextConverter.prepare(
            payload: RichTextPayload(
                plain: "[visible label](https://example.com/hidden)",
                html: nil,
                rtf: nil
            )
        )

        #expect(RichTextConverter.modelHTML(from: prepared) == nil)
        #expect(RichTextConverter.structureSignature(of: prepared.attributed).links.isEmpty)
        #expect(prepared.plain.contains("https://github.com/example/project/pull/11"))
        #expect(RichTextConverter.structureSignature(of: literalMarkdownPayload.attributed).links.isEmpty)
        #expect(literalMarkdownPayload.plain == "[visible label](https://example.com/hidden)")
    }

    @Test func plainOnlyPasteboard_doesNotCreateHiddenLinks() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.PlainOnly.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString("[visible label](https://example.com/hidden)", forType: .string)
        pasteboard.writeObjects([item])

        let payload = try #require(RichTextPasteboard.read(from: pasteboard))
        let prepared = RichTextConverter.prepare(payload: payload)

        #expect(payload.html == nil)
        #expect(payload.rtf == nil)
        #expect(prepared.plain == "[visible label](https://example.com/hidden)")
        #expect(RichTextConverter.structureSignature(of: prepared.attributed).links.isEmpty)
    }

    @Test func emptyRichRepresentation_fallsBackToNonEmptyPlainText() throws {
        let emptyRTF = try #require(
            RichTextConverter.rtf(from: NSAttributedString(string: ""))
        )
        let prepared = RichTextConverter.prepare(payload: RichTextPayload(
            plain: "Literal source text",
            html: nil,
            rtf: emptyRTF
        ))

        #expect(prepared.plain == "Literal source text")
        #expect(RichTextConverter.structureSignature(of: prepared.attributed).links.isEmpty)
    }

    @Test func rtfOnlyInput_preservesLinkDestinationThroughCopyRead() throws {
        let destination = "https://github.com/manychat-internal-it/scripts_manychat/pull/11"
        let source = NSMutableAttributedString(string: "scripts manychat #11")
        source.addAttribute(.link, value: URL(string: destination)!, range: NSRange(location: 0, length: source.length))
        let rtf = try #require(RichTextConverter.rtf(from: source))
        let payload = RichTextPayload(plain: source.string, html: nil, rtf: rtf)
        let prepared = RichTextConverter.prepare(payload: payload)

        #expect(RichTextConverter.structureSignature(of: prepared.attributed).links == [destination])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.RTFLinks.\(UUID().uuidString)"))
        RichTextPasteboard.write(payload, to: pasteboard)
        let reread = try #require(RichTextPasteboard.read(from: pasteboard))
        let rereadPrepared = RichTextConverter.prepare(payload: reread)
        #expect(RichTextConverter.structureSignature(of: rereadPrepared.attributed).links == [destination])
    }

    @Test func consecutiveListItems_shareOneListInEveryRepresentation() throws {
        let prepared = RichTextConverter.prepare(markdown: "Sentence:\n- System Admins\n- Role Admin")
        let firstLocation = (prepared.attributed.string as NSString).range(of: "System Admins").location
        let secondLocation = (prepared.attributed.string as NSString).range(of: "Role Admin").location
        let firstStyle = prepared.attributed.attribute(.paragraphStyle, at: firstLocation, effectiveRange: nil) as? NSParagraphStyle
        let secondStyle = prepared.attributed.attribute(.paragraphStyle, at: secondLocation, effectiveRange: nil) as? NSParagraphStyle

        #expect(firstStyle?.textLists.count == 1)
        #expect(secondStyle?.textLists.count == 1)
        #expect(firstStyle?.textLists.first === secondStyle?.textLists.first)

        let signature = RichTextConverter.structureSignature(of: prepared.attributed)
        #expect(signature.blocks == ["paragraph", "list:unordered:1:item", "list:unordered:1:item"])
        #expect(signature.listGroups == ["none", "unordered:1:group0", "unordered:1:group0"])

        let rtfOnly = RichTextConverter.prepare(payload: RichTextPayload(
            plain: prepared.plain,
            html: nil,
            rtf: prepared.payload.rtf
        ))
        let rtfFirstLocation = (rtfOnly.attributed.string as NSString).range(of: "System Admins").location
        let rtfSecondLocation = (rtfOnly.attributed.string as NSString).range(of: "Role Admin").location
        let rtfFirstStyle = rtfOnly.attributed.attribute(.paragraphStyle, at: rtfFirstLocation, effectiveRange: nil) as? NSParagraphStyle
        let rtfSecondStyle = rtfOnly.attributed.attribute(.paragraphStyle, at: rtfSecondLocation, effectiveRange: nil) as? NSParagraphStyle
        #expect(rtfFirstStyle?.textLists.count == 1)
        #expect(rtfSecondStyle?.textLists.count == 1)
        #expect(rtfFirstStyle?.textLists.first === rtfSecondStyle?.textLists.first)

        let display = RichTextConverter.displayAttributedString(from: prepared)
        #expect(display.string.contains("• System Admins"))
        #expect(display.string.contains("• Role Admin"))

        let html = try #require(prepared.payload.html)
        #expect(html.components(separatedBy: "<ul>").count - 1 == 1)
        #expect(html.components(separatedBy: "<li>").count - 1 == 2)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.RoundTrip.\(UUID().uuidString)"))
        RichTextPasteboard.write(prepared.payload, to: pasteboard)
        let pasted = try #require(RichTextPasteboard.read(from: pasteboard))
        let pastedPrepared = RichTextConverter.prepare(payload: pasted)
        #expect(RichTextConverter.structureSignature(of: pastedPrepared.attributed) == signature)
    }

    @Test func separateListRuns_remainSeparateInStructureSignature() {
        let prepared = RichTextConverter.prepare(markdown: "- one\n\n- two")
        let signature = RichTextConverter.structureSignature(of: prepared.attributed)
        #expect(signature.listGroups.filter { !$0.hasPrefix("none") } == [
            "unordered:1:group0",
            "unordered:1:group1"
        ])
    }

    @Test func screenshotGrammarInput_roundTripsWithoutExtraBlankOrDroppedItem() {
        let source = "Hey!\n\nAs we discussed on the call with security - let's update the column names in RBAC:\n- System Admins\n- Role Admin"
        let prepared = RichTextConverter.prepare(markdown: source)
        let roundTrip = RichTextConverter.prepare(payload: prepared.payload)

        #expect(prepared.plain == "Hey!\n\nAs we discussed on the call with security - let's update the column names in RBAC:\n• System Admins\n• Role Admin")
        #expect(roundTrip.plain == prepared.plain)
        #expect(RichTextConverter.structureSignature(of: roundTrip.attributed) == RichTextConverter.structureSignature(of: prepared.attributed))

        let listItems = RichTextConverter.structureSignature(of: prepared.attributed).blocks.filter { $0.hasPrefix("list:") }
        #expect(listItems.count == 2)
    }

    @Test func htmlSelection_roundTripsScreenshotStructureWithoutExtraBlank() throws {
        let sourceHTML = """
        <html><body>
        <p>Hey!</p>
        <p>As we discussed on the call with Security, let's update the column names in <a href=\"https://example.com/rbac\"><strong>RBAC</strong></a>:</p>
        <ul><li>System Admins</li><li>Role Admin</li></ul>
        </body></html>
        """
        let prepared = try #require(RichTextConverter.prepare(html: sourceHTML))
        let roundTrip = RichTextConverter.prepare(payload: prepared.payload)

        #expect(prepared.plain == "Hey!\nAs we discussed on the call with Security, let's update the column names in RBAC:\n• System Admins\n• Role Admin")
        #expect(roundTrip.plain == prepared.plain)
        #expect(RichTextConverter.structureSignature(of: roundTrip.attributed) == RichTextConverter.structureSignature(of: prepared.attributed))
        #expect(prepared.payload.html?.contains("<ul>") == true)
        #expect(prepared.payload.html?.contains("<li>System Admins</li><li>Role Admin</li>") == true)
    }

    @Test func listStructureSignature_distinguishesNestedAndOrderedRuns() {
        let prepared = RichTextConverter.prepare(markdown: "- top\n  - nested one\n  - nested two\n- second\n\n1. first\n2. second")
        let signature = RichTextConverter.structureSignature(of: prepared.attributed)

        #expect(signature.blocks.filter { $0.hasPrefix("list:") }.count == 6)
        #expect(signature.listGroups.filter { !$0.hasPrefix("none") } == [
            "unordered:1:group0",
            "unordered:2:group1",
            "unordered:2:group1",
            "unordered:1:group0",
            "ordered:1:group2",
            "ordered:1:group2"
        ])
    }

    @Test func preparedMarkdown_materializesOnlyRequestedFontTraits() {
        let prepared = RichTextConverter.prepare(markdown: "Normal **bold** *italic* `code`")
        let text = prepared.attributed

        func font(at substring: String) -> NSFont? {
            let range = (text.string as NSString).range(of: substring)
            guard range.location != NSNotFound else { return nil }
            return text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }

        let normal = font(at: "Normal")
        let bold = font(at: "bold")
        let italic = font(at: "italic")
        let code = font(at: "code")
        #expect(normal?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(normal?.fontDescriptor.symbolicTraits.contains(.italic) == false)
        #expect(normal?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(italic?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(code?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(Set([normal?.pointSize, bold?.pointSize, italic?.pointSize, code?.pointSize].compactMap { $0 }).count == 1)
    }

    @Test func preparedPayload_roundTripDoesNotChangeSemanticFormatting() {
        let prepared = RichTextConverter.prepare(markdown: "Normal **bold** *italic* `code`\n\n- one\n  - two\n1. three")
        let roundTrip = RichTextConverter.prepare(payload: prepared.payload)
        let rtfOnly = RichTextConverter.prepare(payload: RichTextPayload(
            plain: prepared.plain,
            html: nil,
            rtf: prepared.payload.rtf
        ))

        #expect(roundTrip.plain == prepared.plain)
        #expect(RichTextConverter.structureSignature(of: roundTrip.attributed) == RichTextConverter.structureSignature(of: prepared.attributed))
        #expect(RichTextConverter.structureSignature(of: rtfOnly.attributed) == RichTextConverter.structureSignature(of: prepared.attributed))
        #expect(roundTrip.payload.html?.contains("<strong>bold</strong>") == true)
        #expect(roundTrip.payload.html?.contains("<em>italic</em>") == true)
        #expect(roundTrip.payload.html?.contains("<code>code</code>") == true)
        #expect(roundTrip.payload.html?.contains("<ul>") == true)
        #expect(roundTrip.payload.html?.contains("<ol>") == true)
        #expect(roundTrip.payload.html?.contains("font-family") == false)
        #expect(roundTrip.payload.html?.contains("font-size") == false)
        #expect(roundTrip.payload.html?.contains("color:") == false)
    }

    @Test func preparedPayload_roundTripPreservesTerminalLineBreaks() {
        for source in [
            "Paragraph\n",
            "Paragraph\n\n",
            "- item\n",
            "```\ncode\n```\n"
        ] {
            let prepared = RichTextConverter.prepare(markdown: source)
            let roundTrip = RichTextConverter.prepare(payload: prepared.payload)
            #expect(roundTrip.plain == prepared.plain)
        }
    }

    @Test func preparedMarkdown_createsTrueNestedListsAndVisiblePlainFallback() {
        let prepared = RichTextConverter.prepare(markdown: "- top\n  - nested\n1. numbered")
        let firstListStyle = prepared.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let nestedLocation = (prepared.attributed.string as NSString).range(of: "nested").location
        let nestedListStyle = prepared.attributed.attribute(.paragraphStyle, at: nestedLocation, effectiveRange: nil) as? NSParagraphStyle

        #expect(firstListStyle?.textLists.count == 1)
        #expect(nestedListStyle?.textLists.count == 2)
        #expect(prepared.plain == "• top\n  • nested\n1. numbered")
    }

    @Test func preparedMarkdown_resetsOrderedNumberingWhenListTypeChanges() {
        let prepared = RichTextConverter.prepare(markdown: "1. first\n- middle\n1. second")

        #expect(prepared.plain == "1. first\n• middle\n1. second")
        #expect(RichTextConverter.structureSignature(of: prepared.attributed).listGroups == [
            "ordered:1:group0",
            "unordered:1:group1",
            "ordered:1:group2"
        ])
    }

    @Test func displayLists_resetNumberingAfterAnOrdinaryParagraph() {
        let firstList = NSTextList(markerFormat: .decimal, options: 0)
        let secondList = NSTextList(markerFormat: .decimal, options: 0)
        let firstStyle = NSMutableParagraphStyle()
        firstStyle.textLists = [firstList]
        let secondStyle = NSMutableParagraphStyle()
        secondStyle.textLists = [secondList]

        let source = NSMutableAttributedString()
        source.append(NSAttributedString(string: "First\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]))
        source.append(NSAttributedString(string: "one\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: firstStyle
        ]))
        source.append(NSAttributedString(string: "Second\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]))
        source.append(NSAttributedString(string: "two", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: secondStyle
        ]))

        let displayed = RichTextConverter.displayAttributedString(from: source)
        #expect(displayed.string == "First\n1. one\nSecond\n1. two")
    }

    @Test func pasteboardPlainFallback_keepsVisibleListMarkers() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let payload = RichTextConverter.prepare(markdown: "- one\n1. two").payload
        RichTextPasteboard.write(payload, to: pasteboard)

        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType.string) == "• one\n1. two")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType.html) != nil)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType.rtf) != nil)
    }

    @Test func pasteboardRead_preservesRTFWhenHTMLCannotBeParsed() throws {
        let source = RichTextConverter.prepare(markdown: "Normal **bold**")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.InvalidHTML.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString("<unsupported-html", forType: .html)
        item.setData(try #require(source.payload.rtf), forType: .rtf)
        item.setString("plain fallback", forType: .string)
        pasteboard.writeObjects([item])

        let payload = try #require(RichTextPasteboard.read(from: pasteboard))
        let prepared = RichTextConverter.prepare(payload: payload)
        #expect(prepared.plain == source.plain)
        #expect(RichTextConverter.structureSignature(of: prepared.attributed) == RichTextConverter.structureSignature(of: source.attributed))
    }
    @Test func popupHotkeyValidation_allowsDefaultDoubleCopy_butProtectsEditingShortcuts() {
        let copy = KeyboardShortcut(keyCode: 8, modifiers: [.command])
        #expect(KeyboardMonitor.validationError(for: copy, pressMode: .doublePress) == nil)
        #expect(KeyboardMonitor.validationError(for: copy, pressMode: .singlePress) != nil)

        let paste = KeyboardShortcut(keyCode: 9, modifiers: [.command])
        #expect(KeyboardMonitor.validationError(for: paste, pressMode: .doublePress) != nil)
    }

    @Test func mainProcessingDelay_isShortForPastes_andLongerForTyping() {
        #expect(MainTranslationView.processingDelay(for: "", newValue: "Pasted text") == 0.05)
        #expect(MainTranslationView.processingDelay(for: "one", newValue: "one\ntwo") == 0.05)
        #expect(MainTranslationView.processingDelay(for: "a", newValue: "ab") == 0.30)
    }
}

@MainActor
struct ModelCatalogTests {
    @Test func defaultModel_isGPT6LunaWithHighReasoning() {
        #expect(ModelCatalog.defaultModel == LLMModel(provider: .openAI, name: "gpt-6-luna", reasoningEffort: .high))
        #expect(TranslationService.defaultModel == ModelCatalog.defaultModel)
    }

    @Test func catalog_containsOnlyGPT5Plus_andGemini3Plus() {
        for entry in ModelCatalog.all {
            switch entry.model.provider {
            case .openAI:
                #expect((LLMRequestPolicy.openAIGeneration(entry.model.name) ?? 0) >= 5)
            case .gemini:
                #expect((LLMRequestPolicy.geminiGeneration(entry.model.name) ?? 0) >= 3)
            }
            #expect(entry.reasoningEfforts.contains(entry.defaultReasoningEffort))
        }
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
    }

    @Test func resolve_mapsUnsupportedModelsToDefault_andClampsEffort() {
        #expect(ModelCatalog.resolve(LLMModel(provider: .openAI, name: "gpt-4o")) == ModelCatalog.defaultModel)
        #expect(ModelCatalog.resolve(LLMModel(provider: .gemini, name: "gemini-2.5-flash")) == ModelCatalog.defaultModel)

        // Astra has no `none`, so the model default is used instead.
        let astra = ModelCatalog.resolve(LLMModel(provider: .openAI, name: "gpt-6-astra", reasoningEffort: ReasoningEffort.none))
        #expect(astra.reasoningEffort == .medium)

        // A missing effort takes the model default; a valid one is kept.
        #expect(ModelCatalog.resolve(LLMModel(provider: .gemini, name: "gemini-3.5-flash-lite")).reasoningEffort == .minimal)
        #expect(ModelCatalog.resolve(LLMModel(provider: .openAI, name: "gpt-6-sol", reasoningEffort: .xhigh)).reasoningEffort == .xhigh)
    }

    @Test func llmModel_decodesStoredValuesWithoutEffort() throws {
        let data = #"{"provider":"openai","name":"gpt-6-sol"}"#.data(using: .utf8)!
        let model = try JSONDecoder().decode(LLMModel.self, from: data)
        #expect(model.reasoningEffort == nil)
        #expect(ModelCatalog.resolve(model).reasoningEffort == .medium)

        let unknownEffort = #"{"provider":"openai","name":"gpt-6-sol","reasoningEffort":"turbo"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(LLMModel.self, from: unknownEffort).reasoningEffort == nil)
    }

    @Test @MainActor func builtInTranslateModel_persistsReasoningEffort() {
        let suite = "TinyAITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = TranslationService(defaults: defaults)
        #expect(service.builtInTranslateModel == ModelCatalog.defaultModel)
        let selection = LLMModel(provider: .gemini, name: "gemini-3.8-flash", reasoningEffort: .low)
        service.saveBuiltInTranslateModel(selection)

        let reloaded = TranslationService(defaults: defaults)
        #expect(reloaded.builtInTranslateModel == selection)
    }

    @Test @MainActor func legacyTranslateModelKey_migratesToDefault() {
        let suite = "TinyAITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai:gpt-5-mini", forKey: "BuiltInTranslateModelV1")
        defaults.set(Data("[]".utf8), forKey: "LLMModelsV1")

        let service = TranslationService(defaults: defaults)
        #expect(service.builtInTranslateModel == ModelCatalog.defaultModel)
        #expect(defaults.object(forKey: "LLMModelsV1") == nil)
    }
}

@MainActor
struct LLMRequestPolicyTests {
    private func model(_ name: String, _ effort: ReasoningEffort?, _ provider: LLMProvider = .openAI) -> LLMModel {
        LLMModel(provider: provider, name: name, reasoningEffort: effort)
    }

    @Test func modelGeneration_isParsedFromFamilyPrefix() {
        #expect(LLMRequestPolicy.openAIGeneration("gpt-6-sol") == 6)
        #expect(LLMRequestPolicy.openAIGeneration("ft:gpt-6-luna:org::abc") == 6)
        #expect(LLMRequestPolicy.openAIGeneration("gpt-5.6-terra") == 5)
        #expect(LLMRequestPolicy.openAIGeneration("gpt-4o") == 4)
        #expect(LLMRequestPolicy.openAIGeneration("o3-mini") == nil)
        #expect(LLMRequestPolicy.geminiGeneration("gemini-3.1-pro-preview") == 3)
        #expect(LLMRequestPolicy.geminiGeneration("gemini-3.8-flash") == 3)
        #expect(LLMRequestPolicy.geminiGeneration("gemini-2.5-flash") == 2)
    }

    @Test func gpt6_sendsSelectedEffort_toResponsesAPI_withoutTemperature() throws {
        for (name, effort) in [("gpt-6-luna", ReasoningEffort.high), ("gpt-6-sol", .xhigh), ("gpt-6-astra", .low)] {
            #expect(LLMRequestPolicy.usesOpenAIResponsesAPI(name))
            let chat = LLMRequestPolicy.openAIChatBody(
                model: model(name, effort), systemPrompt: "sys", userText: "Hello", preferredTemperature: 0.2
            )
            #expect(chat["temperature"] == nil)

            let responses = try #require(LLMRequestPolicy.openAIResponsesBody(fromChatBody: chat))
            let reasoning = try #require(responses["reasoning"] as? [String: String])
            #expect(reasoning["effort"] == effort.rawValue)
            #expect(responses["temperature"] == nil)
        }
    }

    @Test func noneEffort_allowsTemperature() throws {
        let chat = LLMRequestPolicy.openAIChatBody(
            model: model("gpt-6-luna", ReasoningEffort.none), systemPrompt: "sys", userText: "Hello", preferredTemperature: 0.3
        )
        let responses = try #require(LLMRequestPolicy.openAIResponsesBody(fromChatBody: chat))
        #expect((responses["reasoning"] as? [String: String])?["effort"] == "none")
        #expect(responses["temperature"] as? Double == 0.3)
    }

    @Test func gemini3_sendsSelectedThinkingLevel_andDefaultTemperature() throws {
        let config = LLMRequestPolicy.geminiGenerationConfig(
            model: model("gemini-3.8-flash", .medium, .gemini), userText: "Hello", preferredTemperature: 0.2
        )
        let thinking = try #require(config["thinkingConfig"] as? [String: String])
        #expect(thinking["thinkingLevel"] == "medium")
        #expect(config["temperature"] == nil)

        let lite = LLMRequestPolicy.geminiGenerationConfig(
            model: model("gemini-3.5-flash-lite", .minimal, .gemini), userText: "Hello", preferredTemperature: 0.2
        )
        #expect((lite["thinkingConfig"] as? [String: String])?["thinkingLevel"] == "minimal")
    }

    @Test func outputBudget_growsWithInputAndEffort_withinBounds() {
        let short = LLMRequestPolicy.outputTokenBudget(userText: "Hi", reasoningEffort: ReasoningEffort.none)
        #expect(short == LLMRequestPolicy.minimumOutputTokens)

        let high = LLMRequestPolicy.outputTokenBudget(userText: "Hi", reasoningEffort: .high)
        #expect(high > LLMRequestPolicy.outputTokenBudget(userText: "Hi", reasoningEffort: .low))

        let longText = String(repeating: "Длинный текст для перевода. ", count: 1000)
        #expect(LLMRequestPolicy.outputTokenBudget(userText: longText, reasoningEffort: .low) > 1500 * 4)

        let huge = String(repeating: "x", count: 1_000_000)
        #expect(LLMRequestPolicy.outputTokenBudget(userText: huge, reasoningEffort: .max) == LLMRequestPolicy.maximumOutputTokens)
    }
}

@MainActor
struct RichTextSanitizerRegressionTests {
    @Test func styleStripping_neverTouchesVisibleText() {
        let html = #"<p style="color: red; font-weight: bold">Hair color: brown; eyes: blue</p><pre><code>body { font-family: Menlo; color: #333; }</code></pre>"#
        let sanitized = RichTextHTMLSanitizer.sanitize(html)
        #expect(sanitized.contains("Hair color: brown; eyes: blue"))
        #expect(sanitized.contains("body { font-family: Menlo; color: #333; }"))
        #expect(sanitized.contains(#"style="font-weight: bold""#))
        #expect(!sanitized.contains("color: red"))
    }

    @Test func styleStripping_removesTypographyAttributesInsideTags() {
        let html = #"<p><span style='font-family: Arial; font-size: 11pt'>x</span><font face="Arial" color="red">y</font><b color=red>z</b></p>"#
        let sanitized = RichTextHTMLSanitizer.sanitize(html)
        #expect(!sanitized.contains("font-family"))
        #expect(!sanitized.contains("style="))
        #expect(!sanitized.contains("face="))
        #expect(!sanitized.contains("color="))
        #expect(!sanitized.contains("<font"))
        #expect(sanitized.contains("x") && sanitized.contains("y") && sanitized.contains("<b>z</b>"))
    }

    @Test func whitespaceOnlySpans_keepTheSpaceBetweenWords() {
        let html = "<p><b>foo</b><span> </span><i>bar</i></p>"
        #expect(RichTextHTMLSanitizer.sanitize(html).contains("<span> </span>"))
    }

    @Test func sanitizer_handlesDeeplyNestedClosingTagsQuickly() {
        let nested = String(repeating: "</span>", count: 400)
        let html = "<ul><li>• " + nested + "x</li></ul>" + String(repeating: "<div><span><b>t</b></span></div>", count: 2000)
        let start = Date()
        _ = RichTextHTMLSanitizer.sanitize(html)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func linkDestinations_areMatchedByURL_notByPosition() {
        let source = #"<p><a href="https://example.com">a</a> <a href="https://b.example/x?q=1&amp;r=2">b</a> <a href='https://c.example/say"hi"'>c</a></p>"#
        // The generator splits a partly bold link into two anchors, which
        // shifted every later destination with positional matching.
        let generated = #"<p><a href="https://example.com/">a</a><a href="https://example.com/"><b>a</b></a> <a href="https://b.example/x?q=1&amp;r=2">b</a> <a href="https://c.example/say%22hi%22">c</a></p>"#
        let result = RichTextConverter.preservingOriginalLinkDestinations(in: generated, sourceHTML: source)
        #expect(result.components(separatedBy: #"href="https://example.com""#).count == 3)
        #expect(result.contains(#"href="https://b.example/x?q=1&amp;r=2""#))
        #expect(result.contains(#"href="https://c.example/say&quot;hi&quot;""#))
        #expect(!result.contains(#"href="https://c.example/say"hi""#))
    }

    @Test func linkDestinations_keepGeneratedURLWhenSourceHasNoMatch() {
        let source = #"<p><a href="https://one.example">1</a></p>"#
        let generated = #"<p><a href="https://two.example/">2</a></p>"#
        #expect(RichTextConverter.preservingOriginalLinkDestinations(in: generated, sourceHTML: source) == generated)
    }
}
