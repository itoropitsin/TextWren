import SwiftUI
import AppKit
import Foundation

struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    let placeholder: String
    let prepared: PreparedRichText?

    private var baseFont: NSFont {
        NSFont.preferredFont(forTextStyle: .body)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    init(markdown: String, placeholder: String, prepared: PreparedRichText? = nil) {
        self.markdown = markdown
        self.placeholder = placeholder
        self.prepared = prepared
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.font = baseFont
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let isPlaceholder = markdown.isEmpty
        let content = isPlaceholder ? placeholder : markdown

        if context.coordinator.lastContent == content,
           context.coordinator.lastWasPlaceholder == isPlaceholder,
           context.coordinator.lastPreparedPayload == prepared?.payload {
            return
        }
        context.coordinator.lastContent = content
        context.coordinator.lastWasPlaceholder = isPlaceholder
        context.coordinator.lastPreparedPayload = prepared?.payload

        if isPlaceholder {
            textView.textStorage?.setAttributedString(
                NSAttributedString(
                    string: content,
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: baseFont
                    ]
                )
            )
            return
        }

        if let prepared {
            textView.textStorage?.setAttributedString(
                RichTextConverter.displayAttributedString(from: prepared)
            )
        } else if #available(macOS 12.0, *) {
            let attributed = RichTextConverter.attributedString(fromMarkdown: content)
            textView.textStorage?.setAttributedString(
                RichTextConverter.displayAttributedString(from: attributed)
            )
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: RichTextConverter.normalizedMarkdown(content)))
        }
    }

    final class Coordinator {
        var lastContent: String?
        var lastWasPlaceholder: Bool = false
        var lastPreparedPayload: RichTextPayload?
    }
}

/// Editable source field that keeps the visible text and its semantic
/// formatting together.  It deliberately uses the same pasteboard helper as
/// the output buttons so a link never becomes just its visible label while it
/// is being edited in the main window.
struct RichTextEditor: NSViewRepresentable {
    @Binding var prepared: PreparedRichText
    let onChange: (_ oldText: String, _ newValue: PreparedRichText) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = RichTextInputTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        context.coordinator.isApplyingExternalValue = true
        textView.textStorage?.setAttributedString(prepared.attributed)
        context.coordinator.isApplyingExternalValue = false
        context.coordinator.lastPayload = prepared.payload
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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? RichTextInputTextView else { return }
        context.coordinator.parent = self

        // A delegate callback already placed this value in the editor.  Avoid
        // replacing the text storage again, which would move the caret and
        // break the normal typing/undo experience.
        guard context.coordinator.lastPayload != prepared.payload else { return }
        context.coordinator.isApplyingExternalValue = true
        let selectedRange = textView.selectedRange()
        textView.textStorage?.setAttributedString(prepared.attributed)
        textView.setSelectedRange(NSRange(
            location: min(selectedRange.location, textView.string.utf16.count),
            length: 0
        ))
        context.coordinator.isApplyingExternalValue = false
        context.coordinator.lastPayload = prepared.payload
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        fileprivate weak var textView: RichTextInputTextView?
        var lastPayload: RichTextPayload?
        var isApplyingExternalValue = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView,
                  let attributed = textView.textStorage else { return }
            let oldText = parent.prepared.plain
            let prepared = RichTextConverter.prepare(attributed: attributed)
            lastPayload = prepared.payload
            parent._prepared.wrappedValue = prepared
            parent.onChange(oldText, prepared)
        }
    }
}

private final class RichTextInputTextView: NSTextView {
    override func paste(_ sender: Any?) {
        guard let payload = RichTextPasteboard.read(from: NSPasteboard.general) else {
            super.paste(sender)
            return
        }

        // Use the rich representation only when it was actually supplied by
        // the source application.  A plain clipboard value must retain the
        // old TextEditor behaviour: Markdown-looking characters remain
        // ordinary text and never create a guessed link.  Rich input is
        // normalized through the same converter so source fonts and colours
        // are discarded while links, lists and emphasis survive.
        let prepared: PreparedRichText
        if let html = payload.html, let htmlPrepared = RichTextConverter.prepare(html: html) {
            prepared = htmlPrepared
        } else if let rtf = payload.rtf,
                  let parsed = try? NSAttributedString(
                    data: rtf,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                  ) {
            prepared = RichTextConverter.prepare(attributed: parsed)
        } else {
            prepared = RichTextConverter.prepare(
                attributed: NSAttributedString(string: payload.plain.normalizedPlainText())
            )
        }

        guard prepared.attributed.length > 0 else { return }

        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: prepared.plain) else { return }
        textStorage?.replaceCharacters(in: range, with: prepared.attributed)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + prepared.attributed.length, length: 0))
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else {
            super.copy(sender)
            return
        }

        let selection = attributedString().attributedSubstring(from: range)
        let prepared = RichTextConverter.prepare(attributed: selection)
        RichTextPasteboard.write(prepared.payload, to: NSPasteboard.general)
    }
}
