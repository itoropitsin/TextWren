import AppKit
import Combine
import SwiftUI

/// The small dark popup under the menu bar icon: recording progress, live
/// text, errors, and transcripts that had no text field to go to.
struct StatusHUDView: View {
    @ObservedObject var coordinator: VoiceCoordinator
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if showsClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .background(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(isResult ? 8 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let text = coordinator.unplacedTranscript, isResult {
                HStack {
                    Button(copied ? "Copied" : "Copy") {
                        TextInserter.copy(text)
                        copied = true
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .onChange(of: coordinator.unplacedTranscript) { _, _ in copied = false }
    }

    private var isResult: Bool {
        !coordinator.state.isBusy && coordinator.unplacedTranscript != nil
    }

    private var showsClose: Bool {
        if case .error = coordinator.state { return true }
        return isResult
    }

    @ViewBuilder private var icon: some View {
        switch coordinator.state {
        case .recording:
            RecordingIndicator(level: coordinator.inputLevel)
        case .transcribing, .thinking:
            ProgressView().controlSize(.small).tint(.white)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
                .font(.system(size: 16, weight: .semibold))
        default:
            Image(systemName: "text.bubble")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private var title: String {
        switch coordinator.state {
        case .recording(.dictation): return "Listening…"
        case .recording(.agent(let id)): return "Ask \(coordinator.store.agent(id: id)?.name ?? "agent")…"
        case .transcribing: return "Transcribing…"
        case .thinking(let agent): return "\(agent) is thinking…"
        case .error: return "Something went wrong"
        default: return "No text field focused"
        }
    }

    private var detail: String? {
        switch coordinator.state {
        case .recording:
            let live = coordinator.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return live.isEmpty ? "Speak now. Release or press again to finish, Esc to cancel." : live
        case .transcribing:
            let live = coordinator.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return live.isEmpty ? nil : live
        case .thinking:
            return coordinator.lastTranscript.isEmpty ? nil : coordinator.lastTranscript
        case .error(let message):
            return message
        default:
            return coordinator.unplacedTranscript
        }
    }
}

/// A red dot with bars that follow the microphone level.
private struct RecordingIndicator: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            ForEach(0..<4, id: \.self) { index in
                let boost = CGFloat(min(1, level * 12)) * [0.6, 1, 0.8, 0.5][index]
                Capsule()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 3, height: 4 + 12 * boost)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Shows the popup under the status item while something is worth showing.
final class StatusHUDController {
    private let coordinator: VoiceCoordinator
    private let anchor: () -> NSRect?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<StatusHUDView>?
    private var cancellables: Set<AnyCancellable> = []
    private var autoHide: DispatchWorkItem?

    init(coordinator: VoiceCoordinator, anchor: @escaping () -> NSRect?) {
        self.coordinator = coordinator
        self.anchor = anchor
        coordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the new value is stored.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private var shouldShow: Bool {
        switch coordinator.state {
        case .recording, .transcribing, .error:
            return true
        case .thinking:
            return false // the answer panel shows progress
        default:
            return coordinator.unplacedTranscript != nil
        }
    }

    private func refresh() {
        guard shouldShow else {
            hide()
            return
        }
        show()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHide?.cancel()
        let delay: TimeInterval
        if case .error = coordinator.state {
            delay = 6
        } else if !coordinator.state.isBusy, coordinator.unplacedTranscript != nil {
            delay = 30
        } else {
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func close() {
        coordinator.dismissUnplacedTranscript()
        hide()
    }

    private func show() {
        if panel == nil {
            let view = StatusHUDView(coordinator: coordinator) { [weak self] in self?.close() }
            let hosting = NSHostingView(rootView: view)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = hosting
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .statusBar
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            self.panel = panel
            hostingView = hosting
        }
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let origin = Self.origin(for: size, below: anchor())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        autoHide?.cancel()
        panel?.orderOut(nil)
    }

    /// Centre the popup under the menu bar icon, kept on screen.
    static func origin(for size: NSSize, below anchor: NSRect?) -> NSPoint {
        let screen = NSScreen.screens.first { anchor.map($0.frame.intersects) ?? false } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorRect = anchor ?? NSRect(x: visible.maxX - 60, y: visible.maxY, width: 24, height: 0)
        var x = anchorRect.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let y = min(anchorRect.minY, visible.maxY) - size.height - 6
        return NSPoint(x: x, y: y)
    }
}
