import Cocoa
import Carbon
import ApplicationServices
import Combine
import os

nonisolated enum PopupHotkeyPressMode: String, CaseIterable, Identifiable, Sendable {
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

nonisolated struct ShortcutModifiers: OptionSet, Equatable, Sendable {
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

nonisolated struct KeyboardShortcut: Equatable, Sendable {
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

/// State shared between the main thread and the event-tap thread.  The tap
/// callback runs on its own thread so a busy main thread (Accessibility
/// calls, HTML import, pasteboard snapshots) never delays keystrokes in
/// other applications; every field it reads or writes lives here.
nonisolated private final class EventTapState: @unchecked Sendable {
    struct Values {
        var globalMonitoringEnabled = false
        var isCustomActionHotkeysEnabled = false
        var isAppActive = false
        var popupHotkey = KeyboardShortcut(keyCode: 8, modifiers: [.command])
        var popupHotkeyPressMode: PopupHotkeyPressMode = .doublePress
        var isProcessing = false
        var isProcessingCustomAction = false
        var isSimulatingCopy = false
        var lastPopupHotkeyPressTime: Date?
        var pendingDoublePressPasteboardChangeCount: Int?
    }

    private let lock = NSLock()
    private var values = Values()
    private var tap: CFMachPort?

    nonisolated func read<T>(_ keyPath: KeyPath<Values, T>) -> T {
        lock.lock()
        defer { lock.unlock() }
        return values[keyPath: keyPath]
    }

    @discardableResult
    nonisolated func update<T>(_ body: (inout Values) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&values)
    }

    nonisolated var eventTap: CFMachPort? {
        get { lock.lock(); defer { lock.unlock() }; return tap }
        set { lock.lock(); tap = newValue; lock.unlock() }
    }
}

/// A thread that only runs a run loop for the event-tap source.
nonisolated private final class EventTapThread: Thread, @unchecked Sendable {
    private let source: CFRunLoopSource
    private let started = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private(set) var runLoop: CFRunLoop?

    nonisolated init(source: CFRunLoopSource) {
        self.source = source
        super.init()
        name = "TinyAI.EventTap"
        qualityOfService = .userInteractive
    }

    nonisolated override func main() {
        let current = CFRunLoopGetCurrent()
        runLoop = current
        CFRunLoopAddSource(current, source, .commonModes)
        started.signal()
        CFRunLoopRun()
    }

    /// Start the thread and wait until its run loop owns the source.
    func startAndWait() {
        start()
        started.wait()
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopStop(runLoop)
    }
}

/// Accessibility requests go to other processes.  A short messaging timeout
/// keeps a hung frontmost application from blocking TinyAI for the default
/// of several seconds per request.
enum AccessibilityElements {
    static let messagingTimeout: Float = 0.5

    static func systemWide() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        // Setting the timeout on the system-wide element applies it to every
        // element this process messages.
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
}

class KeyboardMonitor: ObservableObject {
    var onPopupHotkey: ((RichTextPayload) -> Void)?
    @Published var isCustomActionHotkeysEnabled: Bool = false {
        didSet { tapState.update { $0.isCustomActionHotkeysEnabled = isCustomActionHotkeysEnabled } }
    }

    @Published var customActionHotkey: Int?
    @Published var popupHotkey: KeyboardShortcut {
        didSet { tapState.update { $0.popupHotkey = popupHotkey } }
    }

    @Published var popupHotkeyPressMode: PopupHotkeyPressMode {
        didSet { tapState.update { $0.popupHotkeyPressMode = popupHotkeyPressMode } }
    }

    private let tapState = EventTapState()
    private nonisolated let doublePressInterval: TimeInterval = 0.5
    private let pasteboardPollInterval: TimeInterval = 0.01
    private let pasteboardCopyTimeout: TimeInterval = 0.20
    private var runLoopSource: CFRunLoopSource?
    private var eventTapThread: EventTapThread?
    private var appActivationObservers: [NSObjectProtocol] = []

    private(set) var globalMonitoringEnabled: Bool {
        get { tapState.read(\.globalMonitoringEnabled) }
        set { tapState.update { $0.globalMonitoringEnabled = newValue } }
    }

    private var eventTap: CFMachPort? {
        get { tapState.eventTap }
        set { tapState.eventTap = newValue }
    }
    // Protection against multiple triggers.
    private var isProcessing: Bool {
        get { tapState.read(\.isProcessing) }
        set { tapState.update { $0.isProcessing = newValue } }
    }

    private var isProcessingCustomAction: Bool {
        get { tapState.read(\.isProcessingCustomAction) }
        set { tapState.update { $0.isProcessingCustomAction = newValue } }
    }

    private var isSimulatingCopy: Bool {
        get { tapState.read(\.isSimulatingCopy) }
        set { tapState.update { $0.isSimulatingCopy = newValue } }
    }

    private var pendingDoublePressPasteboardChangeCount: Int? {
        get { tapState.read(\.pendingDoublePressPasteboardChangeCount) }
        set { tapState.update { $0.pendingDoublePressPasteboardChangeCount = newValue } }
    }

    private var eventTapSetupAttempted = false
    private var lastPermissionState: Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinyAI", category: "KeyboardMonitor")

    private let popupHotkeyKeyCodeDefaultsKey = "PopupHotkeyKeyCodeV1"
    private let popupHotkeyModifiersDefaultsKey = "PopupHotkeyModifiersV1"
    private let popupHotkeyPressModeDefaultsKey = "PopupHotkeyPressModeV1"

    private nonisolated static let customActionKeyCodeToIndex: [Int64: Int] = [
        18: 1, // 1
        19: 2, // 2
        20: 3, // 3
        21: 4, // 4
        23: 5  // 5
    ]

    init(globalMonitoringEnabled: Bool? = nil) {
        let monitoringEnabled: Bool
        if let globalMonitoringEnabled {
            monitoringEnabled = globalMonitoringEnabled && !TinyAIRuntime.isTestEnvironment
        } else {
            monitoringEnabled = !TinyAIRuntime.isTestEnvironment
                && TinyAIPermissions.allGranted
        }
        self.lastPermissionState = monitoringEnabled

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
        let initialHotkey = popupHotkey
        let initialPressMode = popupHotkeyPressMode
        tapState.update {
            $0.globalMonitoringEnabled = monitoringEnabled
            $0.popupHotkey = initialHotkey
            $0.popupHotkeyPressMode = initialPressMode
            $0.isAppActive = NSApp?.isActive ?? false
        }
        observeAppActivation()

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
        appActivationObservers.forEach(NotificationCenter.default.removeObserver)
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

    static func shouldEnableGlobalMonitoring(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        !TinyAIRuntime.isTestEnvironment(arguments: arguments, environment: environment)
    }

    var isGlobalMonitoringEnabled: Bool {
        globalMonitoringEnabled
    }

    static func shouldRetryEventTap(permissionStateChanged: Bool, setupAlreadyAttempted: Bool) -> Bool {
        permissionStateChanged && setupAlreadyAttempted
    }

    /// Start the global event tap after the user has granted both permissions.
    /// The monitor is created before the application delegate receives its
    /// launch callback, so startup must be able to enable it later without
    /// constructing a second monitor.
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

    static func preferredPopupPayload(
        pendingClipboard: RichTextPayload?,
        freshClipboard: RichTextPayload?,
        accessibility: RichTextPayload?
    ) -> RichTextPayload? {
        let candidates = [pendingClipboard, freshClipboard, accessibility]
            .compactMap { $0 }
            .filter { !$0.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // A plain clipboard value is useful as a last resort, but it must not
        // win over a rich value that arrived from another representation of
        // the same selection (for example, Accessibility versus HTML/RTF).
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst() where richPayloadScore(candidate) > richPayloadScore(best) {
            best = candidate
        }
        return best
    }

    static func richPayloadScore(_ payload: RichTextPayload) -> Int {
        var score = 0
        if payload.html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            score += 2
        }
        if payload.rtf != nil {
            score += 1
        }
        return score
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
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
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

        let thread = EventTapThread(source: runLoopSource)
        thread.startAndWait()
        eventTapThread = thread
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Runs on the event-tap thread.  It only decides whether to pass or
    /// swallow the event and hands any work to the main thread.
    private nonisolated func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable a tap the system disabled even while monitoring is
        // paused; otherwise it stays dead after permissions come back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = tapState.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, tapState.read(\.globalMonitoringEnabled) else {
            return Unmanaged.passUnretained(event)
        }

        // A held key generates repeated keyDown events. They must not trigger a
        // second popup or custom action while the user is still holding the key.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let observedModifiers = ShortcutModifiers(eventFlags: event.flags)
        let now = Date()
        let doublePressInterval = self.doublePressInterval

        enum Decision {
            case pass
            case passAndRecordFirstPress(reuseNaturalCopy: Bool)
            case swallow
            case customAction(Int)
            case popup(previousPasteboardChangeCount: Int?, naturalCopyStartedAt: Date?)
        }

        let decision: Decision = tapState.update { state in
            if state.isSimulatingCopy {
                return .pass
            }

            if state.isCustomActionHotkeysEnabled && state.isAppActive && observedModifiers == [.command],
               let index = Self.customActionKeyCodeToIndex[keyCode] {
                guard !state.isProcessingCustomAction else { return .pass }
                state.isProcessingCustomAction = true
                return .customAction(index)
            }

            guard keyCode == state.popupHotkey.keyCode && observedModifiers == state.popupHotkey.modifiers else {
                return .pass
            }

            switch state.popupHotkeyPressMode {
            case .singlePress:
                guard !state.isProcessing else { return .swallow }
                state.isProcessing = true
                return .popup(previousPasteboardChangeCount: nil, naturalCopyStartedAt: nil)
            case .doublePress:
                if let lastPress = state.lastPopupHotkeyPressTime,
                   now.timeIntervalSince(lastPress) < doublePressInterval {
                    let previousPasteboardChangeCount = state.pendingDoublePressPasteboardChangeCount
                    state.lastPopupHotkeyPressTime = nil
                    state.pendingDoublePressPasteboardChangeCount = nil
                    guard !state.isProcessing else { return .swallow }
                    state.isProcessing = true
                    // Start the short grace period here, after the second
                    // press has been observed. The first press may have
                    // happened almost the full double-press interval ago.
                    return .popup(previousPasteboardChangeCount: previousPasteboardChangeCount, naturalCopyStartedAt: now)
                }
                state.lastPopupHotkeyPressTime = now
                let reuseNaturalCopy = state.popupHotkey.keyCode == 8 && state.popupHotkey.modifiers == [.command]
                if !reuseNaturalCopy {
                    state.pendingDoublePressPasteboardChangeCount = nil
                }
                return .passAndRecordFirstPress(reuseNaturalCopy: reuseNaturalCopy)
            }
        }

        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .passAndRecordFirstPress(let reuseNaturalCopy):
            if reuseNaturalCopy {
                let changeCount = NSPasteboard.general.changeCount
                tapState.update { $0.pendingDoublePressPasteboardChangeCount = changeCount }
            }
            return Unmanaged.passUnretained(event)
        case .customAction(let index):
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
        case .popup(let previousPasteboardChangeCount, let naturalCopyStartedAt):
            DispatchQueue.main.async { [weak self] in
                self?.handlePopupHotkeyTriggered(
                    previousPasteboardChangeCount: previousPasteboardChangeCount,
                    naturalCopyStartedAt: naturalCopyStartedAt
                )
            }
            return nil
        }
    }

    /// `NSApp.isActive` is main-thread only; the tap reads a mirrored value.
    private func observeAppActivation() {
        let center = NotificationCenter.default
        let state = tapState
        appActivationObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                state.update { $0.isAppActive = true }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                state.update { $0.isAppActive = false }
            }
        ]
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
                startedAt: naturalCopyStartedAt,
                fallbackPayload: nil
            )
            return
        }

        // For every trigger other than the natural first copy, ask the target
        // application for a real copy first.  Accessibility is captured as a
        // fallback, but is not emitted until the short clipboard grace period
        // has elapsed; otherwise its plain value could win before HTML/RTF is
        // published by the source application.
        let accessibilityFallback = getSelectedRichText()
        let snapshot = snapshotPasteboard(pasteboard)
        let initialChangeCount = pasteboard.changeCount

        // Copy selected text
        isSimulatingCopy = true
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
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
            startedAt: Date(),
            fallbackPayload: accessibilityFallback
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
        fallbackPayload: RichTextPayload?
    ) {
        let currentChangeCount = pasteboard.changeCount
        var latestPayload = fallbackPayload

        if currentChangeCount != baselineChangeCount,
           let payload = RichTextPasteboard.read(from: pasteboard),
           !payload.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestPayload = payload

            // A rich representation is complete enough to use immediately.
            // If this is only plain text, keep polling until the deadline in
            // case the source app publishes HTML/RTF shortly afterwards.
            if Self.richPayloadScore(payload) > 0 {
                var richPayload = payload
                richPayload.replacementTarget = replacementTarget
                emitPopupPayload(richPayload)
                return
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= pasteboardCopyTimeout {
            let accessibilityPayload = getSelectedRichText()
            if var payload = Self.preferredPopupPayload(
                pendingClipboard: latestPayload,
                freshClipboard: nil,
                accessibility: accessibilityPayload
            ) {
                payload.replacementTarget = replacementTarget
                emitPopupPayload(payload)
                return
            }

            // The natural copy did not produce readable text. Use the same
            // bounded synthetic-copy fallback as the single-press path, but
            // never read the old clipboard value as if it were the selection.
            let snapshot = snapshotPasteboard(pasteboard)
            let initialChangeCount = pasteboard.changeCount
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
                startedAt: Date(),
                fallbackPayload: latestPayload
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardPollInterval) { [weak self] in
            self?.waitForNaturalPasteboardCopy(
                pasteboard: pasteboard,
                baselineChangeCount: baselineChangeCount,
                replacementTarget: replacementTarget,
                startedAt: startedAt,
                fallbackPayload: latestPayload
            )
        }
    }

    private func emitPopupPayload(_ payload: RichTextPayload) {
        onPopupHotkey?(payload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isProcessing = false
        }
    }

    private func waitForPasteboardCopy(
        pasteboard: NSPasteboard,
        snapshot: PasteboardSnapshot,
        initialChangeCount: Int,
        replacementTarget: TextReplacementTarget?,
        startedAt: Date,
        fallbackPayload: RichTextPayload?
    ) {
        let copiedChangeCount = pasteboard.changeCount
        let elapsed = Date().timeIntervalSince(startedAt)
        var latestPayload = fallbackPayload

        if copiedChangeCount != initialChangeCount,
           let payload = RichTextPasteboard.read(from: pasteboard),
           !payload.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestPayload = payload

            // A rich representation is complete enough to use immediately.
            // Keep polling when the source has published only plain text: its
            // HTML/RTF item can arrive a few milliseconds later.
            if Self.richPayloadScore(payload) > 0 {
                var richPayload = payload
                richPayload.replacementTarget = replacementTarget
                emitPopupPayload(richPayload)

                // Restore only the clipboard contents produced by our
                // synthetic copy. If the user copied something else in the
                // meantime, never overwrite it.
                if pasteboard.changeCount == copiedChangeCount {
                    restorePasteboard(pasteboard, snapshot: snapshot)
                }
                isSimulatingCopy = false
                return
            }
        }

        if elapsed >= pasteboardCopyTimeout {
            let accessibilityPayload = getSelectedRichText() ?? fallbackPayload
            if var payload = Self.preferredPopupPayload(
                pendingClipboard: latestPayload,
                freshClipboard: nil,
                accessibility: accessibilityPayload
            ) {
                payload.replacementTarget = replacementTarget
                emitPopupPayload(payload)
            }

            // Do not reuse stale clipboard data when the target application did
            // not provide a readable selection before the deadline.
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
                fallbackPayload: latestPayload
            )
        }
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
        let systemWideElement = AccessibilityElements.systemWide()

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

    private func getSelectedRichText() -> RichTextPayload? {
        guard let element = focusedUIElement() else { return nil }
        let target = textReplacementTarget(for: element)

        let attributedAttribute = "AXSelectedTextAttributedString" as CFString
        var attributedValue: AnyObject?
        let attributedResult = AXUIElementCopyAttributeValue(element, attributedAttribute, &attributedValue)
        if attributedResult == .success, let attributed = attributedValue as? NSAttributedString, !attributed.string.isEmpty {
            var payload = RichTextConverter.prepare(attributed: attributed).payload
            payload.replacementTarget = target
            return payload
        }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            return RichTextPayload(
                plain: RichTextConverter.normalizedMarkdown(text.normalizedPlainText()),
                html: nil,
                rtf: nil,
                replacementTarget: target
            )
        }

        return nil
    }

    func stopMonitoring() {
        globalMonitoringEnabled = false
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTapThread?.stop()

        eventTapThread = nil
        runLoopSource = nil
        eventTap = nil
    }
}
