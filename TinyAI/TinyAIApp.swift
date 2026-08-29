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

    static var userDefaults: UserDefaults {
        guard isTestEnvironment else { return .standard }
        return UserDefaults(suiteName: testDefaultsSuite) ?? .standard
    }

    static func isTestEnvironment(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.contains("--ui-testing") || environment["TINYAI_TEST_MODE"] == "1" {
            return true
        }
        if environment["XCInjectBundleInto"] != nil || environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return environment.keys.contains { $0.hasPrefix("XCTest") }
    }
}

/// Permission requests are deliberately limited to one attempt per missing
/// permission during a process lifetime.  A new process may ask again when
/// access is still genuinely missing, while an update with preserved TCC
/// state does not ask at all.
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
            case .accessibility: granted = accessibilityGranted
            case .inputMonitoring: granted = inputMonitoringGranted
            }
            return !granted && !requested.contains(permission)
        }
    }

    @discardableResult
    static func requestMissing() -> Bool {
        guard !TinyAIRuntime.isTestEnvironment else { return allGranted }

        let requestable = requestablePermissions(
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted,
            requested: requestedThisProcess
        )
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

    #if DEBUG
    static func resetRequestStateForTesting() {
        requestedThisProcess.removeAll()
    }
    #endif
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
                .onAppear {
                    appDelegate.translationService = translationService
                    appDelegate.keyboardMonitor = keyboardMonitor
                    keyboardMonitor.onPopupHotkey = { [weak appDelegate] payload in
                        appDelegate?.showTranslationPopup(with: payload)
                    }
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

// Keep this subclass concrete. A generic NSHostingView subclass can trigger a
// Swift optimizer crash while synthesising its deinit.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var popupWindow: NSWindow?
    weak var translationService: TranslationService?
    var keyboardMonitor: KeyboardMonitor?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinyAI", category: "AppDelegate")
    private var permissionObserver: NSObjectProtocol?

    func isFrontmostWindowFullscreen() -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()

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

        requestMissingPermissionsAtLaunch()
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            // Returning from System Settings may have changed TCC state.  A
            // foreground transition only re-checks; requestMissing() itself
            // remains guarded by its one-attempt-per-process policy.
            self?.startKeyboardMonitoringIfPermitted()
        }
        startKeyboardMonitoringIfPermitted()
    }

    deinit {
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
        }
    }

    private func requestMissingPermissionsAtLaunch() {
        guard !TinyAIPermissions.allGranted else {
            startKeyboardMonitoringIfPermitted()
            return
        }

        _ = TinyAIPermissions.requestMissing()
        if !TinyAIPermissions.allGranted {
            logger.notice("Accessibility and Input Monitoring permissions are required for global hotkeys")
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
