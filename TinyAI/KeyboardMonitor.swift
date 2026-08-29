import Cocoa
import Carbon
import ApplicationServices
import Combine
import os

enum PopupHotkeyPressMode: String, CaseIterable, Identifiable {
    case singlePress
    case doublePress

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singlePress:
            return "Single press"
        case .doublePress:
            return "Double press"
        }
    }
}

struct ShortcutModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(eventFlags: CGEventFlags) {
        var result: ShortcutModifiers = []
        if eventFlags.contains(.maskCommand) { result.insert(.command) }
        if eventFlags.contains(.maskShift) { result.insert(.shift) }
        if eventFlags.contains(.maskAlternate) { result.insert(.option) }
        if eventFlags.contains(.maskControl) { result.insert(.control) }
        self = result
    }

    init(modifierFlags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        if modifierFlags.contains(.command) { result.insert(.command) }
        if modifierFlags.contains(.shift) { result.insert(.shift) }
        if modifierFlags.contains(.option) { result.insert(.option) }
        if modifierFlags.contains(.control) { result.insert(.control) }
        self = result
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    var displaySymbols: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

struct KeyboardShortcut: Equatable {
    var keyCode: Int64
    var modifiers: ShortcutModifiers

    var displayString: String {
        "\(modifiers.displaySymbols)\(KeyboardShortcut.displayKey(for: keyCode))"
    }

    private static func displayKey(for keyCode: Int64) -> String {
        switch keyCode {
        case 36: return "↩︎"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            break
        }

        let table: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            50: "`"
        ]

        return table[keyCode] ?? "Key \(keyCode)"
    }
}

class KeyboardMonitor: ObservableObject {
    var onPopupHotkey: ((RichTextPayload) -> Void)?
    @Published var isCustomActionHotkeysEnabled: Bool = false
    @Published var customActionHotkey: Int?
    @Published var popupHotkey: KeyboardShortcut
    @Published var popupHotkeyPressMode: PopupHotkeyPressMode
    
    private var lastPopupHotkeyPressTime: Date?
    private let doublePressInterval: TimeInterval = 0.5
    private var pendingDoublePressPasteboardChangeCount: Int?
    private let pasteboardPollInterval: TimeInterval = 0.01
    private let pasteboardCopyTimeout: TimeInterval = 1.0
    private let pasteboardStabilityWindow: TimeInterval = 0.10
    private(set) var globalMonitoringEnabled: Bool
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapSetupAttempted = false
    private var lastPermissionState: Bool
    private var isProcessing: Bool = false // Protection against multiple triggers
    private var isProcessingCustomAction: Bool = false
    private var isSimulatingCopy: Bool = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinyAI", category: "KeyboardMonitor")

    private let popupHotkeyKeyCodeDefaultsKey = "PopupHotkeyKeyCodeV1"
    private let popupHotkeyModifiersDefaultsKey = "PopupHotkeyModifiersV1"
    private let popupHotkeyPressModeDefaultsKey = "PopupHotkeyPressModeV1"

    private static let customActionKeyCodeToIndex: [Int64: Int] = [
        18: 1, // 1
        19: 2, // 2
        20: 3, // 3
        21: 4, // 4
        23: 5  // 5
    ]
    
    init(globalMonitoringEnabled: Bool? = nil) {
        if let globalMonitoringEnabled {
            self.globalMonitoringEnabled = globalMonitoringEnabled && !TinyAIRuntime.isTestEnvironment
        } else {
            self.globalMonitoringEnabled = !TinyAIRuntime.isTestEnvironment && TinyAIPermissions.allGranted
        }
        self.lastPermissionState = self.globalMonitoringEnabled

        let defaults = TinyAIRuntime.userDefaults
        let savedKeyCode = defaults.object(forKey: popupHotkeyKeyCodeDefaultsKey) as? Int64
        let savedModifiers = defaults.object(forKey: popupHotkeyModifiersDefaultsKey) as? Int
        let savedPressModeRaw = defaults.string(forKey: popupHotkeyPressModeDefaultsKey)

        let defaultHotkey = KeyboardShortcut(keyCode: 8, modifiers: [.command]) // ⌘C
        popupHotkey = KeyboardShortcut(
            keyCode: savedKeyCode ?? defaultHotkey.keyCode,
            modifiers: ShortcutModifiers(rawValue: savedModifiers ?? defaultHotkey.modifiers.rawValue)
        )
        popupHotkeyPressMode = PopupHotkeyPressMode(rawValue: savedPressModeRaw ?? "") ?? .doublePress

        if savedKeyCode == nil || savedModifiers == nil {
            defaults.set(popupHotkey.keyCode, forKey: popupHotkeyKeyCodeDefaultsKey)
            defaults.set(popupHotkey.modifiers.rawValue, forKey: popupHotkeyModifiersDefaultsKey)
        }
        if savedPressModeRaw == nil {
            defaults.set(popupHotkeyPressMode.rawValue, forKey: popupHotkeyPressModeDefaultsKey)
        }

        if self.globalMonitoringEnabled {
            setupGlobalHotkey()
        }
    }
    
    deinit {
        stopMonitoring()
    }

    func validatePopupHotkey(_ shortcut: KeyboardShortcut, pressMode: PopupHotkeyPressMode) -> String? {
        Self.validationError(for: shortcut, pressMode: pressMode)
    }

    static func validationError(for shortcut: KeyboardShortcut, pressMode: PopupHotkeyPressMode) -> String? {
        guard shortcut.modifiers.contains(.command) else {
            return "Shortcut must include ⌘ (Command)."
        }

        let reservedDigitKeyCodes: Set<Int64> = [18, 19, 20, 21, 22, 23, 25, 26, 28, 29]
        if reservedDigitKeyCodes.contains(shortcut.keyCode) && shortcut.modifiers == [.command] {
            return "⌘1, ⌘2, ⌘3, … are static shortcuts and can’t be reassigned."
        }

        // Always-reserved system-level shortcuts.
        if shortcut.modifiers == [.command] && shortcut.keyCode == 49 { // ⌘Space
            return "⌘Space is reserved by the system."
        }
        if shortcut.modifiers == [.command] && shortcut.keyCode == 48 { // ⌘Tab
            return "⌘Tab is reserved by the system."
        }
        let screenshotKeyCodes: Set<Int64> = [20, 21, 23] // 3/4/5
        if shortcut.modifiers == [.command, .shift] && screenshotKeyCodes.contains(shortcut.keyCode) { // ⌘⇧3/4/5
            return "⌘⇧3/4/5 are reserved by the system for screenshots."
        }

        // Common system/app editing shortcuts are not safe to intercept. ⌘C is the
        // intentional exception for double-press mode because the first press is passed
        // through and the second press opens the popup.
        if shortcut.modifiers == [.command] {
            let reservedSinglePress: Set<Int64> = [
                0,  // A
                6,  // Z
                7,  // X
                8,  // C
                9,  // V
                1,  // S
                12, // Q
                13, // W
                50  // `
            ]
            let allowsDoublePressCopy = pressMode == .doublePress && shortcut.keyCode == 8
            if reservedSinglePress.contains(shortcut.keyCode) && !allowsDoublePressCopy {
                return "This shortcut already has a system-defined action (Copy/Paste/Undo/etc)."
            }
        }

        return nil
    }

    static func preferredPopupPayload(
        pendingClipboard: RichTextPayload?,
        freshClipboard: RichTextPayload?,
        accessibility: RichTextPayload?
    ) -> RichTextPayload? {
        let candidates = [pendingClipboard, freshClipboard, accessibility]
            .compactMap { $0 }
            .filter { !$0.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // A plain value is useful as a last resort, but semantic structure is
        // the primary comparison.  Representation availability is considered
        // only as a tie-breaker after the candidates have the same structure.
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst() {
            let candidateScore = richPayloadScore(candidate)
            let bestScore = richPayloadScore(best)
            if candidateScore > bestScore {
                best = candidate
            } else if candidateScore == bestScore,
                      hasRichRepresentation(candidate),
                      !hasRichRepresentation(best) {
                best = candidate
            }
        }
        return best
    }

    var isGlobalMonitoringEnabled: Bool {
        globalMonitoringEnabled
    }

    static func shouldRetryEventTap(permissionStateChanged: Bool, setupAlreadyAttempted: Bool) -> Bool {
        permissionStateChanged && setupAlreadyAttempted
    }

    /// Start the event tap only after both system permissions are granted.
    /// There is intentionally no timer-based retry: a failed tap must not
    /// produce a chain of macOS permission prompts.
    @discardableResult
    func startMonitoringIfPermitted() -> Bool {
        let permissionsGranted = TinyAIPermissions.allGranted
        guard !TinyAIRuntime.isTestEnvironment, permissionsGranted else {
            globalMonitoringEnabled = false
            lastPermissionState = false
            return false
        }

        let permissionStateChanged = !lastPermissionState
        if Self.shouldRetryEventTap(
            permissionStateChanged: permissionStateChanged,
            setupAlreadyAttempted: eventTapSetupAttempted
        ) {
            eventTapSetupAttempted = false
        }
        lastPermissionState = true
        globalMonitoringEnabled = true
        guard !eventTapSetupAttempted else { return eventTap != nil }
        setupGlobalHotkey()
        return eventTap != nil
    }

    static func richPayloadScore(_ payload: RichTextPayload) -> Int {
        let prepared = RichTextConverter.prepare(payload: payload)
        let signature = RichTextConverter.structureSignature(of: prepared.attributed)
        return signature.structuralScore + signature.inlineScore
    }

    private static func hasRichRepresentation(_ payload: RichTextPayload) -> Bool {
        payload.html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || payload.rtf != nil
    }

    func applyPopupHotkeySettings(shortcut: KeyboardShortcut, pressMode: PopupHotkeyPressMode) -> String? {
        if let error = validatePopupHotkey(shortcut, pressMode: pressMode) {
            return error
        }

        popupHotkey = shortcut
        popupHotkeyPressMode = pressMode
        clearPendingDoublePressState()

        let defaults = TinyAIRuntime.userDefaults
        defaults.set(shortcut.keyCode, forKey: popupHotkeyKeyCodeDefaultsKey)
        defaults.set(shortcut.modifiers.rawValue, forKey: popupHotkeyModifiersDefaultsKey)
        defaults.set(pressMode.rawValue, forKey: popupHotkeyPressModeDefaultsKey)
        return nil
    }

    private func setupGlobalHotkey() {
        guard globalMonitoringEnabled, eventTap == nil, !eventTapSetupAttempted else { return }
        eventTapSetupAttempted = true

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            logger.error("Failed to create event tap")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource = runLoopSource else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            return
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard globalMonitoringEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // A held key generates repeated keyDown events. They must not trigger a
            // second popup or custom action while the user is still holding the key.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return Unmanaged.passUnretained(event)
            }

            if isSimulatingCopy {
                return Unmanaged.passUnretained(event)
            }

            let observedModifiers = ShortcutModifiers(eventFlags: flags)

            if isCustomActionHotkeysEnabled && NSApp.isActive && observedModifiers == [.command] {
                if let index = Self.customActionKeyCodeToIndex[keyCode], !isProcessingCustomAction {
                    isProcessingCustomAction = true
                    DispatchQueue.main.async { [weak self] in
                        self?.customActionHotkey = index
                        DispatchQueue.main.async { [weak self] in
                            self?.customActionHotkey = nil
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.isProcessingCustomAction = false
                    }
                    return nil
                }
            }
            
            if keyCode == popupHotkey.keyCode && observedModifiers == popupHotkey.modifiers {
                let now = Date()
                switch popupHotkeyPressMode {
                case .singlePress:
                    if !isProcessing {
                        isProcessing = true
                        DispatchQueue.main.async { [weak self] in
                            self?.handlePopupHotkeyTriggered()
                        }
                    }
                    return nil
                case .doublePress:
                    if let lastPress = lastPopupHotkeyPressTime,
                       now.timeIntervalSince(lastPress) < doublePressInterval {
                        let previousPasteboardChangeCount = pendingDoublePressPasteboardChangeCount
                        // Start the short grace period here, after the second
                        // press has been observed. The first press may have
                        // happened almost the full double-press interval ago.
                        let naturalCopyStartedAt = now
                        lastPopupHotkeyPressTime = nil
                        clearPendingDoublePressState()
                        if !isProcessing {
                            isProcessing = true
                            DispatchQueue.main.async { [weak self] in
                                self?.handlePopupHotkeyTriggered(
                                    previousPasteboardChangeCount: previousPasteboardChangeCount,
                                    naturalCopyStartedAt: naturalCopyStartedAt
                                )
                            }
                        }
                        return nil
                    }

                    lastPopupHotkeyPressTime = now
                    let canReuseNaturalCopy = popupHotkey.keyCode == 8 && popupHotkey.modifiers == [.command]
                    if canReuseNaturalCopy {
                        pendingDoublePressPasteboardChangeCount = NSPasteboard.general.changeCount
                    } else {
                        clearPendingDoublePressState()
                    }
                    return Unmanaged.passUnretained(event)
                }
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func handlePopupHotkeyTriggered(
        previousPasteboardChangeCount: Int? = nil,
        naturalCopyStartedAt: Date? = nil
    ) {
        // Ensure we are on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePopupHotkeyTriggered(
                    previousPasteboardChangeCount: previousPasteboardChangeCount,
                    naturalCopyStartedAt: naturalCopyStartedAt
                )
            }
            return
        }
        let pasteboard = NSPasteboard.general

        // The first ⌘C is asynchronous in applications such as Slack. Do not
        // fall back to Accessibility while that copy is still in flight: the
        // Accessibility value is often plain text and would permanently lose
        // the HTML/RTF needed for lists, links, and emphasis.
        let replacementTarget = focusedTextReplacementTarget()
        if let previousPasteboardChangeCount, let naturalCopyStartedAt {
            waitForNaturalPasteboardCopy(
                pasteboard: pasteboard,
                baselineChangeCount: previousPasteboardChangeCount,
                replacementTarget: replacementTarget,
                startedAt: naturalCopyStartedAt
            )
            return
        }

        // For a non-copy trigger, Accessibility remains the first fallback.
        if var payload = Self.preferredPopupPayload(
            pendingClipboard: nil,
            freshClipboard: nil,
            accessibility: getSelectedRichText()
        ) {
            payload.replacementTarget = replacementTarget
            emitPopupPayload(payload)
            return
        }

        // Final fallback: ask the target app to copy the selection and wait
        // for a new pasteboard change without ever reusing stale contents.
        let snapshot = snapshotPasteboard(pasteboard)
        let initialChangeCount = pasteboard.changeCount
        requestSyntheticCopy(
            pasteboard: pasteboard,
            snapshot: snapshot,
            initialChangeCount: initialChangeCount,
            replacementTarget: replacementTarget,
            startedAt: Date()
        )
    }

    private func clearPendingDoublePressState() {
        pendingDoublePressPasteboardChangeCount = nil
    }

    private func waitForNaturalPasteboardCopy(
        pasteboard: NSPasteboard,
        baselineChangeCount: Int,
        replacementTarget: TextReplacementTarget?,
        startedAt: Date,
        latestObservation: RichTextPasteboardObservation? = nil,
        lastFormatSignature: String? = nil,
        stableSince: Date? = nil
    ) {
        let now = Date()
        let currentChangeCount = pasteboard.changeCount
        var latest = latestObservation
        var observedSignature = lastFormatSignature
        var observedStableSince = stableSince
        var timing = RichTextCaptureTimingState(
            baselineChangeCount: baselineChangeCount,
            startedAt: startedAt,
            timeout: pasteboardCopyTimeout,
            stabilityWindow: pasteboardStabilityWindow,
            lastFormatSignature: lastFormatSignature,
            stableSince: stableSince
        )
        var timingDecision: RichTextCaptureWaitDecision = .waiting

        if currentChangeCount != baselineChangeCount,
           let observation = observationForCurrentPasteboard(
               pasteboard: pasteboard,
               latestObservation: latest
           ) {
            let hasReadablePayload = observation.payload?.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if hasReadablePayload {
                let enriched: RichTextPasteboardObservation
                if observation.formatSignature != lastFormatSignature,
                   let accessibility = getSelectedAttributedRichText() {
                    enriched = RichTextPasteboard.merging(observation, withAccessibility: accessibility)
                } else {
                    enriched = observation
                }
                latest = enriched
            }
            timingDecision = timing.observe(
                changeCount: currentChangeCount,
                formatSignature: observation.formatSignature,
                hasReadablePayload: hasReadablePayload,
                now: now
            )
            observedSignature = timing.lastFormatSignature
            observedStableSince = timing.stableSince

            if timingDecision == .accept,
               let accepted = latest.flatMap({
                   payloadWithCaptureMetadata(
                       from: $0,
                       replacementTarget: replacementTarget,
                       startedAt: startedAt
                   )
               }) {
                emitPopupPayload(accepted)
                return
            }
        }

        let elapsed = now.timeIntervalSince(startedAt)
        let hasReadableCopy = latest?.payload?.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if timingDecision == .waiting {
            timingDecision = timing.observe(
                changeCount: currentChangeCount,
                formatSignature: nil,
                hasReadablePayload: hasReadableCopy,
                now: now
            )
            observedSignature = timing.lastFormatSignature
            observedStableSince = timing.stableSince
        }
        if elapsed >= pasteboardCopyTimeout {
            if hasReadableCopy,
               let observedStableSince,
               now.timeIntervalSince(observedStableSince) >= pasteboardStabilityWindow,
               let accepted = latest.flatMap({
                   payloadWithCaptureMetadata(
                       from: $0,
                       replacementTarget: replacementTarget,
                       startedAt: startedAt
                   )
               }) {
                emitPopupPayload(accepted)
                return
            }

            // Give a copy that appeared at the one-second boundary its full
            // stability window.  If it never settles, use the single allowed
            // synthetic Copy attempt rather than stale clipboard data.
            if hasReadableCopy, elapsed < pasteboardCopyTimeout + pasteboardStabilityWindow {
                scheduleNaturalPasteboardPoll(
                    pasteboard: pasteboard,
                    baselineChangeCount: baselineChangeCount,
                    replacementTarget: replacementTarget,
                    startedAt: startedAt,
                    latestObservation: latest,
                    lastFormatSignature: observedSignature,
                    stableSince: observedStableSince
                )
                return
            }

            let snapshot = snapshotPasteboard(pasteboard)
            let initialChangeCount = pasteboard.changeCount
            requestSyntheticCopy(
                pasteboard: pasteboard,
                snapshot: snapshot,
                initialChangeCount: initialChangeCount,
                replacementTarget: replacementTarget,
                startedAt: Date()
            )
            return
        }

        scheduleNaturalPasteboardPoll(
            pasteboard: pasteboard,
            baselineChangeCount: baselineChangeCount,
            replacementTarget: replacementTarget,
            startedAt: startedAt,
            latestObservation: latest,
            lastFormatSignature: observedSignature,
            stableSince: observedStableSince
        )
    }

    private func scheduleNaturalPasteboardPoll(
        pasteboard: NSPasteboard,
        baselineChangeCount: Int,
        replacementTarget: TextReplacementTarget?,
        startedAt: Date,
        latestObservation: RichTextPasteboardObservation?,
        lastFormatSignature: String?,
        stableSince: Date?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardPollInterval) { [weak self] in
            self?.waitForNaturalPasteboardCopy(
                pasteboard: pasteboard,
                baselineChangeCount: baselineChangeCount,
                replacementTarget: replacementTarget,
                startedAt: startedAt,
                latestObservation: latestObservation,
                lastFormatSignature: lastFormatSignature,
                stableSince: stableSince
            )
        }
    }

    private func emitPopupPayload(_ payload: RichTextPayload) {
        if let metadata = payload.captureMetadata {
            let types = metadata.availableTypes.joined(separator: ",")
            logger.info(
                "selection capture app=\(metadata.application, privacy: .public) source=\(metadata.source.rawValue, privacy: .public) completeness=\(metadata.completeness.rawValue, privacy: .public) types=\(types, privacy: .public) elapsedMs=\(metadata.elapsedMilliseconds) blocks=\(metadata.blockCount) lists=\(metadata.listCount) links=\(metadata.linkCount) styles=\(metadata.styleCount)"
            )
        }
        onPopupHotkey?(payload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isProcessing = false
        }
    }

    private func requestSyntheticCopy(
        pasteboard: NSPasteboard,
        snapshot: PasteboardSnapshot,
        initialChangeCount: Int,
        replacementTarget: TextReplacementTarget?,
        startedAt: Date
    ) {
        isSimulatingCopy = true
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        if let keyDown, let keyUp {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        waitForPasteboardCopy(
            pasteboard: pasteboard,
            snapshot: snapshot,
            initialChangeCount: initialChangeCount,
            replacementTarget: replacementTarget,
            startedAt: startedAt
        )
    }

    private func waitForPasteboardCopy(
        pasteboard: NSPasteboard,
        snapshot: PasteboardSnapshot,
        initialChangeCount: Int,
        replacementTarget: TextReplacementTarget?,
        startedAt: Date,
        latestObservation: RichTextPasteboardObservation? = nil,
        lastFormatSignature: String? = nil,
        stableSince: Date? = nil
    ) {
        let copiedChangeCount = pasteboard.changeCount
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        var latest = latestObservation
        var observedSignature = lastFormatSignature
        var observedStableSince = stableSince
        var timing = RichTextCaptureTimingState(
            baselineChangeCount: initialChangeCount,
            startedAt: startedAt,
            timeout: pasteboardCopyTimeout,
            stabilityWindow: pasteboardStabilityWindow,
            lastFormatSignature: lastFormatSignature,
            stableSince: stableSince
        )
        var timingDecision: RichTextCaptureWaitDecision = .waiting

        if copiedChangeCount != initialChangeCount,
           let observation = observationForCurrentPasteboard(
               pasteboard: pasteboard,
               latestObservation: latest
           ) {
            let hasReadablePayload = observation.payload?.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if hasReadablePayload {
                let enriched: RichTextPasteboardObservation
                if observation.formatSignature != lastFormatSignature,
                   let accessibility = getSelectedAttributedRichText() {
                    enriched = RichTextPasteboard.merging(observation, withAccessibility: accessibility)
                } else {
                    enriched = observation
                }
                latest = enriched
            }
            timingDecision = timing.observe(
                changeCount: copiedChangeCount,
                formatSignature: observation.formatSignature,
                hasReadablePayload: hasReadablePayload,
                now: now
            )
            observedSignature = timing.lastFormatSignature
            observedStableSince = timing.stableSince

            if timingDecision == .accept,
               let accepted = latest.flatMap({
                   payloadWithCaptureMetadata(
                       from: $0,
                       replacementTarget: replacementTarget,
                       startedAt: startedAt
                   )
               }) {
                emitSyntheticPayload(
                    accepted,
                    pasteboard: pasteboard,
                    copiedChangeCount: copiedChangeCount,
                    snapshot: snapshot
                )
                return
            }
        }

        if timingDecision == .waiting {
            timingDecision = timing.observe(
                changeCount: copiedChangeCount,
                formatSignature: nil,
                hasReadablePayload: latest?.payload != nil,
                now: now
            )
            observedSignature = timing.lastFormatSignature
            observedStableSince = timing.stableSince
        }

        if elapsed >= pasteboardCopyTimeout + pasteboardStabilityWindow,
           let latest,
           let observedStableSince,
           now.timeIntervalSince(observedStableSince) >= pasteboardStabilityWindow,
           let accepted = payloadWithCaptureMetadata(
               from: latest,
               replacementTarget: replacementTarget,
               startedAt: startedAt
           ) {
            emitSyntheticPayload(
                accepted,
                pasteboard: pasteboard,
                copiedChangeCount: copiedChangeCount,
                snapshot: snapshot
            )
            return
        }

        if elapsed >= pasteboardCopyTimeout {
            // Do not reuse stale clipboard data when the target application did not
            // provide a readable selection before the deadline.
            if copiedChangeCount != initialChangeCount,
               pasteboard.changeCount == copiedChangeCount {
                restorePasteboard(pasteboard, snapshot: snapshot)
            }
            isSimulatingCopy = false
            isProcessing = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardPollInterval) { [weak self] in
            self?.waitForPasteboardCopy(
                pasteboard: pasteboard,
                snapshot: snapshot,
                initialChangeCount: initialChangeCount,
                replacementTarget: replacementTarget,
                startedAt: startedAt,
                latestObservation: latest,
                lastFormatSignature: observedSignature,
                stableSince: observedStableSince
            )
        }
    }

    private func emitSyntheticPayload(
        _ payload: RichTextPayload,
        pasteboard: NSPasteboard,
        copiedChangeCount: Int,
        snapshot: PasteboardSnapshot
    ) {
        emitPopupPayload(payload)
        // Restore only the clipboard contents produced by our synthetic copy.
        // If the user copied something else in the meantime, never overwrite it.
        if pasteboard.changeCount == copiedChangeCount {
            restorePasteboard(pasteboard, snapshot: snapshot)
        }
        isSimulatingCopy = false
    }

    private func payloadWithCaptureMetadata(
        from observation: RichTextPasteboardObservation,
        replacementTarget: TextReplacementTarget?,
        startedAt: Date
    ) -> RichTextPayload? {
        guard var payload = observation.payload,
              let prepared = observation.prepared else {
            return nil
        }
        let summary = RichTextConverter.formattingSummary(of: prepared)
        let source = observation.source ?? .pasteboardPlain
        let completeness: RichTextCaptureCompleteness
        switch source {
        case .pasteboardPlain:
            completeness = summary.listCount > 0 || summary.linkCount > 0 || summary.styleCount > 0 ? .rich : .plain
        case .pasteboardHTML, .pasteboardRTF, .pasteboardRTFD:
            completeness = .rich
        case .accessibilityAttributed:
            completeness = .attributed
        case .accessibilityPlain:
            completeness = .plain
        }
        let processName = sourceApplication(for: replacementTarget)
        payload.replacementTarget = replacementTarget
        payload.captureMetadata = RichTextCaptureMetadata(
            application: processName,
            availableTypes: observation.availableTypes,
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1000.0)),
            source: source,
            completeness: completeness,
            blockCount: summary.blockCount,
            listCount: summary.listCount,
            linkCount: summary.linkCount,
            styleCount: summary.styleCount
        )
        return payload
    }

    private func observationForCurrentPasteboard(
        pasteboard: NSPasteboard,
        latestObservation: RichTextPasteboardObservation?
    ) -> RichTextPasteboardObservation? {
        let signature = RichTextPasteboard.formatSignature(from: pasteboard)
        if let latestObservation, latestObservation.formatSignature == signature {
            return latestObservation
        }
        return RichTextPasteboard.readObservation(from: pasteboard)
    }

    private enum PasteboardValue {
        case data(Data)
        case string(String)
        case plist(Data)
    }

    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: PasteboardValue]]

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else {
            return []
        }

        var snapshot: PasteboardSnapshot = []
        snapshot.reserveCapacity(items.count)

        for item in items {
            var dict: [NSPasteboard.PasteboardType: PasteboardValue] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = .data(data)
                    continue
                }
                if let string = item.string(forType: type) {
                    dict[type] = .string(string)
                    continue
                }
                if let plist = item.propertyList(forType: type),
                   let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                    dict[type] = .plist(data)
                    continue
                }
            }
            snapshot.append(dict)
        }

        return snapshot
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else {
            return
        }

        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.count)

        for dict in snapshot {
            let item = NSPasteboardItem()
            for (type, value) in dict {
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
            items.append(item)
        }

        pasteboard.writeObjects(items)
    }

    private func focusedTextReplacementTarget() -> TextReplacementTarget? {
        guard let element = focusedUIElement() else { return nil }
        return textReplacementTarget(for: element)
    }

    private func textReplacementTarget(for element: AXUIElement) -> TextReplacementTarget? {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        guard processIdentifier != 0 else { return nil }
        return TextReplacementTarget(element: element, processIdentifier: processIdentifier)
    }

    private func focusedUIElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedElementValue: AnyObject?
        let focusedElementResult = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue)

        let element: AXUIElement?
        if focusedElementResult == .success, let focused = focusedElementValue as! AXUIElement? {
            element = focused
        } else {
            var focusedApp: AnyObject?
            let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &focusedApp)
            guard result == .success, let app = focusedApp as! AXUIElement? else {
                return nil
            }

            var focusedWindow: AnyObject?
            let windowResult = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
            guard windowResult == .success, let window = focusedWindow as! AXUIElement? else {
                return nil
            }

            element = window
        }

        return element
    }

    private func getSelectedRichText(includePlainFallback: Bool = true) -> RichTextPayload? {
        guard let element = focusedUIElement() else { return nil }
        let target = textReplacementTarget(for: element)

        let attributedAttribute = "AXSelectedTextAttributedString" as CFString
        var attributedValue: AnyObject?
        let attributedResult = AXUIElementCopyAttributeValue(element, attributedAttribute, &attributedValue)
        if attributedResult == .success, let attributed = attributedValue as? NSAttributedString, !attributed.string.isEmpty {
            let prepared = RichTextConverter.prepare(attributed: attributed, inferListMarkers: true)
            let summary = RichTextConverter.formattingSummary(of: prepared)
            let metadata = RichTextCaptureMetadata(
                application: sourceApplication(for: target),
                availableTypes: ["AXSelectedTextAttributedString"],
                elapsedMilliseconds: 0,
                source: .accessibilityAttributed,
                completeness: .attributed,
                blockCount: summary.blockCount,
                listCount: summary.listCount,
                linkCount: summary.linkCount,
                styleCount: summary.styleCount
            )
            var payload = prepared.payload
            payload.replacementTarget = target
            payload.captureMetadata = metadata
            return payload
        }

        guard includePlainFallback else { return nil }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            var payload = RichTextPayload(
                plain: RichTextConverter.normalizedMarkdown(text.normalizedPlainText()),
                html: nil,
                rtf: nil,
                replacementTarget: target
            )
            payload.captureMetadata = RichTextCaptureMetadata(
                application: sourceApplication(for: target),
                availableTypes: ["AXSelectedText"],
                elapsedMilliseconds: 0,
                source: .accessibilityPlain,
                completeness: .plain,
                blockCount: 1,
                listCount: 0,
                linkCount: 0,
                styleCount: 0
            )
            return payload
        }

        return nil
    }

    private func sourceApplication(for target: TextReplacementTarget?) -> String {
        if let target,
           let application = NSRunningApplication(processIdentifier: target.processIdentifier) {
            return application.bundleIdentifier ?? application.localizedName ?? "unknown"
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "unknown"
    }

    /// Read only the formatted Accessibility representation.  This is called
    /// after a changed pasteboard has been observed, never as a substitute for
    /// an unconfirmed double-⌘C copy.
    private func getSelectedAttributedRichText() -> PreparedRichText? {
        guard let element = focusedUIElement() else { return nil }
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextAttributedString" as CFString,
            &value
        )
        guard result == .success,
              let attributed = value as? NSAttributedString,
              !attributed.string.isEmpty else {
            return nil
        }
        return RichTextConverter.prepare(attributed: attributed, inferListMarkers: true)
    }
    
    func stopMonitoring() {
        globalMonitoringEnabled = false
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
    }
}
