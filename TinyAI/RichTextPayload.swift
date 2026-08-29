import AppKit
import Foundation
import ApplicationServices

final class TextReplacementTarget: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t

    init(element: AXUIElement, processIdentifier: pid_t) {
        self.element = element
        self.processIdentifier = processIdentifier
    }
}

struct RichTextPayload: Equatable, @unchecked Sendable {
    var plain: String
    var html: String?
    var rtf: Data?
    var replacementTarget: TextReplacementTarget?
    /// Metadata is kept next to the payload so the capture path can be
    /// inspected without changing the popup/model API.  It is deliberately
    /// ignored by Equatable: it describes how the text arrived, not the text
    /// itself.
    var captureMetadata: RichTextCaptureMetadata?

    init(
        plain: String,
        html: String?,
        rtf: Data?,
        replacementTarget: TextReplacementTarget? = nil,
        captureMetadata: RichTextCaptureMetadata? = nil
    ) {
        self.plain = plain
        self.html = html
        self.rtf = rtf
        self.replacementTarget = replacementTarget
        self.captureMetadata = captureMetadata
    }

    static func == (lhs: RichTextPayload, rhs: RichTextPayload) -> Bool {
        lhs.plain == rhs.plain && lhs.html == rhs.html && lhs.rtf == rhs.rtf
    }
}

enum RichTextCaptureSource: String, Equatable, Sendable {
    case pasteboardHTML
    case pasteboardRTF
    case pasteboardRTFD
    case pasteboardPlain
    case accessibilityAttributed
    case accessibilityPlain
}

enum RichTextCaptureCompleteness: String, Equatable, Sendable {
    case rich
    case attributed
    case plain
}

/// Safe diagnostics for one selection capture.  This type intentionally has
/// no text, link labels, or URLs: it is suitable for a local diagnostic log.
struct RichTextCaptureMetadata: Equatable, Sendable {
    let application: String
    let availableTypes: [String]
    let elapsedMilliseconds: Int
    let source: RichTextCaptureSource
    let completeness: RichTextCaptureCompleteness
    let blockCount: Int
    let listCount: Int
    let linkCount: Int
    let styleCount: Int
}

struct RichTextFormattingSummary: Equatable, Sendable {
    let blockCount: Int
    let listCount: Int
    let linkCount: Int
    let styleCount: Int
}

enum RichTextCaptureWaitDecision: Equatable, Sendable {
    case waiting
    case accept
    case requestSyntheticCopy
}

/// Small, deterministic timing state used by the asynchronous pasteboard
/// watcher.  Keeping this decision separate makes the delayed-plain/rich and
/// stale-clipboard cases testable without touching the real system pasteboard.
struct RichTextCaptureTimingState: Sendable {
    let baselineChangeCount: Int
    let startedAt: Date
    let timeout: TimeInterval
    let stabilityWindow: TimeInterval
    private(set) var lastFormatSignature: String?
    private(set) var stableSince: Date?

    init(
        baselineChangeCount: Int,
        startedAt: Date,
        timeout: TimeInterval = 1.0,
        stabilityWindow: TimeInterval = 0.10,
        lastFormatSignature: String? = nil,
        stableSince: Date? = nil
    ) {
        self.baselineChangeCount = baselineChangeCount
        self.startedAt = startedAt
        self.timeout = timeout
        self.stabilityWindow = stabilityWindow
        self.lastFormatSignature = lastFormatSignature
        self.stableSince = stableSince
    }

    mutating func observe(
        changeCount: Int,
        formatSignature: String?,
        hasReadablePayload: Bool,
        now: Date
    ) -> RichTextCaptureWaitDecision {
        let elapsed = now.timeIntervalSince(startedAt)
        guard changeCount != baselineChangeCount else {
            return elapsed >= timeout ? .requestSyntheticCopy : .waiting
        }

        if let formatSignature {
            if formatSignature == lastFormatSignature {
                if hasReadablePayload {
                    stableSince = stableSince ?? now
                }
            } else {
                lastFormatSignature = formatSignature
                stableSince = hasReadablePayload ? now : nil
            }
        }

        if hasReadablePayload,
           let stableSince,
           now.timeIntervalSince(stableSince) >= stabilityWindow {
            return .accept
        }

        if elapsed >= timeout + (hasReadablePayload ? stabilityWindow : 0) {
            return .requestSyntheticCopy
        }
        return .waiting
    }
}

/// The single, canonical representation used by the popup, Copy and Replace.
/// The attributed string is deliberately kept alongside the pasteboard payload:
/// reading our own RTF back would run the source-app normalisation a second time.
struct PreparedRichText: @unchecked Sendable {
    let plain: String
    let attributed: NSAttributedString
    let payload: RichTextPayload

    init(attributed: NSAttributedString, payload: RichTextPayload) {
        self.attributed = attributed
        self.plain = payload.plain
        self.payload = payload
    }
}

/// A semantic description of rich text.  It intentionally ignores fonts,
/// colours and exact translated character counts, while retaining the parts
/// that a built-in translation must not change.
struct RichTextStructureSignature: Equatable, Sendable {
    let blocks: [String]
    let links: [String]
    let inlineTraits: [String]

    var listItemCount: Int {
        blocks.filter { $0.hasPrefix("list:") }.count
    }

    var listGroupCount: Int {
        var result = 0
        var rootKind: String?
        var inList = false
        for block in blocks {
            guard block.hasPrefix("list:") else {
                inList = false
                rootKind = nil
                continue
            }
            let parts = block.split(separator: ":")
            let kind = parts.count > 1 ? String(parts[1]) : "unordered"
            let depth = parts.count > 2 ? Int(parts[2]) ?? 1 : 1
            if !inList || (depth == 1 && rootKind != kind) {
                result += 1
                rootKind = kind
                inList = true
            }
        }
        return result
    }

    /// Stable group labels for diagnostics and regression tests.  A nested
    /// list has its own depth group, while returning to its parent reuses the
    /// parent's label; a non-list paragraph starts a fresh run.
    var listGroups: [String] {
        var nextGroup = 0
        var groupsByDepth: [String: Int] = [:]
        var lastDepth: Int?
        var lastKind: String?
        var result: [String] = []
        for block in blocks {
            guard block.hasPrefix("list:") else {
                result.append("none")
                groupsByDepth.removeAll()
                lastDepth = nil
                lastKind = nil
                continue
            }
            let parts = block.split(separator: ":")
            let kind = parts.count > 1 ? String(parts[1]) : "unordered"
            let depth = parts.count > 2 ? Int(parts[2]) ?? 1 : 1
            if let lastDepth, let lastKind, lastKind != kind, depth <= lastDepth {
                groupsByDepth = groupsByDepth.filter { key, _ in
                    let keyDepth = Int(key.split(separator: ":").last ?? "1") ?? 1
                    return keyDepth < depth
                }
            }
            let key = "\(kind):\(depth)"
            let group = groupsByDepth[key] ?? {
                defer { nextGroup += 1 }
                return nextGroup
            }()
            groupsByDepth[key] = group
            result.append("\(kind):\(depth):group\(group)")
            lastDepth = depth
            lastKind = kind
        }
        return result
    }

    var structuralScore: Int {
        blocks.reduce(into: 0) { score, block in
            if block.hasPrefix("list:") {
                let depth = Int(block.split(separator: ":").dropFirst(2).first ?? "1") ?? 1
                score += 8 + depth
            } else if block == "code" {
                score += 5
            } else if block == "quote" {
                score += 4
            } else if block == "blank" {
                score += 3
            } else {
                score += 1
            }
        }
    }

    var inlineScore: Int {
        links.count * 4 + inlineTraits.count * 2
    }
}

enum RichTextSemanticAttributes {
    /// AppKit has no portable paragraph-level quote attribute.  This private
    /// key lets the input normaliser retain quote semantics across HTML, RTF,
    /// Accessibility and the canonical output representations.
    static let quote = NSAttributedString.Key("TinyAI.quote")
}

enum RichTextHTMLSanitizer {
    static func sanitize(_ html: String) -> String {
        var result = html
        // List markers copied from rich-text applications can be duplicated:
        // once by the list structure and once as a literal character in the
        // text. Remove those characters before stripping the source font; some
        // applications use a private-use glyph for the visible marker.
        result = removeDuplicateListBullets(from: result)
        result = replaceStandalonePrivateUseListMarkers(from: result)
        result = stripFontMarkupAndStyles(from: result)
        return result
    }

    static func isLikelyHTML(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<"), trimmed.contains(">") else { return false }
        let lowered = trimmed.prefix(512).lowercased()
        return lowered.contains("<html") || lowered.contains("<body") || lowered.contains("<p") || lowered.contains("<div") || lowered.contains("<span") || lowered.contains("<ul") || lowered.contains("<ol") || lowered.contains("<li") || lowered.contains("<pre") || lowered.contains("<code") || lowered.contains("<a ") || lowered.contains("<strong") || lowered.contains("<em") || lowered.contains("<h1") || lowered.contains("<table") || lowered.contains("<tr") || lowered.contains("<td") || lowered.contains("<blockquote") || lowered.contains("<br")
    }

    private static func stripFontMarkupAndStyles(from html: String) -> String {
        var result = html

        // AppKit writes a document-level CSS block for every source font.  It
        // is presentation-only and can contain declarations that span lines;
        // remove the complete block before applying inline sanitisation so the
        // generated HTML remains valid.
        result = replacingRegex(
            in: result,
            pattern: "<style\\b[^>]*>.*?</style\\s*>",
            with: "",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        result = replacingRegex(in: result, pattern: "</?font\\b[^>]*>", with: "", options: [.caseInsensitive])
        result = replacingRegex(in: result, pattern: "\\sface\\s*=\\s*\"[^\"]*\"", with: "", options: [.caseInsensitive])
        result = replacingRegex(in: result, pattern: "\\scolor\\s*=\\s*\"[^\"]*\"", with: "", options: [.caseInsensitive])

        // Strip CSS declarations that carry source-app typography or colors
        // while keeping semantic styles such as bold and italic.
        result = replacingRegex(in: result, pattern: "font-family\\s*:\\s*[^;\"']+;?", with: "", options: [.caseInsensitive])
        result = replacingRegex(in: result, pattern: "font-size\\s*:\\s*[^;\"']+;?", with: "", options: [.caseInsensitive])
        result = replacingRegex(in: result, pattern: "(?<![-\\w])(?:background-)?color\\s*:\\s*[^;\"']+;?", with: "", options: [.caseInsensitive])

        // Clean up empty style="" attributes left after stripping.
        result = replacingRegex(in: result, pattern: "\\sstyle\\s*=\\s*\"\\s*\"", with: "", options: [.caseInsensitive])
        result = replacingRegex(in: result, pattern: "\\sstyle\\s*=\\s*\"\\s*;\\s*\"", with: "", options: [.caseInsensitive])

        return result
    }

    private static func removeDuplicateListBullets(from html: String) -> String {
        var result = html

        let markerPattern = "(?:&bull;|&#8226;|&#x2022;|•|·|◦|▪|‣|\\-|\\*|\\+|\(RichTextListMarkers.slackPrivateUseBullet)|&#58630;|&#x[eE]506;)"

        // Remove a literal bullet that appears inside <li> content (often duplicated by list styling).
        // Covers cases like:
        // - <li>• text</li>
        // - <li><p>• text</p></li>
        // - <li><span>•</span> text</li>
        // - <li><span><b>•</b></span> text</li>
        result = replacingRegex(
            in: result,
            pattern: "(<li\\b[^>]*>(?:(?!<(?:pre|code)\\b)(?:\\s|&nbsp;|<[^>]+>))*)(" + markerPattern + ")((?:</?[^>]+>)*)(?:[ \\t]|&nbsp;)+((?:</?[^>]+>)*)",
            with: "$1$3$4",
            options: [.caseInsensitive]
        )

        // Clean up empty wrappers that may remain after removing the bullet glyph.
        // Run this more than once so nested wrappers are removed from the inside out.
        let emptyInlineWrapperPattern = "<(?:strong|b|span|em|i|u|s|del|a)\\b[^>]*>\\s*</(?:strong|b|span|em|i|u|s|del|a)>"
        for _ in 0..<3 {
            result = replacingRegex(in: result, pattern: emptyInlineWrapperPattern, with: "", options: [.caseInsensitive])
        }

        return result
    }

    private static func replaceStandalonePrivateUseListMarkers(from html: String) -> String {
        let markerPattern = "(?:\(RichTextListMarkers.slackPrivateUseBullet)|&#58630;|&#x[eE]506;)"

        // A private-use list glyph outside <li> still carries list meaning.
        // Replace it with a normal bullet only at the start of a block. The
        // look-ahead allows inline wrappers such as <span>...</span> between
        // the glyph and the following whitespace.
        let blockStartPattern = "((?:^|<(?:p|div|h[1-6]|blockquote|td|th)\\b[^>]*>)(?:(?!<(?:pre|code)\\b)(?:\\s|&nbsp;|<[^>]+>))*)"
        let followingWhitespace = "(?=(?:(?:</?[^>]+>)*)(?:[ \\t]|&nbsp;))"
        return replacingRegex(
            in: html,
            pattern: blockStartPattern + markerPattern + followingWhitespace,
            with: "$1•",
            options: [.caseInsensitive]
        )
    }

    private static func replacingRegex(in input: String, pattern: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}

extension String {
    func normalizedPlainText() -> String {
        self
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}

enum RichTextListMarkers {
    static let slackPrivateUseBullet = "\u{E506}"

    enum Kind {
        case unordered
        case ordered
    }

    struct Match {
        let kind: Kind
        let markerRange: Range<String.Index>
        let separatorRange: Range<String.Index>
        let marker: Character
    }

    private static let unorderedCharacters: Set<Character> = ["•", "·", "◦", "▪", "‣", "-", "*", "+", "\u{E506}"]

    static func match(in line: String) -> Match? {
        var index = line.startIndex
        while index < line.endIndex, isHorizontalWhitespace(line[index]) {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }

        let marker = line[index]
        if unorderedCharacters.contains(marker) {
            let afterMarker = line.index(after: index)
            guard afterMarker < line.endIndex, isHorizontalWhitespace(line[afterMarker]) else {
                return nil
            }

            let separatorEnd = endOfHorizontalWhitespace(in: line, from: afterMarker)
            return Match(
                kind: .unordered,
                markerRange: index..<afterMarker,
                separatorRange: afterMarker..<separatorEnd,
                marker: marker
            )
        }

        if marker.isNumber || marker.isLetter {
            var cursor = line.index(after: index)
            var digitOrLetterCount = 1
            while cursor < line.endIndex,
                  digitOrLetterCount < 3,
                  line[cursor].isNumber == marker.isNumber,
                  line[cursor].isLetter == marker.isLetter {
                cursor = line.index(after: cursor)
                digitOrLetterCount += 1
            }

            // A prose line such as "As discussed ..." starts with letters
            // followed by whitespace, but it is not an ordered-list item.
            // Require the punctuation used by list markers before accepting
            // numeric or alphabetic ordered items (for example, "1. item"
            // or "a) item").
            guard cursor < line.endIndex, line[cursor] == "." || line[cursor] == ")" else {
                return nil
            }
            cursor = line.index(after: cursor)
            guard cursor < line.endIndex, isHorizontalWhitespace(line[cursor]) else {
                return nil
            }

            let separatorEnd = endOfHorizontalWhitespace(in: line, from: cursor)
            return Match(
                kind: .ordered,
                markerRange: index..<cursor,
                separatorRange: cursor..<separatorEnd,
                marker: marker
            )
        }

        return nil
    }

    static func normalizedMarkdownLine(_ line: String, replacingPrivateUseMarker: Bool = true) -> String? {
        guard let match = match(in: line), match.kind == .unordered else {
            return nil
        }
        if !replacingPrivateUseMarker, match.marker == "\u{E506}" {
            return nil
        }

        let indent = String(line[..<match.markerRange.lowerBound])
        let rest = String(line[match.separatorRange.upperBound...])
        return indent + "- " + rest
    }

    static func displayMarkdownLine(_ line: String) -> String? {
        guard let match = match(in: line), match.kind == .unordered else {
            return nil
        }

        let indent = String(line[..<match.markerRange.lowerBound])
        let rest = String(line[match.separatorRange.upperBound...])
        return indent + "• " + rest
    }

    static func markerRange(in paragraph: String) -> NSRange? {
        guard let match = match(in: paragraph) else { return nil }
        return NSRange(match.markerRange, in: paragraph)
    }

    static func isCodeFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    static func quoteContent(in line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, isHorizontalWhitespace(line[index]) {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == ">" else { return nil }
        index = line.index(after: index)
        while index < line.endIndex, isHorizontalWhitespace(line[index]) {
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{00A0}"
    }

    private static func endOfHorizontalWhitespace(in line: String, from start: String.Index) -> String.Index {
        var index = start
        while index < line.endIndex, isHorizontalWhitespace(line[index]) {
            index = line.index(after: index)
        }
        return index
    }
}

enum RichTextConverter {
    private static let defaultFont = NSFont.preferredFont(forTextStyle: .body)
    private static let defaultColor = NSColor.labelColor

    private struct HTMLBlock {
        let depth: Int
        let kind: String
        let content: String
    }

    /// Prepare Markdown exactly once.  This is the existing model/output
    /// path; selection capture uses the capture-specific helpers below so
    /// response handling remains unchanged.
    static func prepare(markdown: String) -> PreparedRichText {
        let attributed = attributedString(fromMarkdown: markdown)
        return prepared(attributed: attributed)
    }

    /// Prepare plain text that was just read from another application's
    /// pasteboard.  Capture needs the additional quote and marker semantics;
    /// the regular Markdown path intentionally keeps its old behaviour.
    static func prepareCaptured(markdown: String) -> PreparedRichText {
        let attributed = attributedString(fromMarkdown: markdown, includeQuoteSemantics: true)
        return prepare(attributed: attributed, inferListMarkers: true)
    }

    /// Prepare model/output HTML using the pre-existing sanitisation order.
    /// Capture must call `prepareCaptured(html:)`, which parses the source
    /// before any output cleanup can remove structural clues.
    static func prepare(html: String) -> PreparedRichText? {
        let sanitized = RichTextHTMLSanitizer.sanitize(html)
        guard RichTextHTMLSanitizer.isLikelyHTML(sanitized),
              let parsed = parseHTML(sanitized) else {
            return nil
        }

        let parsedWithoutSyntheticNewline = removingSyntheticFinalNewline(
            from: parsed,
            sourceHTML: sanitized
        )
        let withPrivateMarkers = replacingPrivateUseListMarkers(in: parsedWithoutSyntheticNewline)
        let withoutDuplicateMarkers = normalizedListMarkers(in: withPrivateMarkers)
        let withSemanticFonts = normalizedFonts(in: withoutDuplicateMarkers, baseFont: defaultFont)
        let canonical = applyingBaseAttributesIfMissing(
            to: normalizedColors(in: withSemanticFonts, baseColor: defaultColor),
            baseFont: defaultFont,
            baseColor: defaultColor
        )
        return prepared(attributed: canonical)
    }

    /// Parse source HTML before applying output cleanup.  This is used only at
    /// the external-selection boundary, where list markers and source roles
    /// must still be available to the structure normaliser.
    static func prepareCaptured(html: String) -> PreparedRichText? {
        guard RichTextHTMLSanitizer.isLikelyHTML(html) else {
            return nil
        }

        let parsed = parseHTML(html) ?? parseHTML(RichTextHTMLSanitizer.sanitize(html))
        guard let parsed else { return nil }

        let withoutSyntheticNewline = removingSyntheticFinalNewline(
            from: parsed,
            sourceHTML: html
        )
        return prepare(attributed: annotatingQuotes(
            in: withoutSyntheticNewline,
            sourceHTML: html
        ), inferListMarkers: true)
    }

    static func prepare(payload: RichTextPayload) -> PreparedRichText {
        if let html = payload.html, let prepared = prepare(html: html) {
            return prepared
        }
        if let rtf = payload.rtf,
           let parsed = try? NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            let withPrivateMarkers = replacingPrivateUseListMarkers(in: parsed)
            let withoutDuplicateMarkers = normalizedListMarkers(in: withPrivateMarkers)
            let withSemanticFonts = normalizedFonts(in: withoutDuplicateMarkers, baseFont: defaultFont)
            let canonical = applyingBaseAttributesIfMissing(
                to: normalizedColors(in: withSemanticFonts, baseColor: defaultColor),
                baseFont: defaultFont,
                baseColor: defaultColor
            )
            return prepared(attributed: canonical)
        }
        return prepare(markdown: payload.plain.normalizedPlainText())
    }

    static func prepare(
        rtf data: Data,
        documentType: NSAttributedString.DocumentType = .rtf,
        inferListMarkers: Bool = false
    ) -> PreparedRichText? {
        guard let parsed = try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
        ) else {
            return nil
        }
        return prepare(attributed: parsed, inferListMarkers: inferListMarkers)
    }

    /// Normalise an attributed selection once, then derive all output forms
    /// from that same attributed string.  This is the boundary between input
    /// capture and the existing model/popup code.
    static func prepare(attributed: NSAttributedString, inferListMarkers: Bool = false) -> PreparedRichText {
        let withIndentedQuotes = annotatingIndentedQuotes(in: attributed)
        let withPrivateMarkers = replacingPrivateUseListMarkers(in: withIndentedQuotes)
        let withSemanticLists = normalizedListSemantics(in: withPrivateMarkers, inferListMarkers: inferListMarkers)
        let withSemanticFonts = normalizedFonts(in: withSemanticLists, baseFont: defaultFont)
        let canonical = applyingBaseAttributesIfMissing(
            to: normalizedColors(in: withSemanticFonts, baseColor: defaultColor),
            baseFont: defaultFont,
            baseColor: defaultColor
        )
        return prepared(attributed: canonical, includeCaptureSemantics: true)
    }

    static func attributedString(from payload: RichTextPayload) -> NSAttributedString {
        prepare(payload: payload).attributed
    }

    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
        attributedString(fromMarkdown: markdown, includeQuoteSemantics: false)
    }

    private static func attributedString(
        fromMarkdown markdown: String,
        includeQuoteSemantics: Bool
    ) -> NSAttributedString {
        let normalized = normalizedMarkdown(markdown)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSAttributedString(string: "")
        }

        let lines = normalized.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        var isInsideCodeFence = false
        var listStack: [NSTextList] = []

        for (index, line) in lines.enumerated() {
            let startsFence = RichTextListMarkers.isCodeFence(line)
            let lineStart = result.length

            if isInsideCodeFence || startsFence {
                listStack.removeAll()
                result.append(NSAttributedString(
                    string: line,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize, weight: .regular),
                        .foregroundColor: defaultColor
                    ]
                ))
            } else if includeQuoteSemantics,
                      let quote = RichTextListMarkers.quoteContent(in: line) {
                listStack.removeAll()
                result.append(inlineAttributedString(quote))
                let quoteStyle = NSMutableParagraphStyle()
                quoteStyle.firstLineHeadIndent = 20
                quoteStyle.headIndent = 20
                result.addAttribute(
                    .paragraphStyle,
                    value: quoteStyle,
                    range: NSRange(location: lineStart, length: result.length - lineStart)
                )
                result.addAttribute(
                    RichTextSemanticAttributes.quote,
                    value: true,
                    range: NSRange(location: lineStart, length: result.length - lineStart)
                )
            } else if let match = RichTextListMarkers.match(in: line) {
                let body = String(line[match.separatorRange.upperBound...])
                result.append(inlineAttributedString(body))
                let depth = listDepth(in: line, marker: match)
                if depth < listStack.count {
                    listStack.removeLast(listStack.count - depth)
                }
                if listStack.count == depth {
                    listStack.append(NSTextList(
                        markerFormat: match.kind == .ordered ? .decimal : .disc,
                        options: 0
                    ))
                } else if listStack[depth].markerFormat != (match.kind == .ordered ? .decimal : .disc) {
                    listStack.removeLast(listStack.count - depth)
                    listStack.append(NSTextList(
                        markerFormat: match.kind == .ordered ? .decimal : .disc,
                        options: 0
                    ))
                }
                applyListStyle(
                    to: result,
                    range: NSRange(location: lineStart, length: result.length - lineStart),
                    textLists: listStack,
                    depth: depth
                )
            } else {
                listStack.removeAll()
                result.append(inlineAttributedString(line))
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: defaultFont,
                    .foregroundColor: defaultColor
                ]))
                if let style = result.attribute(.paragraphStyle, at: lineStart, effectiveRange: nil) as? NSParagraphStyle {
                    result.addAttribute(
                        .paragraphStyle,
                        value: style,
                        range: NSRange(location: lineStart, length: result.length - lineStart)
                    )
                }
            }

            if startsFence {
                isInsideCodeFence.toggle()
            }
        }

        let withFonts = normalizedFonts(in: result, baseFont: defaultFont)
        return applyingBaseAttributesIfMissing(
            to: normalizedColors(in: withFonts, baseColor: defaultColor),
            baseFont: defaultFont,
            baseColor: defaultColor
        )
    }

    static func payload(fromMarkdown markdown: String) -> RichTextPayload {
        prepare(markdown: markdown).payload
    }

    static func normalizedMarkdown(_ raw: String, replacingPrivateUseMarkers: Bool = true) -> String {
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        lines.reserveCapacity(normalizedNewlines.count / 20)
        var isInsideCodeFence = false

        for line in normalizedNewlines.components(separatedBy: "\n") {
            if RichTextListMarkers.isCodeFence(line) {
                lines.append(line)
                isInsideCodeFence.toggle()
                continue
            }

            if !isInsideCodeFence,
               let converted = RichTextListMarkers.normalizedMarkdownLine(
                   line,
                   replacingPrivateUseMarker: replacingPrivateUseMarkers
               ) {
                lines.append(converted)
            } else {
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func parseHTML(_ html: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .defaultAttributes: [
                    NSAttributedString.Key.font: defaultFont,
                    NSAttributedString.Key.foregroundColor: defaultColor
                ]
            ],
            documentAttributes: nil
        )
    }

    private static func annotatingQuotes(
        in attributed: NSAttributedString,
        sourceHTML: String
    ) -> NSAttributedString {
        guard attributed.length > 0,
              sourceHTML.range(of: "<blockquote\\b", options: [.regularExpression, .caseInsensitive]) != nil else {
            return attributed
        }

        // AppKit usually exposes a blockquote through paragraph indents.  The
        // private marker gives us a stable semantic signal when it does not.
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let range = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, paragraphRange, _ in
            guard let style = value as? NSParagraphStyle,
                  style.headIndent > style.firstLineHeadIndent + 0.5 else {
                return
            }
            mutable.addAttribute(RichTextSemanticAttributes.quote, value: true, range: paragraphRange)
        }

        // If the HTML parser flattened the blockquote without an indent, mark
        // its visible text by walking each source block in order.  This does
        // not rewrite text or links; it only records the semantic role.
        guard let regex = try? NSRegularExpression(
            pattern: "<blockquote\\b[^>]*>(.*?)</blockquote\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return mutable
        }
        let sourceRange = NSRange(sourceHTML.startIndex..<sourceHTML.endIndex, in: sourceHTML)
        for match in regex.matches(in: sourceHTML, options: [], range: sourceRange) {
            guard match.numberOfRanges > 1,
                  let innerRange = Range(match.range(at: 1), in: sourceHTML) else { continue }
            let innerHTML = String(sourceHTML[innerRange])
            guard let inner = parseHTML(innerHTML) else { continue }
            let visible = inner.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !visible.isEmpty else { continue }
            let visibleRange = (mutable.string as NSString).range(of: visible)
            guard visibleRange.location != NSNotFound else { continue }
            mutable.addAttribute(RichTextSemanticAttributes.quote, value: true, range: visibleRange)
        }
        return mutable
    }

    private static func annotatingIndentedQuotes(in attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: mutable.length),
            options: []
        ) { value, paragraphRange, _ in
            guard let style = value as? NSParagraphStyle,
                  style.textLists.isEmpty,
                  style.headIndent > max(CGFloat(16), style.firstLineHeadIndent + 0.5),
                  mutable.attribute(.font, at: paragraphRange.location, effectiveRange: nil)
                    .flatMap({ ($0 as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) }) != true else {
                return
            }
            mutable.addAttribute(RichTextSemanticAttributes.quote, value: true, range: paragraphRange)
        }
        return mutable
    }

    static func structureSignature(of attributed: NSAttributedString) -> RichTextStructureSignature {
        var blocks: [String] = []
        var location = 0
        while location < attributed.length {
            let paragraphRange = (attributed.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let contentLength = max(0, paragraphRange.length - (
                (attributed.string as NSString).substring(with: paragraphRange).hasSuffix("\n") ? 1 : 0
            ))
            let text = (attributed.string as NSString).substring(
                with: NSRange(location: paragraphRange.location, length: contentLength)
            )
            let style = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            if let list = style?.textLists.last {
                let kind = list.markerFormat == .decimal ? "ordered" : "unordered"
                let depth = max(1, style?.textLists.count ?? 1)
                blocks.append("list:\(kind):\(depth):\(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "item")")
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append("blank")
            } else {
                let isCode = attributed.attribute(.font, at: paragraphRange.location, effectiveRange: nil)
                    .flatMap { ($0 as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) } ?? false
                let isQuote = attributed.attribute(
                    RichTextSemanticAttributes.quote,
                    at: paragraphRange.location,
                    effectiveRange: nil
                ) as? Bool == true
                let block = isCode ? "code" : (isQuote ? "quote" : "paragraph")
                // Adjacent monospaced paragraphs are one code block for the
                // purpose of validation; AppKit may split or merge their line
                // ranges while round-tripping HTML/RTF.
                if block != "code" || blocks.last != "code" {
                    blocks.append(block)
                }
            }
            location = NSMaxRange(paragraphRange)
        }

        var links: [String] = []
        if attributed.length > 0 {
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
                guard let value else { return }
                if let url = value as? URL {
                    links.append(normalizedLink(url.absoluteString))
                } else if let url = value as? NSURL {
                    links.append(normalizedLink(url.absoluteString ?? url.description))
                } else {
                    links.append(String(describing: value))
                }
            }
        }

        var traitCounts: [String: Int] = [:]
        if attributed.length > 0 {
            attributed.enumerateAttributes(
                in: NSRange(location: 0, length: attributed.length),
                options: []
            ) { attributes, range, _ in
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                var parts: [String] = []
                if traits.contains(.monoSpace) { parts.append("mono") }
                if traits.contains(.bold) { parts.append("bold") }
                if traits.contains(.italic) { parts.append("italic") }
                if attributes[.underlineStyle] != nil {
                    parts.append("underline")
                }
                if attributes[.strikethroughStyle] != nil {
                    parts.append("strike")
                }
                if !parts.isEmpty {
                    let key = parts.joined(separator: "+")
                    // Counts are intentionally presence flags.  AppKit may
                    // merge adjacent code paragraphs into one run when it
                    // parses the HTML again; that is not a structure change.
                    traitCounts[key] = 1
                }
            }
        }

        let inlineTraits = traitCounts.keys.sorted().map { "\($0):\(traitCounts[$0] ?? 0)" }
        return RichTextStructureSignature(blocks: blocks, links: links, inlineTraits: inlineTraits)
    }

    static func comparableText(of prepared: PreparedRichText) -> String {
        prepared.attributed.string
            .normalizedPlainText()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .newlines)
    }

    static func formattingSummary(of prepared: PreparedRichText) -> RichTextFormattingSummary {
        let signature = structureSignature(of: prepared.attributed)
        return RichTextFormattingSummary(
            blockCount: signature.blocks.count,
            listCount: signature.listGroupCount,
            linkCount: signature.links.count,
            styleCount: signature.inlineTraits.count
        )
    }

    static func mergeCompatible(_ candidates: [RichTextPasteboardCandidate]) -> RichTextPasteboardCandidate? {
        guard let first = candidates.first else { return nil }
        let comparable = comparableText(of: first.prepared)
        let compatible = candidates.filter { comparableText(of: $0.prepared) == comparable }
        guard !compatible.isEmpty else { return first }

        let base = compatible.max {
            let left = structureSignature(of: $0.prepared.attributed)
            let right = structureSignature(of: $1.prepared.attributed)
            if left.structuralScore != right.structuralScore {
                return left.structuralScore < right.structuralScore
            }
            return left.inlineScore < right.inlineScore
        } ?? first

        guard compatible.count > 1 else { return base }
        let merged = NSMutableAttributedString(attributedString: base.prepared.attributed)
        let baseIndex = compatible.firstIndex {
            $0.itemIndex == base.itemIndex
                && $0.source == base.source
                && $0.prepared.payload == base.prepared.payload
        }
        for (index, candidate) in compatible.enumerated() where index != (baseIndex ?? -1) {
            mergeInlineAttributes(from: candidate.prepared.attributed, into: merged)
        }
        let prepared = prepare(attributed: merged)
        return RichTextPasteboardCandidate(
            itemIndex: base.itemIndex,
            source: base.source,
            availableTypes: Array(Set(compatible.flatMap(\.availableTypes))).sorted(),
            prepared: prepared
        )
    }

    private static func mergeInlineAttributes(
        from source: NSAttributedString,
        into target: NSMutableAttributedString
    ) {
        guard source.string == target.string, source.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            guard range.length > 0 else { return }
            if target.attribute(.link, at: range.location, effectiveRange: nil) == nil,
               let link = attributes[.link] {
                target.addAttribute(.link, value: link, range: range)
            }
            if target.attribute(.underlineStyle, at: range.location, effectiveRange: nil) == nil,
               let underline = attributes[.underlineStyle] {
                target.addAttribute(.underlineStyle, value: underline, range: range)
            }
            if target.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) == nil,
               let strike = attributes[.strikethroughStyle] {
                target.addAttribute(.strikethroughStyle, value: strike, range: range)
            }
            if target.attribute(RichTextSemanticAttributes.quote, at: range.location, effectiveRange: nil) == nil,
               let quote = attributes[RichTextSemanticAttributes.quote] {
                target.addAttribute(RichTextSemanticAttributes.quote, value: quote, range: range)
            }

            guard let sourceFont = attributes[.font] as? NSFont else { return }
            let sourceTraits = sourceFont.fontDescriptor.symbolicTraits
            guard sourceTraits.contains(.bold)
                || sourceTraits.contains(.italic)
                || sourceTraits.contains(.monoSpace) else {
                return
            }
            let targetFont = target.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? defaultFont
            let targetTraits = targetFont.fontDescriptor.symbolicTraits
            var mergedFont = targetFont
            let manager = NSFontManager.shared
            if sourceTraits.contains(.monoSpace) && !targetTraits.contains(.monoSpace) {
                mergedFont = NSFont.monospacedSystemFont(
                    ofSize: targetFont.pointSize,
                    weight: sourceTraits.contains(.bold) || targetTraits.contains(.bold) ? .bold : .regular
                )
            } else if sourceTraits.contains(.bold) && !targetTraits.contains(.bold) {
                mergedFont = manager.convert(mergedFont, toHaveTrait: .boldFontMask)
            }
            if sourceTraits.contains(.italic) && !mergedFont.fontDescriptor.symbolicTraits.contains(.italic) {
                mergedFont = manager.convert(mergedFont, toHaveTrait: .italicFontMask)
            }
            target.addAttribute(.font, value: mergedFont, range: range)
        }
    }

    private static func normalizedLink(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              components.host != nil,
              components.path == "/" else {
            return value
        }
        components.path = ""
        return components.string ?? value
    }

    static func html(from attributed: NSAttributedString) -> String? {
        html(from: attributed, includeCaptureSemantics: false)
    }

    private static func html(
        from attributed: NSAttributedString,
        includeCaptureSemantics: Bool
    ) -> String? {
        guard attributed.length > 0 else { return nil }

        var blocks: [HTMLBlock] = []
        var location = 0
        while location < attributed.length {
            let paragraphRange = (attributed.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let rawParagraph = (attributed.string as NSString).substring(with: paragraphRange)
            let contentLength = max(0, paragraphRange.length - (rawParagraph.hasSuffix("\n") ? 1 : 0))
            let contentRange = NSRange(location: paragraphRange.location, length: contentLength)
            let style = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            let list = style?.textLists.last
            let depth = max(0, (style?.textLists.count ?? 1) - 1)
            let kind = list?.markerFormat == .decimal ? "ol" : "ul"
            let isQuote = includeCaptureSemantics && attributed.attribute(
                RichTextSemanticAttributes.quote,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? Bool == true
            let isCode = isMonospacedParagraph(in: attributed, range: contentRange)
            let baseContent = isCode
                ? escapeHTML((attributed.string as NSString).substring(with: contentRange))
                : htmlInline(
                    from: attributed,
                    range: contentRange,
                    includeCaptureSemantics: includeCaptureSemantics
                )
            let isEmpty = baseContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // HTML document parsing adds one final newline even when the
            // source has none. Encode a real terminal newline explicitly so
            // the parser can distinguish it from that synthetic character.
            let isTerminalBlock = NSMaxRange(paragraphRange) == attributed.length
                && rawParagraph.hasSuffix("\n")
            let content = isTerminalBlock && !isEmpty ? baseContent + "<br>" : baseContent

            if list != nil {
                blocks.append(HTMLBlock(depth: depth, kind: kind, content: content))
            } else if isCode {
                blocks.append(HTMLBlock(depth: -1, kind: "pre", content: content))
            } else if isQuote {
                blocks.append(HTMLBlock(depth: -1, kind: "blockquote", content: content))
            } else if isEmpty {
                blocks.append(HTMLBlock(depth: -1, kind: "blank", content: ""))
            } else {
                blocks.append(HTMLBlock(depth: -1, kind: "p", content: content))
            }
            location = NSMaxRange(paragraphRange)
        }

        var body = ""
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if block.depth >= 0 {
                body += renderHTMLList(blocks, index: &index, depth: block.depth, kind: block.kind)
            } else if block.kind == "pre" {
                var codeLines: [String] = []
                while index < blocks.count, blocks[index].kind == "pre" {
                    codeLines.append(blocks[index].content)
                    index += 1
                }
                body += "<pre><code>\(codeLines.joined(separator: "\n"))</code></pre>"
            } else if block.kind == "blank" {
                body += "<p><br></p>"
                index += 1
            } else if block.kind == "blockquote" {
                body += "<blockquote><p>\(block.content)</p></blockquote>"
                index += 1
            } else {
                body += "<p>\(block.content)</p>"
                index += 1
            }
        }

        return "<html><body>\(body)</body></html>"
    }

    static func rtf(from attributed: NSAttributedString) -> Data? {
        try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    static func plain(fromHTML html: String) -> String {
        guard let plain = prepare(html: html)?.plain else { return html }
        // Keep this legacy helper's Markdown-compatible return value for
        // callers that explicitly ask for plain HTML extraction.  Prepared
        // payloads themselves retain visible bullets ("•") for pasteboard
        // fallbacks.
        return normalizedMarkdown(plain, replacingPrivateUseMarkers: false)
    }

    private static func prepared(attributed: NSAttributedString) -> PreparedRichText {
        prepared(attributed: attributed, includeCaptureSemantics: false)
    }

    private static func prepared(
        attributed: NSAttributedString,
        includeCaptureSemantics: Bool
    ) -> PreparedRichText {
        let canonical = applyingBaseAttributesIfMissing(
            to: normalizedColors(in: normalizedFonts(in: attributed, baseFont: defaultFont), baseColor: defaultColor),
            baseFont: defaultFont,
            baseColor: defaultColor
        )
        let plain = plainText(from: canonical, includeCaptureSemantics: includeCaptureSemantics)
        let payload = RichTextPayload(
            plain: plain,
            html: canonical.length > 0
                ? html(from: canonical, includeCaptureSemantics: includeCaptureSemantics)
                : nil,
            rtf: canonical.length > 0 ? rtf(from: canonical) : nil
        )
        return PreparedRichText(attributed: canonical, payload: payload)
    }

    private static func plainText(
        from attributed: NSAttributedString,
        includeCaptureSemantics: Bool = false
    ) -> String {
        guard attributed.length > 0 else { return "" }

        var result = ""
        var counters: [Int: Int] = [:]
        var location = 0
        while location < attributed.length {
            let paragraphRange = (attributed.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let paragraph = (attributed.string as NSString).substring(with: paragraphRange)
            let hasNewline = paragraph.hasSuffix("\n")
            let contentLength = max(0, paragraphRange.length - (hasNewline ? 1 : 0))
            let content = (paragraph as NSString).substring(with: NSRange(location: 0, length: contentLength))
            let style = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            let isQuote = includeCaptureSemantics && attributed.attribute(
                RichTextSemanticAttributes.quote,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? Bool == true

            if let list = style?.textLists.last {
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                for key in Array(counters.keys) where key > depth {
                    counters.removeValue(forKey: key)
                }
                let ordered = list.markerFormat == .decimal
                let number = counters[depth, default: 1]
                counters[depth] = ordered ? number + 1 : number
                let indent = String(repeating: "  ", count: depth)
                result += indent + (ordered ? "\(number). " : "• ") + content
            } else {
                counters.removeAll()
                result += isQuote ? "> \(content)" : content
            }

            if hasNewline {
                result += "\n"
            }
            location = NSMaxRange(paragraphRange)
        }

        return result.normalizedPlainText()
    }

    private static func renderHTMLList(_ blocks: [HTMLBlock], index: inout Int, depth: Int, kind: String) -> String {
        var result = "<\(kind)>"
        while index < blocks.count {
            let block = blocks[index]
            guard block.depth == depth, block.kind == kind else { break }
            result += "<li>\(block.content)"
            index += 1

            if index < blocks.count, blocks[index].depth > depth {
                let nested = blocks[index]
                result += renderHTMLList(blocks, index: &index, depth: depth + 1, kind: nested.kind)
            }
            result += "</li>"
        }
        result += "</\(kind)>"
        return result
    }

    private static func isMonospacedParagraph(in attributed: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var hasFont = false
        var allMono = true
        attributed.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
            hasFont = true
            guard let font = value as? NSFont else {
                allMono = false
                return
            }
            allMono = allMono && font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        return hasFont && allMono
    }

    private static func htmlInline(
        from attributed: NSAttributedString,
        range: NSRange,
        includeCaptureSemantics: Bool = false
    ) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let text = (attributed.string as NSString).substring(with: subrange)
            var value = escapeHTML(text)
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let link = attributes[.link].flatMap { value -> String? in
                if let url = value as? URL { return url.absoluteString }
                if let url = value as? NSURL { return url.absoluteString }
                return String(describing: value)
            }

            if traits.contains(.monoSpace) { value = "<code>\(value)</code>" }
            if traits.contains(.bold) { value = "<strong>\(value)</strong>" }
            if traits.contains(.italic) { value = "<em>\(value)</em>" }
            if includeCaptureSemantics, attributes[.underlineStyle] != nil {
                value = "<u>\(value)</u>"
            }
            if includeCaptureSemantics, attributes[.strikethroughStyle] != nil {
                value = "<s>\(value)</s>"
            }
            if let link {
                value = "<a href=\"\(escapeHTMLAttribute(link))\">\(value)</a>"
            }
            result += value
        }
        return result
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inlineAttributedString(_ markdown: String) -> NSAttributedString {
        guard #available(macOS 12.0, *) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: defaultFont,
                .foregroundColor: defaultColor
            ])
        }

        do {
            let value = try AttributedString(markdown: markdown, options: {
                var options = AttributedString.MarkdownParsingOptions()
                options.interpretedSyntax = .inlineOnlyPreservingWhitespace
                options.failurePolicy = .returnPartiallyParsedIfPossible
                return options
            }())

            let result = NSMutableAttributedString(attributedString: NSAttributedString(value))
            for run in value.runs {
                let intent = run.inlinePresentationIntent
                let isCode = intent?.contains(.code) == true
                let isBold = intent?.contains(.stronglyEmphasized) == true
                let isItalic = intent?.contains(.emphasized) == true
                var font = isCode
                    ? NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize, weight: isBold ? .bold : .regular)
                    : NSFont.systemFont(ofSize: defaultFont.pointSize, weight: isBold ? .bold : .regular)
                if isItalic {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                result.addAttribute(NSAttributedString.Key.font, value: font, range: NSRange(run.range, in: value))
            }

            return applyingBaseAttributesIfMissing(to: result, baseFont: defaultFont, baseColor: defaultColor)
        } catch {
            return NSAttributedString(string: markdown, attributes: [
                .font: defaultFont,
                .foregroundColor: defaultColor
            ])
        }
    }

    private static func listDepth(in line: String, marker: RichTextListMarkers.Match) -> Int {
        let prefix = line[..<marker.markerRange.lowerBound]
        let spaces = prefix.reduce(into: 0) { result, character in
            result += character == "\t" ? 2 : 1
        }
        return max(0, spaces / 2)
    }

    private static func applyListStyle(to attributed: NSMutableAttributedString, range: NSRange, textLists: [NSTextList], depth: Int) {
        guard range.length > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.textLists = textLists
        style.firstLineHeadIndent = CGFloat(depth * 20)
        style.headIndent = CGFloat((depth + 1) * 20)
        attributed.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// Preserve the legacy output normalisation used by model responses.  It
    /// removes a literal marker only when AppKit already supplied a real list;
    /// capture uses the richer inference routine below.
    private static func normalizedListMarkers(in attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let bulletPattern = "^(?:[\\s\\u00A0]*)(?:[•·◦▪‣\\-*+])(?:[\\s\\u00A0]+)"
        let orderedPattern = "^(?:[\\s\\u00A0]*)(?:(?:\\(?\\d{1,3}[\\).])|(?:\\d{1,3})|(?:[A-Za-z][\\).]))(?:[\\s\\u00A0]+)"
        let bulletRegex = try? NSRegularExpression(pattern: bulletPattern, options: [])
        let orderedRegex = try? NSRegularExpression(pattern: orderedPattern, options: [])

        var rangesToDelete: [NSRange] = []
        var location = 0
        while location < mutable.length {
            let currentString = mutable.string as NSString
            let paragraphRange = currentString.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)

            guard paragraphRange.length > 0,
                  let paragraphStyle = mutable.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle,
                  !paragraphStyle.textLists.isEmpty else {
                continue
            }

            let paragraphText = currentString.substring(with: paragraphRange) as NSString
            let localRange = NSRange(location: 0, length: paragraphText.length)
            let match = bulletRegex?.firstMatch(in: paragraphText as String, options: [], range: localRange)
                ?? orderedRegex?.firstMatch(in: paragraphText as String, options: [], range: localRange)
            if let match, match.range.length > 0 {
                rangesToDelete.append(NSRange(location: paragraphRange.location + match.range.location, length: match.range.length))
            }
        }

        for range in rangesToDelete.reversed() {
            mutable.deleteCharacters(in: range)
        }
        return mutable
    }

    /// Repair list semantics that source applications sometimes flatten into
    /// ordinary paragraphs.  Existing list paragraphs are cleaned of duplicate
    /// literal markers; marker-only paragraphs are promoted to real NSTextList
    /// paragraphs.  A blank/non-list paragraph resets the current list, so two
    /// lists separated by an empty line stay separate.
    private static func normalizedListSemantics(
        in attributed: NSAttributedString,
        inferListMarkers: Bool
    ) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }

        struct Operation {
            let range: NSRange
            let prefixLength: Int
            let depth: Int
            let existingLists: [NSTextList]
            let existingStyle: NSParagraphStyle?
            let isInferred: Bool
        }

        let original = attributed
        var operations: [Operation] = []
        var location = 0
        var listStack: [NSTextList] = []

        while location < original.length {
            let paragraphRange = (original.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let rawParagraph = (original.string as NSString).substring(with: paragraphRange)
            let rawParagraphLength = (rawParagraph as NSString).length
            let contentLength = max(0, rawParagraphLength - (rawParagraph.hasSuffix("\n") ? 1 : 0))
            let content = (rawParagraph as NSString).substring(with: NSRange(location: 0, length: contentLength))
            let style = original.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            let existingLists = style?.textLists ?? []
            let isCode = isMonospacedParagraph(
                in: original,
                range: NSRange(location: paragraphRange.location, length: min(contentLength, paragraphRange.length))
            )
            let quote = original.attribute(
                RichTextSemanticAttributes.quote,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? Bool == true

            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCode || quote {
                listStack.removeAll()
                location = NSMaxRange(paragraphRange)
                continue
            }

            if !existingLists.isEmpty {
                let last = existingLists.last!
                let kind: RichTextListMarkers.Kind = last.markerFormat == .decimal ? .ordered : .unordered
                let match = RichTextListMarkers.match(in: content)
                let prefixLength = match.map { NSMaxRange(NSRange($0.separatorRange, in: content)) }
                    ?? appKitListPrefixLength(in: content, kind: kind)
                operations.append(Operation(
                    range: paragraphRange,
                    prefixLength: prefixLength,
                    depth: max(0, existingLists.count - 1),
                    existingLists: existingLists,
                    existingStyle: style,
                    isInferred: false
                ))
                listStack = existingLists
                location = NSMaxRange(paragraphRange)
                continue
            }

            guard inferListMarkers,
                  let match = RichTextListMarkers.match(in: content) else {
                listStack.removeAll()
                location = NSMaxRange(paragraphRange)
                continue
            }

            let depth = listDepth(in: content, marker: match)
            let listFormat: NSTextList.MarkerFormat = match.kind == .ordered ? .decimal : .disc
            if depth < listStack.count {
                listStack.removeLast(listStack.count - depth)
            }
            if listStack.count == depth {
                listStack.append(NSTextList(markerFormat: listFormat, options: 0))
            } else if listStack[depth].markerFormat != listFormat {
                listStack.removeLast(listStack.count - depth)
                listStack.append(NSTextList(markerFormat: listFormat, options: 0))
            }

            operations.append(Operation(
                range: paragraphRange,
                prefixLength: NSMaxRange(NSRange(match.separatorRange, in: content)),
                depth: depth,
                existingLists: listStack,
                existingStyle: style,
                isInferred: true
            ))
            location = NSMaxRange(paragraphRange)
        }

        guard !operations.isEmpty else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: original)
        var removedCharacters = 0
        for operation in operations {
            let currentLocation = operation.range.location - removedCharacters
            guard currentLocation >= 0, currentLocation <= mutable.length else { continue }
            let currentRange = (mutable.string as NSString).paragraphRange(
                for: NSRange(location: currentLocation, length: 0)
            )
            let deleteLength = min(operation.prefixLength, currentRange.length)
            if deleteLength > 0 {
                mutable.deleteCharacters(in: NSRange(location: currentRange.location, length: deleteLength))
                removedCharacters += deleteLength
            }

            let style: NSMutableParagraphStyle
            if let existingStyle = operation.existingStyle?.mutableCopy() as? NSMutableParagraphStyle {
                style = existingStyle
            } else {
                style = NSMutableParagraphStyle()
            }
            style.textLists = operation.existingLists
            if operation.isInferred {
                style.firstLineHeadIndent = CGFloat(operation.depth * 20)
                style.headIndent = CGFloat((operation.depth + 1) * 20)
            }
            let resultingRange = (mutable.string as NSString).paragraphRange(
                for: NSRange(location: currentRange.location, length: 0)
            )
            if resultingRange.length > 0 {
                mutable.addAttribute(.paragraphStyle, value: style, range: resultingRange)
            }
        }
        return mutable
    }

    private static func appKitListPrefixLength(
        in content: String,
        kind: RichTextListMarkers.Kind
    ) -> Int {
        let marker = kind == .ordered
            ? "(?:\\(?\\d{1,3}[\\).]?)"
            : "(?:[•·◦▪‣\\-*+])"
        guard let regex = try? NSRegularExpression(
            pattern: "^[\\t ]*" + marker + "[\\t ]+",
            options: []
        ) else {
            return 0
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.firstMatch(in: content, options: [], range: range)?.range.length ?? 0
    }

    private static func removingSyntheticFinalNewline(
        from attributed: NSAttributedString,
        sourceHTML: String
    ) -> NSAttributedString {
        guard attributed.string.hasSuffix("\n"),
              !hasExplicitTerminalLineBreak(in: sourceHTML) else {
            return attributed
        }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
        return mutable
    }

    private static func hasExplicitTerminalLineBreak(in html: String) -> Bool {
        // Strip closing block/document tags from the end. A final <br> then
        // unambiguously represents a source newline, including inside the
        // <pre><code>...</code></pre> form used for code blocks.
        var value = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        let closingTag = try? NSRegularExpression(
            pattern: "</(?:html|body|p|div|li|ul|ol|pre|code|blockquote|td|th|h[1-6])\\s*>\\s*$",
            options: [.caseInsensitive]
        )
        while let closingTag,
              let match = closingTag.firstMatch(
                in: value,
                options: [],
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ) {
            guard let range = Range(match.range, in: value) else { break }
            value.removeSubrange(range)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let terminalBreak = try? NSRegularExpression(
            pattern: "<br\\b[^>]*>\\s*$",
            options: [.caseInsensitive]
        )
        return terminalBreak?.firstMatch(
            in: value,
            options: [],
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }

    private static func replacingPrivateUseListMarkers(in attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        var replacements: [NSRange] = []
        var location = 0

        while location < mutable.length {
            let currentString = mutable.string as NSString
            let paragraphRange = currentString.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)

            guard paragraphRange.length > 0 else { continue }
            let paragraphText = currentString.substring(with: paragraphRange)
            guard let markerRange = RichTextListMarkers.markerRange(in: paragraphText),
                  (paragraphText as NSString).substring(with: markerRange) == RichTextListMarkers.slackPrivateUseBullet else {
                continue
            }

            let absoluteMarkerLocation = paragraphRange.location + markerRange.location
            if let font = mutable.attribute(.font, at: absoluteMarkerLocation, effectiveRange: nil) as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                continue
            }
            replacements.append(NSRange(location: absoluteMarkerLocation, length: markerRange.length))
        }

        for range in replacements.reversed() {
            mutable.replaceCharacters(in: range, with: "•")
        }
        return mutable
    }

    private static func normalizedFonts(in attributed: NSAttributedString, baseFont: NSFont) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let fullRange = NSRange(location: 0, length: attributed.length)
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fontManager = NSFontManager.shared

        mutable.beginEditing()
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let replacement: NSFont
            if let font = value as? NSFont {
                let symbolicTraits = font.fontDescriptor.symbolicTraits
                let managerTraits = fontManager.traits(of: font)
                let isBold = symbolicTraits.contains(.bold) || managerTraits.contains(.boldFontMask)
                let isItalic = symbolicTraits.contains(.italic) || managerTraits.contains(.italicFontMask)
                let isMono = symbolicTraits.contains(.monoSpace)
                var candidate = isMono
                    ? NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: isBold ? .bold : .regular)
                    : NSFont.systemFont(ofSize: baseFont.pointSize, weight: isBold ? .bold : .regular)
                if isItalic {
                    candidate = fontManager.convert(candidate, toHaveTrait: .italicFontMask)
                }
                replacement = candidate
            } else {
                replacement = baseFont
            }
            mutable.addAttribute(.font, value: replacement, range: range)
        }
        mutable.endEditing()
        return mutable
    }

    private static func normalizedColors(in attributed: NSAttributedString, baseColor: NSColor) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let fullRange = NSRange(location: 0, length: attributed.length)
        let mutable = NSMutableAttributedString(attributedString: attributed)

        mutable.beginEditing()
        var foregroundRanges: [(range: NSRange, hasLink: Bool)] = []
        mutable.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { _, range, _ in
            let hasLink = mutable.attribute(.link, at: range.location, effectiveRange: nil) != nil
            foregroundRanges.append((range: range, hasLink: hasLink))
        }
        for foreground in foregroundRanges {
            mutable.addAttribute(
                .foregroundColor,
                value: foreground.hasLink ? NSColor.linkColor : baseColor,
                range: foreground.range
            )
        }
        mutable.removeAttribute(.backgroundColor, range: fullRange)
        mutable.endEditing()
        return mutable
    }

    private static func applyingBaseAttributesIfMissing(to attributed: NSAttributedString, baseFont: NSFont, baseColor: NSColor) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let fullRange = NSRange(location: 0, length: attributed.length)
        let mutable = NSMutableAttributedString(attributedString: attributed)

        mutable.beginEditing()
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: baseFont, range: range)
            }
        }
        var missingForegroundRanges: [(range: NSRange, hasLink: Bool)] = []
        mutable.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                let hasLink = mutable.attribute(.link, at: range.location, effectiveRange: nil) != nil
                missingForegroundRanges.append((range: range, hasLink: hasLink))
            }
        }
        for foreground in missingForegroundRanges {
            mutable.addAttribute(
                .foregroundColor,
                value: foreground.hasLink ? NSColor.linkColor : baseColor,
                range: foreground.range
            )
        }
        mutable.endEditing()
        return mutable
    }
}

struct RichTextPasteboardCandidate {
    let itemIndex: Int
    let source: RichTextCaptureSource
    let availableTypes: [String]
    let prepared: PreparedRichText
}

struct RichTextPasteboardObservation {
    let payload: RichTextPayload?
    let prepared: PreparedRichText?
    let source: RichTextCaptureSource?
    let availableTypes: [String]
    /// A content-free signature used only to decide when a source has finished
    /// publishing its pasteboard representations.
    let formatSignature: String
}

enum RichTextPasteboard {
    private static let rtfdType = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
    private static let legacyRTFDType = NSPasteboard.PasteboardType("com.apple.rtfd")
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let utf16PlainTextType = NSPasteboard.PasteboardType("public.utf16-plain-text")

    static func read(from pasteboard: NSPasteboard) -> RichTextPayload? {
        readObservation(from: pasteboard)?.payload
    }

    static func formatSignature(from pasteboard: NSPasteboard) -> String {
        let items = pasteboard.pasteboardItems ?? []
        if items.isEmpty {
            let types = pasteboard.types?.map(\.rawValue) ?? []
            return topLevelSignature(pasteboard, types: types)
        }
        return items.map(itemSignature).joined(separator: "|")
    }

    static func readObservation(from pasteboard: NSPasteboard) -> RichTextPasteboardObservation? {
        let items = pasteboard.pasteboardItems ?? []
        var parsedCandidates: [RichTextPasteboardCandidate] = []
        var allTypes: [String] = []
        var signatures: [String] = []

        for (index, item) in items.enumerated() {
            let types = item.types.map(\.rawValue)
            allTypes.append(contentsOf: types)
            signatures.append(itemSignature(item))
            parsedCandidates.append(contentsOf: candidates(for: item, itemIndex: index, availableTypes: types))
        }

        // Some pasteboard providers expose values through the pasteboard API
        // without materialising NSPasteboardItem objects.  Read those values as
        // one final item, while still requiring the caller to confirm a new
        // changeCount before using it.
        if items.isEmpty {
            let types = pasteboard.types?.map(\.rawValue) ?? []
            allTypes.append(contentsOf: types)
            signatures.append(topLevelSignature(pasteboard, types: types))
            parsedCandidates.append(contentsOf: candidates(for: pasteboard, itemIndex: 0, availableTypes: types))
        }

        guard !parsedCandidates.isEmpty else {
            return RichTextPasteboardObservation(
                payload: nil,
                prepared: nil,
                source: nil,
                availableTypes: Array(Set(allTypes)).sorted(),
                formatSignature: signatures.joined(separator: "|")
            )
        }

        let grouped = Dictionary(grouping: parsedCandidates, by: \.itemIndex)
        let selectedByItem = grouped.keys.sorted().compactMap { itemIndex -> RichTextPasteboardCandidate? in
            guard let itemCandidates = grouped[itemIndex] else { return nil }
            let nonEmpty = itemCandidates.filter {
                !RichTextConverter.comparableText(of: $0.prepared).isEmpty
            }
            let pool = nonEmpty.isEmpty ? itemCandidates : nonEmpty
            guard let richest = pool.max(by: isLessComplete) else { return nil }
            let text = RichTextConverter.comparableText(of: richest.prepared)
            let matching = pool.filter { RichTextConverter.comparableText(of: $0.prepared) == text }
            return RichTextConverter.mergeCompatible(matching) ?? richest
        }

        guard !selectedByItem.isEmpty else {
            return RichTextPasteboardObservation(
                payload: nil,
                prepared: nil,
                source: nil,
                availableTypes: Array(Set(allTypes)).sorted(),
                formatSignature: signatures.joined(separator: "|")
            )
        }

        let combined = combine(selectedByItem.map(\.prepared))
        let source = selectedByItem.first?.source
        return RichTextPasteboardObservation(
            payload: combined.payload,
            prepared: combined,
            source: source,
            availableTypes: Array(Set(allTypes)).sorted(),
            formatSignature: signatures.joined(separator: "|")
        )
    }

    static func merging(
        _ observation: RichTextPasteboardObservation,
        withAccessibility prepared: PreparedRichText
    ) -> RichTextPasteboardObservation {
        guard let basePrepared = observation.prepared else {
            return observation
        }
        let base = RichTextPasteboardCandidate(
            itemIndex: 0,
            source: observation.source ?? .pasteboardPlain,
            availableTypes: observation.availableTypes,
            prepared: basePrepared
        )
        let accessibility = RichTextPasteboardCandidate(
            itemIndex: 0,
            source: .accessibilityAttributed,
            availableTypes: ["AXSelectedTextAttributedString"],
            prepared: prepared
        )
        guard let selected = RichTextConverter.mergeCompatible([base, accessibility]) else {
            return observation
        }
        let source = selected.source
        let types = Array(Set(observation.availableTypes + ["AXSelectedTextAttributedString"])).sorted()
        return RichTextPasteboardObservation(
            payload: selected.prepared.payload,
            prepared: selected.prepared,
            source: source,
            availableTypes: types,
            formatSignature: observation.formatSignature
        )
    }

    private static func isLessComplete(
        _ left: RichTextPasteboardCandidate,
        _ right: RichTextPasteboardCandidate
    ) -> Bool {
        let leftSignature = RichTextConverter.structureSignature(of: left.prepared.attributed)
        let rightSignature = RichTextConverter.structureSignature(of: right.prepared.attributed)
        if leftSignature.structuralScore != rightSignature.structuralScore {
            return leftSignature.structuralScore < rightSignature.structuralScore
        }
        if leftSignature.inlineScore != rightSignature.inlineScore {
            return leftSignature.inlineScore < rightSignature.inlineScore
        }
        if left.prepared.attributed.length != right.prepared.attributed.length {
            return left.prepared.attributed.length < right.prepared.attributed.length
        }
        return sourceRank(left.source) < sourceRank(right.source)
    }

    private static func sourceRank(_ source: RichTextCaptureSource) -> Int {
        switch source {
        case .pasteboardRTF: return 5
        case .pasteboardRTFD: return 4
        case .pasteboardHTML: return 3
        case .pasteboardPlain: return 1
        case .accessibilityAttributed, .accessibilityPlain: return 0
        }
    }

    private static func combine(_ prepared: [PreparedRichText]) -> PreparedRichText {
        guard let first = prepared.first else {
            return RichTextConverter.prepare(markdown: "")
        }
        guard prepared.count > 1 else { return first }

        let mutable = NSMutableAttributedString(attributedString: first.attributed)
        for next in prepared.dropFirst() {
            if mutable.length > 0 {
                if mutable.string.hasSuffix("\n\n") {
                    // The source item already ended with a blank paragraph.
                } else if mutable.string.hasSuffix("\n") {
                    mutable.append(NSAttributedString(string: "\n"))
                } else {
                    mutable.append(NSAttributedString(string: "\n\n"))
                }
            }
            mutable.append(next.attributed)
        }
        return RichTextConverter.prepare(attributed: mutable)
    }

    private static func candidates(
        for item: NSPasteboardItem,
        itemIndex: Int,
        availableTypes: [String]
    ) -> [RichTextPasteboardCandidate] {
        var result: [RichTextPasteboardCandidate] = []
        let html = [
            item.string(forType: .html),
            item.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        ]
        .compactMap { $0 }
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let html,
           let prepared = RichTextConverter.prepareCaptured(html: html) {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardHTML,
                availableTypes: availableTypes,
                prepared: prepared
            ))
        }

        if let rtf = item.data(forType: .rtf),
           let prepared = RichTextConverter.prepare(rtf: rtf, documentType: .rtf, inferListMarkers: true) {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardRTF,
                availableTypes: availableTypes,
                prepared: prepared
            ))
        }
        if let rtfd = rtfdData(from: item),
           let prepared = RichTextConverter.prepare(rtf: rtfd, documentType: .rtfd, inferListMarkers: true) {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardRTFD,
                availableTypes: availableTypes,
                prepared: prepared
            ))
        }

        let plain = [
            item.string(forType: .string),
            item.string(forType: utf8PlainTextType),
            item.string(forType: utf16PlainTextType)
        ]
        .compactMap { $0 }
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardPlain,
                availableTypes: availableTypes,
                prepared: RichTextConverter.prepareCaptured(markdown: plain.normalizedPlainText())
            ))
        }
        return result
    }

    private static func candidates(
        for pasteboard: NSPasteboard,
        itemIndex: Int,
        availableTypes: [String]
    ) -> [RichTextPasteboardCandidate] {
        var result: [RichTextPasteboardCandidate] = []
        let html = [
            pasteboard.string(forType: .html),
            pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        ]
        .compactMap { $0 }
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let html, let prepared = RichTextConverter.prepareCaptured(html: html) {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardHTML,
                availableTypes: availableTypes,
                prepared: prepared
            ))
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let prepared = RichTextConverter.prepare(rtf: rtf, documentType: .rtf, inferListMarkers: true) {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardRTF,
                availableTypes: availableTypes,
                prepared: prepared
            ))
        }
        if let rtfd = rtfdData(from: pasteboard),
           let prepared = RichTextConverter.prepare(rtf: rtfd, documentType: .rtfd, inferListMarkers: true) {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardRTFD,
                availableTypes: availableTypes,
                prepared: prepared
            ))
        }
        let plain = [
            pasteboard.string(forType: .string),
            pasteboard.string(forType: utf8PlainTextType),
            pasteboard.string(forType: utf16PlainTextType)
        ]
        .compactMap { $0 }
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(RichTextPasteboardCandidate(
                itemIndex: itemIndex,
                source: .pasteboardPlain,
                availableTypes: availableTypes,
                prepared: RichTextConverter.prepareCaptured(markdown: plain.normalizedPlainText())
            ))
        }
        return result
    }

    private static func itemSignature(_ item: NSPasteboardItem) -> String {
        item.types.sorted { $0.rawValue < $1.rawValue }.map { type in
            let data = item.data(forType: type)
            let dataLength = data?.count ?? 0
            let dataHash = data?.hashValue ?? 0
            let stringHash = item.string(forType: type)?.hashValue ?? 0
            return "\(type.rawValue):\(dataLength):\(dataHash):\(stringHash)"
        }.joined(separator: ",")
    }

    private static func rtfdData(from item: NSPasteboardItem) -> Data? {
        item.data(forType: rtfdType) ?? item.data(forType: legacyRTFDType)
    }

    private static func rtfdData(from pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: rtfdType) ?? pasteboard.data(forType: legacyRTFDType)
    }

    private static func topLevelSignature(_ pasteboard: NSPasteboard, types: [String]) -> String {
        types.sorted().map { rawValue in
            let type = NSPasteboard.PasteboardType(rawValue)
            let data = pasteboard.data(forType: type)
            let dataLength = data?.count ?? 0
            let dataHash = data?.hashValue ?? 0
            let stringHash = pasteboard.string(forType: type)?.hashValue ?? 0
            return "\(rawValue):\(dataLength):\(dataHash):\(stringHash)"
        }.joined(separator: ",")
    }

    static func write(_ payload: RichTextPayload, to pasteboard: NSPasteboard) {
        let attributed: NSAttributedString? = (payload.rtf == nil || payload.html == nil)
            ? RichTextConverter.attributedString(from: payload)
            : nil
        let rtf = payload.rtf ?? attributed.flatMap(RichTextConverter.rtf(from:))
        let html = payload.html.map(RichTextHTMLSanitizer.sanitize) ?? attributed.flatMap(RichTextConverter.html(from:))

        pasteboard.clearContents()

        if let rtf {
            pasteboard.setData(rtf, forType: .rtf)
        }
        if let html, let data = html.data(using: .utf8) {
            pasteboard.setData(data, forType: .html)
        }

        // Keep the canonical plain fallback with visible bullets/numbers.  The
        // HTML and RTF representations carry true list semantics; this string
        // is for applications that understand neither representation.
        pasteboard.setString(payload.plain, forType: .string)
    }
}
