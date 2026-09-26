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

    init(plain: String, html: String?, rtf: Data?, replacementTarget: TextReplacementTarget? = nil) {
        self.plain = plain
        self.html = html
        self.rtf = rtf
        self.replacementTarget = replacementTarget
    }

    static func == (lhs: RichTextPayload, rhs: RichTextPayload) -> Bool {
        lhs.plain == rhs.plain && lhs.html == rhs.html && lhs.rtf == rhs.rtf
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
    let listGroups: [String]
    let links: [String]
    let inlineTraits: [String]

    // Keep the old memberwise construction available to internal callers and
    // tests that predate list-group validation.
    init(
        blocks: [String],
        listGroups: [String] = [],
        links: [String],
        inlineTraits: [String]
    ) {
        self.blocks = blocks
        self.listGroups = listGroups
        self.links = links
        self.inlineTraits = inlineTraits
    }
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

        // Source-app typography and colours live in tag attributes.  Only
        // rewrite inside start tags, so text such as "Hair color: brown;"
        // or a CSS snippet in a code block is never touched.
        return replacingMatches(in: result, pattern: "<[a-zA-Z][^>]*>", options: []) { tag in
            sanitizedStartTag(tag)
        }
    }

    /// Remove `face`/`color` attributes and typography/colour declarations
    /// from `style`, keeping semantic styles such as bold and italic.
    private static func sanitizedStartTag(_ tag: String) -> String {
        var result = replacingRegex(
            in: tag,
            pattern: "\\s(?:face|color)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: [.caseInsensitive]
        )
        result = replacingMatches(
            in: result,
            pattern: "\\sstyle\\s*=\\s*(\"[^\"]*\"|'[^']*')",
            options: [.caseInsensitive]
        ) { attribute in
            guard let quoteIndex = attribute.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
                return attribute
            }
            let quote = attribute[quoteIndex]
            let value = attribute[attribute.index(after: quoteIndex)..<attribute.index(before: attribute.endIndex)]
            let kept = value
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { declaration in
                    guard !declaration.isEmpty else { return false }
                    let property = declaration
                        .split(separator: ":", maxSplits: 1)
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() ?? ""
                    return !strippedStyleProperties.contains(property)
                }
            guard !kept.isEmpty else { return "" }
            return " style=\(quote)\(kept.joined(separator: "; "))\(quote)"
        }
        return result
    }

    private static let strippedStyleProperties: Set<String> = [
        "font-family", "font-size", "color", "background-color"
    ]

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
            pattern: "(<li\\b[^>]*>(?:(?!<(?:pre|code)\\b)(?:\\s|&nbsp;|<[^>]+>))*)(" + markerPattern + ")((?:<[^>]+>)*)(?:[ \\t]|&nbsp;)+((?:<[^>]+>)*)",
            with: "$1$3$4",
            options: [.caseInsensitive]
        )

        // Clean up empty wrappers that may remain after removing the bullet glyph.
        // Run this more than once so nested wrappers are removed from the inside out.
        // Only truly empty pairs are removed: whitespace-only spans carry the
        // space between styled words (Google Docs, Slack).
        let emptyInlineWrapperPattern = "<(strong|b|span|em|i|u|s|del)\\b[^>]*></\\1>"
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
        let followingWhitespace = "(?=(?:(?:<[^>]+>)*)(?:[ \\t]|&nbsp;))"
        return replacingRegex(
            in: html,
            pattern: blockStartPattern + markerPattern + followingWhitespace,
            with: "$1•",
            options: [.caseInsensitive]
        )
    }

    private static func replacingRegex(in input: String, pattern: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = RegexCache.regex(pattern, options: options) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }

    static func replacingMatches(
        in input: String,
        pattern: String,
        options: NSRegularExpression.Options,
        transform: (String) -> String
    ) -> String {
        guard let regex = RegexCache.regex(pattern, options: options) else { return input }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        for match in matches {
            result += nsInput.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(nsInput.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += nsInput.substring(from: cursor)
        return result
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

    /// Prepare Markdown exactly once.  The resulting attributed string is the
    /// one shown in the UI; its HTML/RTF siblings are used for pasteboard I/O.
    static func prepare(markdown: String) -> PreparedRichText {
        let attributed = attributedString(fromMarkdown: markdown)
        return prepared(attributed: attributed)
    }

    /// Prepare an attributed selection supplied by Accessibility or another
    /// native editor.  Normalize it through the same path as HTML/RTF so the
    /// plain fallback receives visible list markers while the canonical rich
    /// representations keep real NSTextList semantics.
    static func prepare(attributed: NSAttributedString) -> PreparedRichText {
        let withPrivateMarkers = replacingPrivateUseListMarkers(in: attributed)
        let withoutDuplicateMarkers = normalizedListMarkers(in: withPrivateMarkers)
        let withSemanticFonts = normalizedFonts(in: withoutDuplicateMarkers, baseFont: defaultFont)
        let canonical = applyingBaseAttributesIfMissing(
            to: normalizedColors(in: withSemanticFonts, baseColor: defaultColor),
            baseFont: defaultFont,
            baseColor: defaultColor
        )
        return prepared(attributed: canonical)
    }

    /// Prepare a sanitized HTML response.  A non-HTML response is rejected so
    /// callers can use the Markdown/text fallback deliberately.
    static func prepare(html: String) -> PreparedRichText? {
        let sanitized = RichTextHTMLSanitizer.sanitize(html)
        guard RichTextHTMLSanitizer.isLikelyHTML(sanitized),
              let data = sanitized.data(using: .utf8),
              let parsed = try? NSAttributedString(
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
              ) else {
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
        let prepared = prepared(attributed: canonical)
        let html = prepared.payload.html.map {
            preservingOriginalLinkDestinations(in: $0, sourceHTML: sanitized)
        }
        let payload = RichTextPayload(
            plain: prepared.plain,
            html: html,
            rtf: prepared.payload.rtf
        )
        return PreparedRichText(attributed: prepared.attributed, payload: payload)
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
            let prepared = prepare(attributed: parsed)
            if !prepared.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || payload.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return prepared
            }
        }

        // A payload with no usable rich representation came from ordinary
        // text (or from a malformed rich clipboard item). Keep it literal;
        // parsing Markdown here would invent hidden link destinations that
        // the source application never supplied.
        return prepare(
            attributed: NSAttributedString(string: payload.plain.normalizedPlainText())
        )
    }

    static func attributedString(from payload: RichTextPayload) -> NSAttributedString {
        prepare(payload: payload).attributed
    }

    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
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
            } else if let match = RichTextListMarkers.match(in: line) {
                let body = String(line[match.separatorRange.upperBound...])
                result.append(inlineAttributedString(body))
                let depth = listDepth(in: line, marker: match)
                let markerFormat: NSTextList.MarkerFormat = match.kind == .ordered ? .decimal : .disc

                // Keep one NSTextList instance for a contiguous run of items.
                // Recreating it for every line produces a different list id in
                // RTF. Slack then treats the first item as a paragraph when it
                // pastes the result into an existing editor selection.
                let requiredListCount = depth + 1
                if listStack.count > requiredListCount {
                    listStack.removeLast(listStack.count - requiredListCount)
                }
                if listStack.count < requiredListCount {
                    while listStack.count < requiredListCount {
                        listStack.append(NSTextList(markerFormat: markerFormat, options: 0))
                    }
                } else if listStack[depth].markerFormat != markerFormat {
                    listStack.removeLast(listStack.count - depth)
                    listStack.append(NSTextList(markerFormat: markerFormat, options: 0))
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

    /// Return true only when the attributed text carries formatting that is
    /// otherwise invisible in its plain string.  A generated HTML wrapper is
    /// not enough: ordinary text and hand-written Markdown must continue to
    /// use the existing text request path.
    static func containsSemanticFormatting(in attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }

        var found = false
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, range, stop in
            if attributes[.link] != nil {
                found = true
                stop.pointee = true
                return
            }

            if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
               !style.textLists.isEmpty {
                found = true
                stop.pointee = true
                return
            }

            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) || traits.contains(.italic) || traits.contains(.monoSpace) {
                    found = true
                    stop.pointee = true
                }
            }
        }
        return found
    }

    /// Return the canonical HTML input for a model only when it contains
    /// semantic formatting.  The caller can use the existing Markdown/text
    /// request path for plain input.
    static func modelHTML(from prepared: PreparedRichText) -> String? {
        guard containsSemanticFormatting(in: prepared.attributed),
              let html = prepared.payload.html?.trimmingCharacters(in: .whitespacesAndNewlines),
              !html.isEmpty else {
            return nil
        }
        return html
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

    static func structureSignature(of attributed: NSAttributedString) -> RichTextStructureSignature {
        var blocks: [String] = []
        var listGroupTokens: [String] = []
        var listGroups: [ObjectIdentifier: Int] = [:]
        var nextListGroup = 0
        var inlineTraits: [String] = []
        var previousParagraphWasCode = false
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
            let isCodeParagraph = style?.textLists.isEmpty != false
                && attributed.attribute(.font, at: paragraphRange.location, effectiveRange: nil)
                    .flatMap { ($0 as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) } == true

            if let list = style?.textLists.last {
                let kind = list.markerFormat == .decimal ? "ordered" : "unordered"
                let depth = max(1, style?.textLists.count ?? 1)
                let objectID = ObjectIdentifier(list)
                let group = listGroups[objectID] ?? {
                    let value = nextListGroup
                    nextListGroup += 1
                    listGroups[objectID] = value
                    return value
                }()
                blocks.append("list:\(kind):\(depth):\(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "item")")
                listGroupTokens.append("\(kind):\(depth):group\(group)")
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append("blank")
                listGroupTokens.append("none")
            } else {
                let block = isCodeParagraph ? "code" : "paragraph"
                // Adjacent monospaced paragraphs are one code block for the
                // purpose of validation; AppKit may split or merge their line
                // ranges while round-tripping HTML/RTF.
                if block != "code" || blocks.last != "code" {
                    blocks.append(block)
                    listGroupTokens.append("none")
                }
            }

            // Preserve the order of semantic font runs within each paragraph.
            // A separator between paragraphs catches a bold/italic span moved
            // to a different paragraph while remaining insensitive to changed
            // word lengths after translation. Adjacent code paragraphs are
            // intentionally coalesced for the same round-trip tolerance used
            // by `blocks` above.
            if contentLength > 0 {
                let contentRange = NSRange(location: paragraphRange.location, length: contentLength)
                var paragraphTraits: [String] = []
                attributed.enumerateAttribute(.font, in: contentRange, options: []) { value, _, _ in
                    guard let font = value as? NSFont else { return }
                    let traits = font.fontDescriptor.symbolicTraits
                    var parts: [String] = []
                    if traits.contains(.monoSpace) { parts.append("mono") }
                    if traits.contains(.bold) { parts.append("bold") }
                    if traits.contains(.italic) { parts.append("italic") }
                    let key = parts.isEmpty ? "plain" : parts.joined(separator: "+")
                    if paragraphTraits.last != key {
                        paragraphTraits.append(key)
                    }
                }

                if !paragraphTraits.isEmpty {
                    if isCodeParagraph && previousParagraphWasCode {
                        for key in paragraphTraits where inlineTraits.last != key {
                            inlineTraits.append(key)
                        }
                    } else {
                        if !inlineTraits.isEmpty { inlineTraits.append("|") }
                        inlineTraits.append(contentsOf: paragraphTraits)
                    }
                }
            }
            previousParagraphWasCode = isCodeParagraph
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

        return RichTextStructureSignature(
            blocks: blocks,
            listGroups: listGroupTokens,
            links: links,
            inlineTraits: inlineTraits
        )
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
            let isCode = isMonospacedParagraph(in: attributed, range: contentRange)
            let baseContent = isCode
                ? escapeHTML((attributed.string as NSString).substring(with: contentRange))
                : htmlInline(from: attributed, range: contentRange)
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

    /// Return whether an attributed selection contains text that is useful to
    /// translate.  URLs, domains, file paths and monospaced code are carried
    /// through unchanged; they must not cause a needless model request (or
    /// influence automatic language detection) when they are the whole
    /// selection.
    static func containsHumanReadableProse(in attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }

        var visible = ""
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                return
            }
            visible += (attributed.string as NSString).substring(with: range)
        }

        // Strip URL/domain/path-shaped tokens before looking for words. Keep
        // ordinary linked labels such as "Read the guide" so they remain
        // translatable, while a selection containing only a link is a no-op.
        if let regex = try? NSRegularExpression(
            pattern: "(?i)\\b(?:https?://|ftp://|www\\.)\\S+|\\b(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(?:/\\S*)?|(?<!\\w)/[^\\s]+",
            options: []
        ) {
            let range = NSRange(visible.startIndex..<visible.endIndex, in: visible)
            visible = regex.stringByReplacingMatches(in: visible, options: [], range: range, withTemplate: " ")
        }

        let technicalPunctuation = CharacterSet(charactersIn: "/\\=<>()[\\]{}")
        for token in visible.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token).trimmingCharacters(in: .punctuationCharacters)
            let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 2 else { continue }
            if word.unicodeScalars.contains(where: { technicalPunctuation.contains($0) }) {
                continue
            }
            return true
        }
        return false
    }

    /// NSTextView does not draw NSTextList markers for a non-editable text
    /// view. Add display-only markers while keeping the canonical attributed
    /// string unchanged so HTML/RTF/Replace never receive duplicate bullets.
    static func displayAttributedString(from prepared: PreparedRichText) -> NSAttributedString {
        displayAttributedString(from: prepared.attributed)
    }

    static func displayAttributedString(from attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        var counters: [Int: Int] = [:]
        var activeLists: [Int: ObjectIdentifier] = [:]
        var insertions: [(location: Int, text: String, attributes: [NSAttributedString.Key: Any])] = []
        var location = 0

        while location < attributed.length {
            let paragraphRange = (attributed.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let style = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            if let list = style?.textLists.last {
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                for key in Array(counters.keys) where key > depth {
                    counters.removeValue(forKey: key)
                }
                for key in Array(activeLists.keys) where key > depth {
                    activeLists.removeValue(forKey: key)
                }

                let listID = ObjectIdentifier(list)
                if activeLists[depth] != listID {
                    counters[depth] = 1
                    activeLists[depth] = listID
                }
                let ordered = list.markerFormat == .decimal
                let number = counters[depth, default: 1]
                counters[depth] = ordered ? number + 1 : number
                let marker = ordered ? "\(number)." : "•"
                let attributes = attributed.attributes(at: paragraphRange.location, effectiveRange: nil)
                insertions.append((paragraphRange.location, "\(marker) ", attributes))
            } else {
                counters.removeAll()
                activeLists.removeAll()
            }
            location = NSMaxRange(paragraphRange)
        }

        for insertion in insertions.reversed() {
            mutable.insert(
                NSAttributedString(string: insertion.text, attributes: insertion.attributes),
                at: insertion.location
            )
        }
        return mutable
    }

    private static func prepared(attributed: NSAttributedString) -> PreparedRichText {
        let canonical = applyingBaseAttributesIfMissing(
            to: normalizedColors(in: normalizedFonts(in: attributed, baseFont: defaultFont), baseColor: defaultColor),
            baseFont: defaultFont,
            baseColor: defaultColor
        )
        let plain = plainText(from: canonical)
        let payload = RichTextPayload(
            plain: plain,
            html: canonical.length > 0 ? html(from: canonical) : nil,
            rtf: canonical.length > 0 ? rtf(from: canonical) : nil
        )
        return PreparedRichText(attributed: canonical, payload: payload)
    }

    /// AppKit's HTML importer canonicalizes some URL strings (for example,
    /// `https://example.com` becomes `https://example.com/`). Restore the
    /// exact source destination for every generated link that points to the
    /// same URL.  Links are matched by URL, not by position: the generator
    /// writes one `<a>` per attribute run (a partly bold link becomes two)
    /// and the importer can drop anchors, so positional matching would give
    /// later links the wrong destination.
    static func preservingOriginalLinkDestinations(in generatedHTML: String, sourceHTML: String) -> String {
        var sourceByKey: [String: String] = [:]
        for destination in linkDestinations(in: sourceHTML) {
            let decoded = decodeHTMLAttribute(destination)
            let key = linkMatchKey(decoded)
            // An ambiguous key (two different sources, same URL) keeps the
            // importer's value rather than guessing.
            if let existing = sourceByKey[key], existing != decoded {
                sourceByKey[key] = ""
            } else {
                sourceByKey[key] = decoded
            }
        }
        guard !sourceByKey.isEmpty else { return generatedHTML }

        return RichTextHTMLSanitizer.replacingMatches(
            in: generatedHTML,
            pattern: "(<a\\b[^>]*?\\bhref\\s*=\\s*\")([^\"]*)(\")",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) { anchor in
            guard let hrefStart = anchor.range(of: "href", options: .caseInsensitive),
                  let open = anchor[hrefStart.upperBound...].firstIndex(of: "\""),
                  let close = anchor[anchor.index(after: open)...].firstIndex(of: "\"") else {
                return anchor
            }
            let generated = decodeHTMLAttribute(String(anchor[anchor.index(after: open)..<close]))
            guard let source = sourceByKey[linkMatchKey(generated)], !source.isEmpty else {
                return anchor
            }
            return String(anchor[...open]) + escapeHTMLAttribute(source) + String(anchor[close...])
        }
    }

    /// Comparison key that ignores the canonicalization AppKit applies:
    /// case of scheme and host, a bare root slash, and percent-encoding.
    private static func linkMatchKey(_ destination: String) -> String {
        var value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.removingPercentEncoding ?? value
        if let components = URLComponents(string: destination.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = components.scheme,
           let host = components.host {
            let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
            var key = "\(scheme.lowercased())://\(host.lowercased())"
            if let port = components.port { key += ":\(port)" }
            key += path == "/" ? "" : path
            if let query = components.percentEncodedQuery { key += "?" + (query.removingPercentEncoding ?? query) }
            if let fragment = components.percentEncodedFragment { key += "#" + (fragment.removingPercentEncoding ?? fragment) }
            return key
        }
        return value
    }

    private static func decodeHTMLAttribute(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func linkDestinations(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\b[^>]*?\\bhref\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            for index in 1...3 {
                if let valueRange = Range(match.range(at: index), in: html) {
                    return String(html[valueRange])
                }
            }
            return nil
        }
    }

    private static func plainText(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }

        var result = ""
        var counters: [Int: Int] = [:]
        var activeLists: [Int: ObjectIdentifier] = [:]
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

            if let list = style?.textLists.last {
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                for key in Array(counters.keys) where key > depth {
                    counters.removeValue(forKey: key)
                }
                for key in Array(activeLists.keys) where key > depth {
                    activeLists.removeValue(forKey: key)
                }

                // Ordered numbering belongs to a concrete NSTextList. Reset
                // the counter when a list changes type or starts after a
                // paragraph; otherwise a sequence such as "1. one", "- two",
                // "1. three" would incorrectly render the last item as "2.".
                let listID = ObjectIdentifier(list)
                if activeLists[depth] != listID {
                    counters[depth] = 1
                    activeLists[depth] = listID
                }
                let ordered = list.markerFormat == .decimal
                let number = counters[depth, default: 1]
                counters[depth] = ordered ? number + 1 : number
                let indent = String(repeating: "  ", count: depth)
                result += indent + (ordered ? "\(number). " : "• ") + content
            } else {
                counters.removeAll()
                activeLists.removeAll()
                result += content
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

            // A nested run may switch between unordered and ordered lists, and
            // malformed/hand-authored Markdown can jump more than one indent
            // level. Consume every deeper run here rather than assuming the
            // next depth is exactly `depth + 1`; that assumption used to emit
            // an empty list and leave the real items outside their parent.
            while index < blocks.count, blocks[index].depth > depth {
                let nested = blocks[index]
                let nestedIndex = index
                result += renderHTMLList(blocks, index: &index, depth: nested.depth, kind: nested.kind)
                if index == nestedIndex {
                    // Keep the renderer total even if a future block kind is
                    // added without a matching renderer.
                    break
                }
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

    private static func htmlInline(from attributed: NSAttributedString, range: NSRange) -> String {
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

enum RichTextPasteboard {
    static func read(from pasteboard: NSPasteboard) -> RichTextPayload? {
        let rtf = pasteboard.data(forType: .rtf)
        let rawHTML = pasteboard.string(forType: .html)
            ?? pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        if let rawHTML,
           let prepared = RichTextConverter.prepare(html: rawHTML) {
            // Keep all three representations from the same normalized
            // attributed string.  Reusing the source application's RTF here
            // would let its fonts, weights, and paragraph metadata leak into
            // a later Replace even though the HTML has already been cleaned.
            return prepared.payload
        }

        // Some native editors publish RTF together with HTML that AppKit
        // cannot parse completely. Preserve the native formatting before
        // falling back to a plain string in that case.
        if let rtf {
            let prepared = RichTextConverter.prepare(payload: RichTextPayload(plain: "", html: nil, rtf: rtf))
            if !prepared.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return prepared.payload
            }
        }

        if let plainString = pasteboard.string(forType: .string) {
            return RichTextPayload(
                plain: RichTextConverter.normalizedMarkdown(plainString.normalizedPlainText()),
                html: nil,
                rtf: rtf
            )
        }

        return nil
    }

    static func write(_ payload: RichTextPayload, to pasteboard: NSPasteboard) {
        let attributed: NSAttributedString? = (payload.rtf == nil || payload.html == nil)
            ? RichTextConverter.attributedString(from: payload)
            : nil
        let rtf = payload.rtf ?? attributed.flatMap(RichTextConverter.rtf(from:))
        let html = payload.html.map(RichTextHTMLSanitizer.sanitize) ?? attributed.flatMap(RichTextConverter.html(from:))

        // Publish all representations on one item. Web editors can choose the
        // HTML representation while native editors can choose RTF, without
        // seeing separate clipboard items or mixing unrelated selections.
        let item = NSPasteboardItem()
        if let html, let data = html.data(using: .utf8) {
            item.setData(data, forType: .html)
        }
        pasteboard.clearContents()
        if let rtf {
            item.setData(rtf, forType: .rtf)
        }

        // Keep the canonical plain fallback with visible bullets/numbers.  The
        // HTML and RTF representations carry true list semantics; this string
        // is for applications that understand neither representation.
        item.setString(payload.plain, forType: .string)
        pasteboard.writeObjects([item])
    }
}

/// Compiled regular expressions, keyed by pattern and options.  The rich
/// text pipeline runs the same patterns on every copy and response.
enum RegexCache {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    nonisolated static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[key] = regex
        return regex
    }
}
