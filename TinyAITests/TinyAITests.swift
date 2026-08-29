//
//  TinyAITests.swift
//  TinyAITests
//
//  Created by Ivan on 12/12/2025.
//

import Testing
import Foundation
import AppKit
@testable import TinyAI

private final class CountingKeychainClient: KeychainClient {
    var forcedResults: [String: KeychainReadResult] = [:]
    var queuedResults: [String: [KeychainReadResult]] = [:]
    var readCalls = 0
    var saveCalls = 0
    var deleteCalls = 0
    var interactionFlags: [Bool] = []
    var saveSucceeds = true
    var deleteSucceeds = true

    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult {
        readCalls += 1
        interactionFlags.append(allowInteraction)
        if var queued = queuedResults[account], !queued.isEmpty {
            let result = queued.removeFirst()
            queuedResults[account] = queued
            return result
        }
        return forcedResults[account] ?? .missing
    }

    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool {
        saveCalls += 1
        interactionFlags.append(allowInteraction)
        return saveSucceeds
    }

    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        deleteCalls += 1
        interactionFlags.append(allowInteraction)
        return deleteSucceeds
    }
}

struct TinyAITests {

    @Test func permissionRequestPlan_doesNotRepeatWithinOneProcess() {
        let first = TinyAIPermissions.requestablePermissions(
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            requested: []
        )
        #expect(first == [.accessibility, .inputMonitoring])

        let afterRequest = TinyAIPermissions.requestablePermissions(
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            requested: Set(first)
        )
        #expect(afterRequest.isEmpty)

        #expect(TinyAIPermissions.requestablePermissions(
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            requested: []
        ).isEmpty)
    }

    @Test func keyboardMonitor_retriesOnlyAfterPermissionStateChanges() {
        #expect(!KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: false, setupAlreadyAttempted: true))
        #expect(!KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: false, setupAlreadyAttempted: false))
        #expect(KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: true, setupAlreadyAttempted: true))
        #expect(!KeyboardMonitor.shouldRetryEventTap(permissionStateChanged: true, setupAlreadyAttempted: false))
    }

    @Test func cachingKeychainClient_reusesNonInteractiveStartupRead() {
        let base = CountingKeychainClient()
        base.forcedResults["OpenAIAPIKey"] = .interactionRequired
        let client = CachingKeychainClient(base: base)

        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .interactionRequired)
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .interactionRequired)
        #expect(base.readCalls == 1)
        #expect(base.interactionFlags == [false])
    }

    @Test func cachingKeychainClient_explicitRetryRechecksCachedMiss() {
        let base = CountingKeychainClient()
        base.forcedResults["OpenAIAPIKey"] = .missing
        let client = CachingKeychainClient(base: base)

        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: false) == .missing)
        base.forcedResults["OpenAIAPIKey"] = .value("recovered-key")
        #expect(client.readString(service: "IT.TinyAI", account: "OpenAIAPIKey", allowInteraction: true) == .value("recovered-key"))
        #expect(base.readCalls == 2)
        #expect(base.interactionFlags == [false, true])
    }

    @Test @MainActor func translationService_startupDoesNotWriteKeychain() {
        let defaultsName = "IT.TinyAI.Tests.StartupRead.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let keychain = CountingKeychainClient()
        keychain.forcedResults["OpenAIAPIKey"] = .value("openai-key")
        keychain.forcedResults["GeminiAPIKey"] = .value("gemini-key")
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        #expect(service.apiKey == "openai-key")
        #expect(service.geminiAPIKey == "gemini-key")
        #expect(keychain.saveCalls == 0)
        #expect(keychain.deleteCalls == 0)
        #expect(keychain.interactionFlags == [false, false])
    }

    @Test @MainActor func translationService_explicitSaveIsTheInteractiveWrite() {
        let defaultsName = "IT.TinyAI.Tests.ExplicitSave.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let keychain = CountingKeychainClient()
        let service = TranslationService(keychainClient: keychain, defaults: defaults)
        service.saveAPIKey("new-openai-key", for: .openAI)

        #expect(keychain.saveCalls == 1)
        #expect(keychain.interactionFlags.last == true)
        #expect(service.apiKey == "new-openai-key")
    }

    @Test @MainActor func translationService_retryUsesInteractiveReadOnlyAfterStartupMiss() {
        let defaultsName = "IT.TinyAI.Tests.RetryRead.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let keychain = CountingKeychainClient()
        keychain.queuedResults["OpenAIAPIKey"] = [.interactionRequired, .value("recovered-key")]
        let service = TranslationService(keychainClient: keychain, defaults: defaults)

        #expect(service.keychainStatus(for: .openAI) == .interactionRequired)
        #expect(service.retryKeychainAccess(for: .openAI) == .value("recovered-key"))
        #expect(service.apiKey == "recovered-key")
        #expect(keychain.interactionFlags == [false, false, true])
        #expect(keychain.saveCalls == 0)
        #expect(keychain.deleteCalls == 0)
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

    @Test func pasteboardPlainFallback_keepsVisibleListMarkers() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let payload = RichTextConverter.prepare(markdown: "- one\n1. two").payload
        RichTextPasteboard.write(payload, to: pasteboard)

        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType.string) == "• one\n1. two")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType.html) != nil)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType.rtf) != nil)
    }

    @Test func pasteboardCapture_mergesLinksFromHTML_withListsFromRTF() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        let html = "<p>Intro</p><p>See <a href=\"https://example.com/docs\">docs</a></p>"
            + "<ul><li>One</li><li>Two</li></ul>"
        let rtf = RichTextConverter.rtf(
            from: RichTextConverter.prepare(markdown: "Intro\nSee docs\n- One\n- Two").attributed
        )!
        item.setString(html, forType: .html)
        item.setData(rtf, forType: .rtf)
        item.setString("Intro\nSee docs\n• One\n• Two", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let observation = RichTextPasteboard.readObservation(from: pasteboard)
        let payload = observation?.payload
        let prepared = observation?.prepared

        #expect(payload?.plain == "Intro\nSee docs\n• One\n• Two")
        #expect(payload?.html?.contains("<ul>") == true)
        #expect(payload?.html?.contains("https://example.com/docs") == true)
        #expect(prepared.map { RichTextConverter.structureSignature(of: $0.attributed).listItemCount } == 2)
        #expect(observation?.availableTypes.contains(NSPasteboard.PasteboardType.html.rawValue) == true)
        #expect(observation?.availableTypes.contains(NSPasteboard.PasteboardType.rtf.rawValue) == true)
    }

    @Test func pasteboardCapture_promotesSlackMarkers_withoutSanitizingSourceHTMLFirst() {
        let marker = RichTextListMarkers.slackPrivateUseBullet
        let html = "<p>\(marker) First</p><p>\(marker) Second</p><p>After</p>"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString(html, forType: .html)
        item.setString("\(marker) First\n\(marker) Second\nAfter", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let observation = RichTextPasteboard.readObservation(from: pasteboard)
        let prepared = observation?.prepared
        let signature = prepared.map { RichTextConverter.structureSignature(of: $0.attributed) }

        #expect(prepared?.plain == "• First\n• Second\nAfter")
        #expect(signature?.listItemCount == 2)
        #expect(signature?.blocks == [
            "list:unordered:1:item",
            "list:unordered:1:item",
            "paragraph"
        ])
        #expect(prepared?.payload.html?.contains("<ul>") == true)
        #expect(prepared?.attributed.string.contains(marker) == false)
    }

    @Test func pasteboardCapture_browserEditorFixture_keepsLinksAndParagraphs() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString(
            "<div>Browser paragraph</div><div>Open <a href=\"https://example.test/guide\">the guide</a></div>",
            forType: .html
        )
        item.setString("Browser paragraph\nOpen the guide", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let observation = RichTextPasteboard.readObservation(from: pasteboard)
        let signature = observation?.prepared.map { RichTextConverter.structureSignature(of: $0.attributed) }

        #expect(observation?.source == .pasteboardHTML)
        #expect(observation?.payload?.plain == "Browser paragraph\nOpen the guide")
        #expect(signature?.blocks == ["paragraph", "paragraph"])
        #expect(signature?.links == ["https://example.test/guide"])
        #expect(observation?.payload?.html?.contains("https://example.test/guide") == true)
    }

    @Test func pasteboardCapture_textEditFixture_prefersRTFListsAndEmphasis() throws {
        let source = RichTextConverter.prepare(markdown: "**Native heading**\n- first\n- second")
        let rtf = try #require(source.payload.rtf)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setData(rtf, forType: .rtf)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let observation = try #require(RichTextPasteboard.readObservation(from: pasteboard))
        let prepared = try #require(observation.prepared)
        let signature = RichTextConverter.structureSignature(of: prepared.attributed)

        #expect(observation.source == .pasteboardRTF)
        #expect(signature.listItemCount == 2)
        #expect(signature.inlineTraits.contains { $0.contains("bold") })
        #expect(prepared.payload.html?.contains("<ul>") == true)
    }

    @Test func pasteboardCapture_notesFixture_readsFlatRTFDAndKeepsEmoji() throws {
        let source = NSAttributedString(
            string: "Note 😊\n- reminder",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        let rtfd = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setData(rtfd, forType: NSPasteboard.PasteboardType("com.apple.flat-rtfd"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let observation = try #require(RichTextPasteboard.readObservation(from: pasteboard))
        let prepared = try #require(observation.prepared)
        let signature = RichTextConverter.structureSignature(of: prepared.attributed)

        #expect(observation.source == .pasteboardRTFD)
        #expect(prepared.payload.plain.contains("😊"))
        #expect(signature.listItemCount == 1)
    }

    @Test func pasteboardCapture_keepsQuotesCodeEmojiAndInlineStyles() {
        let html = "<blockquote><p><strong>Bold</strong> <em>italic</em> "
            + "<u>underlined</u> <s>struck</s> 😊 <code>code</code></p></blockquote>"
            + "<p><br></p>"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString(html, forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let prepared = RichTextPasteboard.readObservation(from: pasteboard)?.prepared
        let signature = prepared.map { RichTextConverter.structureSignature(of: $0.attributed) }

        #expect(prepared?.plain.contains("Bold italic underlined struck 😊 code") == true)
        #expect(signature?.blocks.contains("quote") == true)
        #expect(signature?.blocks.contains("blank") == true)
        #expect(signature?.inlineTraits.contains { $0.contains("bold") } == true)
        #expect(signature?.inlineTraits.contains { $0.contains("italic") } == true)
        #expect(signature?.inlineTraits.contains { $0.contains("underline") } == true)
        #expect(signature?.inlineTraits.contains { $0.contains("strike") } == true)
        #expect(signature?.inlineTraits.contains { $0.contains("mono") } == true)
        #expect(prepared?.payload.html?.contains("<blockquote>") == true)
        #expect(prepared?.payload.html?.contains("😊") == true)
    }

    @Test func pasteboardCapture_canAddFormattedAccessibility_toConfirmedCopy() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString("- First\n- Second", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        guard let observation = RichTextPasteboard.readObservation(from: pasteboard) else {
            Issue.record("Expected a pasteboard observation")
            return
        }
        let accessibility = RichTextConverter.prepare(html: "<p><strong>First</strong></p><p><strong>Second</strong></p>")!
        let merged = RichTextPasteboard.merging(observation, withAccessibility: accessibility)
        let signature = merged.prepared.map { RichTextConverter.structureSignature(of: $0.attributed) }

        #expect(merged.payload?.plain == "• First\n• Second")
        #expect(signature?.listItemCount == 2)
        #expect(signature?.inlineTraits.contains { $0.contains("bold") } == true)
        #expect(merged.availableTypes.contains("AXSelectedTextAttributedString"))
    }

    @Test func pasteboardCapture_keepsSeparateLists_andPreservesMultipleItemsOrder() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TinyAI.Tests.\(UUID().uuidString)"))
        let first = NSPasteboardItem()
        first.setString("- one\n- two", forType: .string)
        let second = NSPasteboardItem()
        second.setString("- three", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let observation = RichTextPasteboard.readObservation(from: pasteboard)
        let prepared = observation?.prepared
        let signature = prepared.map { RichTextConverter.structureSignature(of: $0.attributed) }

        #expect(prepared?.plain == "• one\n• two\n\n• three")
        #expect(signature?.listGroupCount == 2)
        #expect(prepared?.attributed.string == "one\ntwo\n\nthree")
    }

    @Test func structureSignature_countsNestedItems_asOneListGroup() {
        let prepared = RichTextConverter.prepare(markdown: "- top\n  - nested\n- sibling\n\n1. separate")
        let signature = RichTextConverter.structureSignature(of: prepared.attributed)

        #expect(signature.listItemCount == 4)
        #expect(signature.listGroupCount == 2)
        #expect(signature.listGroups == [
            "unordered:1:group0",
            "unordered:2:group1",
            "unordered:1:group0",
            "none",
            "ordered:1:group2"
        ])
    }

    @Test func captureTiming_waitsForRichFormats_afterPlainAndRejectsStaleClipboard() {
        let start = Date(timeIntervalSinceReferenceDate: 10)
        var timing = RichTextCaptureTimingState(
            baselineChangeCount: 7,
            startedAt: start
        )

        #expect(timing.observe(
            changeCount: 7,
            formatSignature: nil,
            hasReadablePayload: false,
            now: start.addingTimeInterval(0.50)
        ) == .waiting)
        #expect(timing.observe(
            changeCount: 8,
            formatSignature: "plain",
            hasReadablePayload: true,
            now: start.addingTimeInterval(0.60)
        ) == .waiting)
        #expect(timing.observe(
            changeCount: 8,
            formatSignature: "rich",
            hasReadablePayload: true,
            now: start.addingTimeInterval(0.65)
        ) == .waiting)
        #expect(timing.observe(
            changeCount: 8,
            formatSignature: "rich",
            hasReadablePayload: true,
            now: start.addingTimeInterval(0.76)
        ) == .accept)

        var stale = RichTextCaptureTimingState(
            baselineChangeCount: 7,
            startedAt: start
        )
        #expect(stale.observe(
            changeCount: 7,
            formatSignature: "old",
            hasReadablePayload: true,
            now: start.addingTimeInterval(1.01)
        ) == .requestSyntheticCopy)
    }

    @Test func openAIModelFiltering_keepsTextModels_andDropsNonTextModels() {
        #expect(TranslationService.isSupportedOpenAITextModel("gpt-4o"))
        #expect(TranslationService.isSupportedOpenAITextModel("o3-mini"))
        #expect(TranslationService.isSupportedOpenAITextModel("chatgpt-4o-latest"))
        #expect(TranslationService.isSupportedOpenAITextModel("ft:gpt-4o-mini:org:custom:abc123"))
        #expect(!TranslationService.isSupportedOpenAITextModel("gpt-4o-realtime-preview"))
        #expect(!TranslationService.isSupportedOpenAITextModel("text-embedding-3-small"))
        #expect(!TranslationService.isSupportedOpenAITextModel("dall-e-3"))
    }

    @Test func openAIModelParsing_returnsSupportedModels_andFiltersUnsupportedModels() throws {
        let payload = """
        {
          "object": "list",
          "data": [
            {"id": "gpt-5.2"},
            {"id": "o4-mini"},
            {"id": "ft:gpt-4o-mini:org:custom:abc123"},
            {"id": "gpt-4o-realtime-preview"},
            {"id": "gpt-image-1"},
            {"id": "text-embedding-3-small"},
            {"id": "dall-e-3"}
          ]
        }
        """.data(using: .utf8)!

        let entries = try TranslationService.parseOpenAIModelEntries(payload)
        let names = Set(entries.map(\.model.name))

        #expect(names == Set([
            "gpt-5.2",
            "o4-mini",
            "ft:gpt-4o-mini:org:custom:abc123"
        ]))
    }

    @Test func modelCatalogMerge_addsVisibleUniqueModels_andPreservesExistingSettings() {
        let existing = LLMModel(provider: .openAI, name: "gpt-5-mini")
        let unavailable = LLMModel(provider: .openAI, name: "gpt-4o")
        let newModel = LLMModel(provider: .openAI, name: "o4-mini")
        let deleted = LLMModel(provider: .openAI, name: "gpt-4.1")

        let result = TranslationService.mergeFetchedModels(
            existing: [
                LLMModelEntry(model: existing, displayName: existing.name),
                LLMModelEntry(model: unavailable, displayName: unavailable.name)
            ],
            fetched: [
                LLMModelEntry(model: existing, displayName: existing.name),
                LLMModelEntry(model: newModel, displayName: newModel.name),
                LLMModelEntry(model: newModel, displayName: newModel.name),
                LLMModelEntry(model: deleted, displayName: deleted.name)
            ],
            visibility: [existing.key: false],
            availability: [existing.key: true, unavailable.key: true],
            provider: .openAI,
            deletedKeys: [deleted.key]
        )

        #expect(result.models.map(\.model.key) == [existing.key, unavailable.key, newModel.key])
        #expect(result.visibility[existing.key] == false)
        #expect(result.visibility[newModel.key] == true)
        #expect(result.availability[existing.key] == true)
        #expect(result.availability[unavailable.key] == false)
        #expect(result.availability[newModel.key] == true)
        #expect(!result.models.contains { $0.model == deleted })
    }

    @Test func openAIModelParsing_returnsEmptyForOnlyUnsupportedModels() throws {
        let payload = """
        {"data": [{"id": "gpt-4o-realtime-preview"}, {"id": "text-embedding-3-small"}]}
        """.data(using: .utf8)!

        let entries = try TranslationService.parseOpenAIModelEntries(payload)
        #expect(entries.isEmpty)
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
