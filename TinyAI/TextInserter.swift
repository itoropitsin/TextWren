import AppKit
import ApplicationServices

/// A copy of every item and type on a pasteboard, so TinyAI can put the
/// user's clipboard back after it borrowed it for a paste or a copy.
struct PasteboardSnapshot {
    private enum Value {
        case data(Data)
        case string(String)
        case plist(Data)
    }

    private let items: [[NSPasteboard.PasteboardType: Value]]

    init(_ pasteboard: NSPasteboard) {
        var captured: [[NSPasteboard.PasteboardType: Value]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var values: [NSPasteboard.PasteboardType: Value] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = .data(data)
                } else if let string = item.string(forType: type) {
                    values[type] = .string(string)
                } else if let plist = item.propertyList(forType: type),
                          let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                    values[type] = .plist(data)
                }
            }
            captured.append(values)
        }
        items = captured
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { values in
            let item = NSPasteboardItem()
            for (type, value) in values {
                switch value {
                case .data(let data):
                    item.setData(data, forType: type)
                case .string(let string):
                    item.setString(string, forType: type)
                case .plist(let data):
                    if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                        item.setPropertyList(plist, forType: type)
                    }
                }
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

extension AccessibilityElements {
    /// The focused control of the frontmost application, or its focused
    /// window when the control is not exposed.
    static func focusedElement() -> AXUIElement? {
        let systemWideElement = systemWide()

        var focusedElementValue: AnyObject?
        if AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
           let value = focusedElementValue, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp, CFGetTypeID(app) == AXUIElementGetTypeID() else {
            return nil
        }

        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }
        return (window as! AXUIElement)
    }

    static func replacementTarget(for element: AXUIElement) -> TextReplacementTarget? {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        guard processIdentifier != 0 else { return nil }
        return TextReplacementTarget(element: element, processIdentifier: processIdentifier)
    }

    static func focusedReplacementTarget() -> TextReplacementTarget? {
        guard let element = focusedElement() else { return nil }
        return replacementTarget(for: element)
    }
}

/// Pastes text into another application with the clipboard and a synthetic
/// ⌘V, after checking that the intended application is frontmost.
enum TextInserter {
    enum InsertError: LocalizedError, Equatable {
        case targetUnavailable
        case focusLost

        var errorDescription: String? {
            switch self {
            case .targetUnavailable:
                return "The original text application is no longer available."
            case .focusLost:
                return "The original text application is no longer focused; nothing was replaced."
            }
        }
    }

    /// Delay before the clipboard is restored.  Applications read the
    /// pasteboard asynchronously after ⌘V, so restoring immediately would
    /// paste the old contents.
    static let restoreDelay: TimeInterval = 0.6

    /// Paste `payload` into `target`.  When `target` is nil the text goes to
    /// whichever application is frontmost.  With `restoreClipboard`, the
    /// previous clipboard comes back unless something else changed it.
    static func insert(
        _ payload: RichTextPayload,
        into target: TextReplacementTarget?,
        restoreClipboard: Bool,
        completion: @escaping (Result<Void, InsertError>) -> Void
    ) {
        let application: NSRunningApplication?
        if let target {
            guard let running = NSRunningApplication(processIdentifier: target.processIdentifier) else {
                completion(.failure(.targetUnavailable))
                return
            }
            application = running
        } else {
            application = nil
        }

        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? PasteboardSnapshot(pasteboard) : nil
        var replacementPayload = payload
        replacementPayload.replacementTarget = target
        RichTextPasteboard.write(replacementPayload, to: pasteboard)
        let expectedChangeCount = pasteboard.changeCount

        // Restore focus to the app and only paste after it is frontmost. This
        // keeps a paste from landing in whichever app the user clicked meanwhile.
        if let target, let application,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            application.activate(options: [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let target {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      pasteboard.changeCount == expectedChangeCount else {
                    completion(.failure(.focusLost))
                    return
                }
                // Re-focus the exact control captured earlier when the source
                // application exposes that attribute. The frontmost-process
                // check above remains the hard safety boundary.
                _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }

            postCommandV()

            if let snapshot {
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    // Never overwrite something the user copied meanwhile.
                    if pasteboard.changeCount == expectedChangeCount {
                        snapshot.restore(to: pasteboard)
                    }
                }
            }
            completion(.success(()))
        }
    }

    static func copy(_ text: String) {
        let payload = RichTextConverter.prepare(markdown: text).payload
        RichTextPasteboard.write(payload, to: .general)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
