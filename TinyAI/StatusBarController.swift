import AppKit
import Combine

/// The menu bar icon: shows what the voice features are doing and offers
/// the voice actions, cancel, and the app windows.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: VoiceCoordinator
    private let openMainWindow: () -> Void
    private let openSettings: () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var pulseTimer: Timer?
    private var pulseOn = false
    private var hud: StatusHUDController?

    init(coordinator: VoiceCoordinator, openMainWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openMainWindow = openMainWindow
        self.openSettings = openSettings
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imageScaling = .scaleProportionallyDown

        hud = StatusHUDController(coordinator: coordinator) { [weak self] in
            self?.statusItem.button?.window?.frame
        }

        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
        coordinator.modelManager.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render(self?.coordinator.state ?? .idle) }
            .store(in: &cancellables)
    }

    static func symbolName(for state: VoiceState) -> String {
        switch state {
        case .idle: return "waveform"
        case .recording: return "mic.fill"
        case .transcribing: return "text.bubble"
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2.fill"
        case .live(let phase):
            switch phase {
            case .connecting: return "antenna.radiowaves.left.and.right"
            case .listening: return "waveform.circle"
            case .speaking: return "waveform.circle.fill"
            case .usingTool: return "wrench.and.screwdriver"
            case .ended: return "waveform"
            }
        case .error: return "exclamationmark.triangle"
        }
    }

    static func statusText(for state: VoiceState) -> String {
        switch state {
        case .idle: return "Ready"
        case .recording(.dictation): return "Listening for dictation…"
        case .recording(.agent): return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking(let agent): return "\(agent) is thinking…"
        case .speaking: return "Speaking the answer"
        case .live(let phase):
            switch phase {
            case .connecting: return "Live: connecting…"
            case .listening: return "Live: listening"
            case .speaking: return "Live: speaking"
            case .usingTool(let tool): return "Live: using \(tool)"
            case .ended: return "Live ended"
            }
        case .error(let message): return message
        }
    }

    private func render(_ state: VoiceState) {
        guard let button = statusItem.button else { return }
        let symbol = Self.symbolName(for: state)
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: Self.statusText(for: state))
        let tint: NSColor?
        switch state {
        case .recording: tint = .systemRed
        case .error: tint = .systemOrange
        default: tint = nil
        }
        if let tint {
            // A coloured image, not a tinted template: menu bar templates are
            // drawn monochrome in some appearances.
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.toolTip = "TinyAI — \(Self.statusText(for: state))"

        let shouldPulse: Bool
        if case .recording = state { shouldPulse = true } else { shouldPulse = false }
        if shouldPulse, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulseOn.toggle()
                self.statusItem.button?.alphaValue = self.pulseOn ? 0.45 : 1
            }
        } else if !shouldPulse {
            pulseTimer?.invalidate()
            pulseTimer = nil
            button.alphaValue = 1
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = coordinator.state
        let store = coordinator.store

        let status = NSMenuItem(title: Self.statusText(for: state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let preview = coordinator.partialTranscript.isEmpty ? coordinator.lastTranscript : coordinator.partialTranscript
        if !preview.isEmpty {
            let item = NSMenuItem(title: "“\(Self.truncated(preview, 60))”", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !coordinator.recentTranscripts.isEmpty {
            let recent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for text in coordinator.recentTranscripts {
                let item = actionItem(Self.truncated(text, 60), #selector(copyRecent(_:)))
                item.representedObject = text
                item.toolTip = "Copy to clipboard"
                submenu.addItem(item)
            }
            recent.submenu = submenu
            menu.addItem(recent)
        }
        if coordinator.response != nil {
            menu.addItem(actionItem("Show Last Answer", #selector(showAnswer)))
        }
        if state.isBusy {
            menu.addItem(actionItem("Cancel", #selector(cancel)))
        }
        menu.addItem(.separator())

        let dictation = actionItem(
            recordingTitle("Dictate", trigger: .dictation, hotkey: store.transcription.dictationHotkey),
            #selector(toggleDictation)
        )
        menu.addItem(dictation)
        for agent in store.agents {
            let item = actionItem(recordingTitle("Ask \(agent.name)", trigger: .agent(agent.id), hotkey: agent.hotkey),
                                  #selector(toggleAgent(_:)))
            item.representedObject = agent.id
            menu.addItem(item)
        }
        let liveTitle = coordinator.isLiveActive ? "End Live Conversation" : "Start Live Conversation"
        menu.addItem(actionItem(liveTitle + (store.live.hotkey.map { "  \($0.displayString)" } ?? ""), #selector(toggleLive)))
        menu.addItem(.separator())

        let engineTitle: String
        if store.transcription.engine == .local {
            let model = store.transcription.localModel
            switch coordinator.modelManager.state(for: model) {
            case .downloading(let progress):
                engineTitle = "\(model.displayName): downloading \(Int(progress * 100))%"
            case .verifying:
                engineTitle = "\(model.displayName): verifying…"
            case .ready:
                engineTitle = "Local: \(model.displayName)"
            case .notDownloaded:
                engineTitle = "\(model.displayName): not downloaded"
            case .failed(let message):
                engineTitle = "\(model.displayName): \(message)"
            }
        } else {
            engineTitle = "OpenAI: \(OpenAITranscriptionModel.resolve(store.transcription.openAIModel).displayName)"
        }
        let engine = NSMenuItem(title: engineTitle, action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)
        menu.addItem(.separator())

        menu.addItem(actionItem("Open TinyAI", #selector(openMain)))
        menu.addItem(actionItem("Settings…", #selector(openSettingsWindow)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TinyAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func recordingTitle(_ base: String, trigger: VoiceTrigger, hotkey: VoiceHotkey?) -> String {
        var title = base
        if case .recording(let active) = coordinator.state, active == trigger {
            title = "Stop Recording"
        }
        if let hotkey { title += "  \(hotkey.displayString)" }
        return title
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    static func truncated(_ text: String, _ length: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > length ? String(single.prefix(length)) + "…" : single
    }

    @objc private func toggleDictation() { coordinator.toggleFromMenu(.dictation) }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.toggleFromMenu(.agent(id))
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.copy(text)
    }

    @objc private func toggleLive() { coordinator.toggleLive() }
    @objc private func cancel() { coordinator.cancel() }
    @objc private func showAnswer() { coordinator.onShowPanel?() }
    @objc private func openMain() { openMainWindow() }
    @objc private func openSettingsWindow() { openSettings() }
}
