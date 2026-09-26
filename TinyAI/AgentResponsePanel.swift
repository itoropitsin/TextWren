import AppKit
import SwiftUI

/// The floating panel with an agent's answer or the live conversation.
struct AgentResponseView: View {
    @ObservedObject var coordinator: VoiceCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if case .live = coordinator.state {
                liveTranscript
            } else if coordinator.response == nil && !coordinator.liveTurns.isEmpty {
                liveTranscript
            } else if let response = coordinator.response {
                answer(response)
            } else {
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 340, minHeight: 280)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: StatusBarController.symbolName(for: coordinator.state))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if coordinator.state.isBusy {
                Button("Stop") { coordinator.cancel() }
                    .controlSize(.small)
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .frame(height: 22)
    }

    private var title: String {
        if case .live = coordinator.state { return "Live conversation" }
        if let response = coordinator.response { return response.title }
        return coordinator.liveTurns.isEmpty ? "TinyAI" : "Live conversation"
    }

    private func answer(_ response: AgentResponseContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(response.question)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Divider()
            if response.answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(StatusBarController.statusText(for: coordinator.state))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                MarkdownTextView(markdown: response.answer, placeholder: "")
                    .foregroundStyle(response.isError ? .red : .primary)
                HStack {
                    Button("Copy") { TextInserter.copy(response.answer) }
                    Button("Insert") { coordinator.insertCurrentResponse() }
                        .help("Paste the answer where the cursor was")
                    Spacer()
                    if coordinator.isSpeakingResponse {
                        Button("Stop Speaking") { coordinator.stopSpeaking() }
                    } else {
                        Button("Speak") { coordinator.speakCurrentResponse() }
                            .disabled(coordinator.state.isBusy || response.isError)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.liveTurns) { turn in
                        Text(turn.text)
                            .font(turn.role == .tool ? .caption : .body)
                            .foregroundStyle(turn.role == .user ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
                            .textSelection(.enabled)
                            .id(turn.id)
                    }
                }
            }
            .onChange(of: coordinator.liveTurns) { _, turns in
                if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

final class AgentResponsePanelController {
    private var window: NSWindow?
    private let coordinator: VoiceCoordinator

    init(coordinator: VoiceCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if let window {
            window.orderFrontRegardless()
            return
        }
        let view = AgentResponseView(coordinator: coordinator) { [weak self] in
            self?.coordinator.dismissResponse()
            self?.hide()
        }
        let hostingView = NSHostingView(rootView: view)
        let size = NSSize(width: 420, height: 360)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 14
        hostingView.layer?.masksToBounds = true

        let panel = DraggableWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 340, height: 260)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 20, y: frame.maxY - size.height - 20))
        }
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.close()
        window = nil
    }
}
