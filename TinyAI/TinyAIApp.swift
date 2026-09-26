import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import os

enum TinyAIRuntime {
    private static let testDefaultsSuite = "IT.TinyAI.TestRuntime"

    static var isTestEnvironment: Bool {
        isTestEnvironment(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
    }

    /// Keep test-host preferences away from the installed application's
    /// defaults. UI tests already use a separate bundle identifier; this also
    /// covers unit tests that launch the regular app as their host.
    static var userDefaults: UserDefaults {
        guard isTestEnvironment else { return .standard }
        return UserDefaults(suiteName: testDefaultsSuite) ?? .standard
    }

    static func isTestEnvironment(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.contains("--ui-testing") || environment["TINYAI_TEST_MODE"] == "1" {
            return true
        }

        // XCTest uses these variables when it injects a test bundle into the
        // application. Checking them keeps unit-test hosts safe even when the
        // test did not pass an explicit launch argument.
        if environment["XCInjectBundleInto"] != nil || environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        return environment.keys.contains { $0.hasPrefix("XCTest") }
    }
}

/// Permission checks are kept separate from the event monitor so the app can
/// inspect status without displaying a system dialog. Only an explicit launch
/// request or the Settings button may call the requesting methods.
enum TinyAIPermissions {
    enum Permission: String, CaseIterable, Identifiable {
        case accessibility
        case inputMonitoring

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }
    }

    // Keep permission prompts bounded within one process. The launch path
    // also stores a per-version marker, while Settings can explicitly opt in
    // to another request after the user has changed macOS permissions.
    private static var requestedThisProcess: Set<Permission> = []

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoringGranted: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }
        return true
    }

    static var allGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    static func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: return accessibilityGranted
        case .inputMonitoring: return inputMonitoringGranted
        }
    }

    static func requestablePermissions(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        requested: Set<Permission>
    ) -> [Permission] {
        Permission.allCases.filter { permission in
            let granted: Bool
            switch permission {
            case .accessibility:
                granted = accessibilityGranted
            case .inputMonitoring:
                granted = inputMonitoringGranted
            }
            return !granted && !requested.contains(permission)
        }
    }

    /// Ask macOS for any currently missing permission. Normal launch calls
    /// are limited to one request per process; Settings passes `explicit:
    /// true` to deliberately retry after the user has changed access.
    @discardableResult
    static func requestMissing(explicit: Bool = false) -> Bool {
        guard !TinyAIRuntime.isTestEnvironment else { return allGranted }

        let requestable: [Permission]
        if explicit {
            requestable = Permission.allCases.filter { !isGranted($0) }
        } else {
            requestable = requestablePermissions(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                requested: requestedThisProcess
            )
        }

        if requestable.contains(.accessibility) {
            requestedThisProcess.insert(.accessibility)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        if #available(macOS 10.15, *), requestable.contains(.inputMonitoring) {
            requestedThisProcess.insert(.inputMonitoring)
            _ = CGRequestListenEventAccess()
        }
        return allGranted
    }
}

@main
struct TinyAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var translationService = TranslationService()
    @StateObject private var keyboardMonitor = KeyboardMonitor()

    var body: some Scene {
        WindowGroup {
            MainTranslationView()
                .environmentObject(translationService)
                .environmentObject(keyboardMonitor)
                .environmentObject(appDelegate.voiceStore)
                .environmentObject(appDelegate.voiceCoordinator)
                .environmentObject(appDelegate.localModelManager)
                .onAppear {
                    appDelegate.translationService = translationService
                    appDelegate.keyboardMonitor = keyboardMonitor
                    keyboardMonitor.onPopupHotkey = { [weak appDelegate = appDelegate] payload in
                        appDelegate?.showTranslationPopup(with: payload)
                    }
                    appDelegate.connectVoice(translationService: translationService, keyboardMonitor: keyboardMonitor)
                    appDelegate.startKeyboardMonitoringIfPermitted()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 800, height: 600)
    }
}

private struct HoverHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.unemphasizedSelectedContentBackgroundColor))
                    .opacity(isEnabled && isHovering ? 0.18 : 0)
            )
            .scaleEffect(isEnabled && isHovering ? 1.01 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct HoverRowHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.unemphasizedSelectedContentBackgroundColor))
                    .opacity(isEnabled && isHovering ? 0.12 : 0)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct HoverToolbarIconModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        content
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(Color(NSColor.unemphasizedSelectedContentBackgroundColor))
                    .opacity(isEnabled && isHovering ? 0.14 : 0)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }

    func hoverRowHighlight() -> some View {
        modifier(HoverRowHighlightModifier())
    }

    func hoverToolbarIcon() -> some View {
        modifier(HoverToolbarIconModifier())
    }
}

// Keep this subclass concrete. A generic NSHostingView subclass triggers a
// Swift 6.3 Release-optimizer crash while synthesising its deinit; the view
// itself does not need to expose its generic root type to the rest of the app.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Notification.Name {
    static let tinyAIOpenSettings = Notification.Name("TinyAIOpenSettings")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var popupWindow: NSWindow?
    let voiceStore = VoiceSettingsStore()
    let localModelManager = LocalModelManager()
    lazy var voiceCoordinator = VoiceCoordinator(store: voiceStore, modelManager: localModelManager)
    private var statusBarController: StatusBarController?
    private var responsePanel: AgentResponsePanelController?
    weak var translationService: TranslationService?
    var keyboardMonitor: KeyboardMonitor?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinyAI", category: "AppDelegate")
    private var permissionObserver: NSObjectProtocol?
    private let permissionPromptDefaultsKey = "PermissionPromptedVersionV1"

    func isFrontmostWindowFullscreen() -> Bool {
        let systemWideElement = AccessibilityElements.systemWide()

        var focusedApp: AnyObject?
        let focusedAppResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard focusedAppResult == .success, let app = focusedApp as! AXUIElement? else {
            return false
        }

        var focusedWindow: AnyObject?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard focusedWindowResult == .success, let window = focusedWindow as! AXUIElement? else {
            return false
        }

        var isFullscreenValue: AnyObject?
        let fullscreenAttribute = "AXFullScreen" as CFString
        let fullscreenResult = AXUIElementCopyAttributeValue(
            window,
            fullscreenAttribute,
            &isFullscreenValue
        )

        if fullscreenResult == .success, let isFullscreen = isFullscreenValue as? Bool {
            return isFullscreen
        }

        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the app in the Dock so the main window is visible
        // NSApp.setActivationPolicy(.accessory)

        guard !TinyAIRuntime.isTestEnvironment else { return }

        setUpVoice()
        requestMissingPermissionsAtLaunchIfNeeded()
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.startKeyboardMonitoringIfPermitted()
        }
        startKeyboardMonitoringIfPermitted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalTranscriptionEngine.shared.unloadNow()
    }

    deinit {
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
        }
    }

    private func currentVersionToken() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private func requestMissingPermissionsAtLaunchIfNeeded() {
        guard !TinyAIPermissions.allGranted else {
            startKeyboardMonitoringIfPermitted()
            return
        }

        let token = currentVersionToken()
        let defaults = TinyAIRuntime.userDefaults
        if defaults.string(forKey: permissionPromptDefaultsKey) != token {
            // Mark before invoking macOS. If the user closes or denies the
            // dialog, this version will not surprise them with another prompt
            // on every launch. Settings provides the explicit retry point.
            defaults.set(token, forKey: permissionPromptDefaultsKey)
            _ = TinyAIPermissions.requestMissing()
        }

        if !TinyAIPermissions.allGranted {
            logger.notice("Accessibility and Input Monitoring permissions are required for global hotkeys")
        }
    }

    /// Hook the voice features up to the hotkeys and the OpenAI key.
    func connectVoice(translationService: TranslationService, keyboardMonitor: KeyboardMonitor) {
        let coordinator = voiceCoordinator
        coordinator.openAIKeyProvider = { [weak translationService] in
            translationService?.apiKey(for: .openAI) ?? ""
        }
        keyboardMonitor.onVoiceHotkey = { [weak coordinator] id, edge in
            coordinator?.handleHotkey(id: id, edge: edge)
        }
        keyboardMonitor.onVoiceCancel = { [weak coordinator] in
            coordinator?.cancel()
        }
        coordinator.keyboardMonitor = keyboardMonitor
    }

    private func setUpVoice() {
        let coordinator = voiceCoordinator
        let panel = AgentResponsePanelController(coordinator: coordinator)
        responsePanel = panel
        coordinator.onShowPanel = { [weak panel] in panel?.show() }
        coordinator.onHidePanel = { [weak panel] in panel?.hide() }
        statusBarController = StatusBarController(
            coordinator: coordinator,
            openMainWindow: { [weak self] in self?.showMainWindow() },
            openSettings: { [weak self] in
                self?.showMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(name: .tinyAIOpenSettings, object: nil)
                }
            }
        )
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Re-opening the running app makes SwiftUI create a new main window.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
    }

    func startKeyboardMonitoringIfPermitted() {
        guard !TinyAIRuntime.isTestEnvironment,
              TinyAIPermissions.allGranted else { return }
        _ = keyboardMonitor?.startMonitoringIfPermitted()
    }

    func showTranslationPopup(with payload: RichTextPayload) {
        // Ensure everything runs on the main thread
        DispatchQueue.main.async { [weak self] in
            guard
                let self = self,
                let translationService = self.translationService,
                let keyboardMonitor = self.keyboardMonitor
            else { return }

            // Close the previous window if it's open
            if let existingWindow = self.popupWindow {
                existingWindow.close()
                self.popupWindow = nil
            }

            // IMPORTANT: Create the popup on the current desktop.
            // This ensures the new window is created on the same desktop
            // where the active app resides.
            let wasActive = NSApplication.shared.isActive
            if !wasActive {
                // Create the popup without switching desktops
                self.createPopupWindow(payload: payload, translationService: translationService, keyboardMonitor: keyboardMonitor)
            } else {
                self.createPopupWindow(payload: payload, translationService: translationService, keyboardMonitor: keyboardMonitor)
            }
        }
    }

    private func createPopupWindow(payload: RichTextPayload, translationService: TranslationService, keyboardMonitor: KeyboardMonitor) {
        // Create the view on the main thread
        let popupView = TranslationPopupView(selectedText: payload.plain, selectedPayload: payload, onClose: { [weak self] in
            DispatchQueue.main.async {
                self?.popupWindow?.close()
                self?.popupWindow = nil
            }
        })
        .environmentObject(translationService)
        .environmentObject(keyboardMonitor)

        // Create a hosting view with correct sizing
        let hostingView = FirstMouseHostingView(rootView: AnyView(popupView))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 14
        hostingView.layer?.masksToBounds = true
        if #available(macOS 10.15, *) {
            hostingView.layer?.cornerCurve = .continuous
        }

        // Create a draggable window
        let window = DraggableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [NSWindow.StyleMask.borderless, NSWindow.StyleMask.fullSizeContentView, NSWindow.StyleMask.nonactivatingPanel, NSWindow.StyleMask.resizable],
            backing: NSWindow.BackingStoreType.buffered,
            defer: false
        )

        window.contentView = hostingView
        // Keep the window itself fully transparent so rounded corners don't reveal a halo/border.
        // The actual background is drawn by the SwiftUI content.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 420)

        // Use the correct settings to keep the window on the same desktop.
        // fullScreenAuxiliary allows the window to appear in fullscreen.
        // Do NOT use canJoinAllSpaces (it makes the window visible on all Spaces).
        // Use moveToActiveSpace to ensure the window shows on the current Space.
        if isFrontmostWindowFullscreen() {
            window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
        } else {
            window.collectionBehavior = [.moveToActiveSpace, .transient]
        }

        // The window is draggable via the custom header area
        window.isMovableByWindowBackground = false

        // Find the active screen for correct positioning
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen.main!

        let screenFrame = screen.frame
        let windowX = mouseLocation.x - 210
        let windowY = mouseLocation.y - 260

        // Ensure the window stays within screen bounds
        let constrainedX = max(screenFrame.minX, min(windowX, screenFrame.maxX - 420))
        let constrainedY = max(screenFrame.minY, min(windowY, screenFrame.maxY - 520))

        window.setFrameOrigin(NSPoint(x: constrainedX, y: constrainedY))

        // Show the window WITHOUT activating the app.
        // Make it key so controls like the language Picker can open their menus
        // even when the app is not active (non-activating panels allow this).
        window.orderFrontRegardless()
        window.makeKey()

        self.popupWindow = window
    }
}
