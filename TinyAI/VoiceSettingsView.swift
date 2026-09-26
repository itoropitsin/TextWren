import AVFoundation
import SwiftUI

// MARK: - Shared layout

private let labelWidth: CGFloat = 130
private let controlWidth: CGFloat = 330

private struct SettingsRow<Content: View>: View {
    let label: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
                .frame(width: controlWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .hoverRowHighlight()
    }
}

private struct SettingsNote: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: labelWidth, height: 1)
            Text(text)
                .font(.caption)
                .foregroundColor(color)
                .frame(width: controlWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct TemplateEditor: View {
    @Binding var text: String
    var height: CGFloat = 70

    var body: some View {
        InsetTextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
    }
}

/// Every voice shortcut in a draft, for conflict checks.
enum VoiceHotkeySlots {
    static func all(in draft: VoiceConfiguration) -> [(id: String, name: String, hotkey: VoiceHotkey)] {
        var slots: [(String, String, VoiceHotkey)] = []
        if let hotkey = draft.transcription.dictationHotkey {
            slots.append((VoiceTrigger.dictationHotkeyId, "Dictation", hotkey))
        }
        for agent in draft.agents {
            if let hotkey = agent.hotkey {
                slots.append((VoiceTrigger.agent(agent.id).hotkeyId, agent.name, hotkey))
            }
        }
        if let hotkey = draft.live.hotkey {
            slots.append((VoiceTrigger.liveHotkeyId, "Live conversation", hotkey))
        }
        return slots
    }

    static func validationError(for shortcut: KeyboardShortcut, slotId: String, draft: VoiceConfiguration, popupHotkey: KeyboardShortcut) -> String? {
        let others = all(in: draft).filter { $0.id != slotId }.map { $0.hotkey.shortcut }
        return KeyboardMonitor.voiceValidationError(for: shortcut, popupHotkey: popupHotkey, otherVoiceHotkeys: others)
    }

    /// The first conflict in the whole draft, as a readable message.
    static func firstError(in draft: VoiceConfiguration, popupHotkey: KeyboardShortcut) -> String? {
        for slot in all(in: draft) {
            if let error = validationError(for: slot.hotkey.shortcut, slotId: slot.id, draft: draft, popupHotkey: popupHotkey) {
                return "\(slot.name) (\(slot.hotkey.displayString)): \(error)"
            }
        }
        return nil
    }
}

/// A voice shortcut: record, clear, and choose how it triggers.
private struct VoiceHotkeyField: View {
    @Binding var hotkey: VoiceHotkey?
    var allowsModes = true
    var defaultMode: HotkeyActivationMode = .holdOrToggle
    let validate: (KeyboardShortcut) -> String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KeyboardShortcutRecorder(
                    shortcut: hotkey?.shortcut ?? KeyboardShortcut(keyCode: -1, modifiers: []),
                    isInvalid: error != nil,
                    width: 200
                ) { candidate in
                    if let message = validate(candidate) {
                        error = message
                        return
                    }
                    error = nil
                    hotkey = VoiceHotkey(shortcut: candidate, mode: hotkey?.mode ?? defaultMode)
                }
                .overlay(alignment: .leading) {
                    if hotkey == nil {
                        Text("Not set")
                            .foregroundColor(.secondary)
                            .padding(.leading, 10)
                            .allowsHitTesting(false)
                            .background(Color(NSColor.controlBackgroundColor).padding(.vertical, -4))
                    }
                }
                if hotkey != nil {
                    Button("Clear") {
                        hotkey = nil
                        error = nil
                    }
                    .controlSize(.small)
                }
            }
            if allowsModes, hotkey != nil {
                Picker("", selection: Binding(
                    get: { hotkey?.mode ?? defaultMode },
                    set: { hotkey?.mode = $0 }
                )) {
                    ForEach(HotkeyActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
}

// MARK: - Voice tab

struct VoiceSettingsTab: View {
    @Binding var draft: VoiceConfiguration
    @ObservedObject var modelManager: LocalModelManager
    let popupHotkey: KeyboardShortcut
    @State private var microphoneRefresh = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription")
                        .font(.headline)

                    SettingsRow(label: "Engine") {
                        Picker("", selection: $draft.transcription.engine) {
                            ForEach(TranscriptionEngineKind.allCases) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    if draft.transcription.engine == .local {
                        ForEach(LocalTranscriptionModel.allCases) { model in
                            localModelRow(model)
                        }
                        SettingsNote(text: "Models run on this Mac with transcribe.cpp (the engine Handy uses). Audio never leaves the device.")
                    } else {
                        SettingsRow(label: "Model") {
                            Picker("", selection: $draft.transcription.openAIModel) {
                                ForEach(OpenAITranscriptionModel.all) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220)
                        }
                        SettingsNote(text: OpenAITranscriptionModel.resolve(draft.transcription.openAIModel).summary
                                     + " Uses the OpenAI key from the API tab.")
                    }

                    SettingsRow(label: "Language") {
                        Picker("", selection: $draft.transcription.language) {
                            ForEach(TranscriptionLanguage.all) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    if draft.transcription.engine == .openAI {
                        SettingsRow(label: "Vocabulary", alignment: .top) {
                            TextField("Names and terms, e.g. TinyAI, Manychat", text: $draft.transcription.vocabulary, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Dictation")
                        .font(.headline)

                    SettingsRow(label: "Shortcut", alignment: .top) {
                        VoiceHotkeyField(hotkey: $draft.transcription.dictationHotkey) { candidate in
                            VoiceHotkeySlots.validationError(for: candidate, slotId: VoiceTrigger.dictationHotkeyId,
                                                             draft: draft, popupHotkey: popupHotkey)
                        }
                    }
                    SettingsNote(text: "Hold the shortcut and speak, or tap it to start and tap again to stop. Esc cancels. The text is pasted where the cursor is.")

                    SettingsRow(label: "Clipboard") {
                        Toggle("Restore the clipboard after pasting", isOn: $draft.transcription.restoreClipboard)
                    }
                    SettingsRow(label: "Sounds") {
                        Toggle("Play start and stop sounds", isOn: $draft.transcription.soundFeedback)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone")
                        .font(.headline)
                    SettingsRow(label: "Access") {
                        HStack(spacing: 8) {
                            Image(systemName: MicrophonePermission.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(MicrophonePermission.isGranted ? .green : .orange)
                            Text(MicrophonePermission.isGranted ? "Granted" : "Required for voice features")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if !MicrophonePermission.isGranted {
                                Button(MicrophonePermission.isUndetermined ? "Allow" : "Open Settings") {
                                    if MicrophonePermission.isUndetermined {
                                        MicrophonePermission.request { _ in microphoneRefresh = UUID() }
                                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                        .id(microphoneRefresh)
                    }
                    SettingsNote(text: "Global voice shortcuts also need Accessibility and Input Monitoring (see the Hotkeys tab).")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func localModelRow(_ model: LocalTranscriptionModel) -> some View {
        let state = modelManager.state(for: model)
        let isSelected = draft.transcription.localModel == model
        return HStack(alignment: .top, spacing: 12) {
            Button {
                draft.transcription.localModel = model
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: labelWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName).fontWeight(isSelected ? .semibold : .regular)
                    Text(model.formattedSize).font(.caption).foregroundColor(.secondary)
                    if model.supportsStreaming {
                        Text("live text").font(.caption2).padding(.horizontal, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(model.useCase)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch state {
                    case .notDownloaded:
                        Button("Download") { modelManager.download(model) }.controlSize(.small)
                    case .downloading(let progress):
                        ProgressView(value: progress).frame(width: 140)
                        Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                        Button("Cancel") { modelManager.cancelDownload(model) }.controlSize(.small)
                    case .verifying:
                        ProgressView().controlSize(.small)
                        Text("Verifying…").font(.caption)
                    case .ready:
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.green)
                        Button("Delete") { modelManager.delete(model) }.controlSize(.small)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundColor(.red).lineLimit(2)
                        Button("Retry") { modelManager.download(model) }.controlSize(.small)
                    }
                }
            }
            .frame(width: controlWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { draft.transcription.localModel = model }
        .hoverRowHighlight()
    }
}

// MARK: - Agents tab

struct AgentsSettingsTab: View {
    @Binding var draft: VoiceConfiguration
    @Binding var headerSecrets: [UUID: String]
    let store: VoiceSettingsStore
    let coordinator: VoiceCoordinator
    let popupHotkey: KeyboardShortcut

    @State private var selectedConnectionId: UUID?
    @State private var selectedAgentId: UUID?
    @State private var connectionStatus: [UUID: String] = [:]
    @State private var busyConnections: Set<UUID> = []
    @State private var oauthRefresh = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionsSection
                agentsSection
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .onAppear {
            if selectedConnectionId == nil { selectedConnectionId = draft.connections.first?.id }
            if selectedAgentId == nil { selectedAgentId = draft.agents.first?.id }
        }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Menu {
                    Button("HTTP API") { addConnection(.http) }
                    Button("MCP server") { addConnection(.mcp) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("Endpoints your agents talk to: a plain HTTP API, or an MCP server whose tools the agents and the live conversation can call.")
                .font(.caption)
                .foregroundColor(.secondary)

            if draft.connections.isEmpty {
                Text("No connections yet.").foregroundColor(.secondary).padding(.vertical, 4)
            }
            ForEach(draft.connections) { connection in
                listRow(
                    title: connection.name,
                    subtitle: "\(connection.kind.displayName) · \(connection.url.isEmpty ? "no URL" : connection.url)",
                    selected: selectedConnectionId == connection.id,
                    onSelect: { selectedConnectionId = connection.id },
                    onDelete: { removeConnection(connection.id) }
                )
            }
            if let index = draft.connections.firstIndex(where: { $0.id == selectedConnectionId }) {
                connectionEditor(index: index)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    private func connectionEditor(index: Int) -> some View {
        let binding = $draft.connections[index]
        let connection = draft.connections[index]
        return VStack(alignment: .leading, spacing: 8) {
            SettingsRow(label: "Name") {
                TextField("Name", text: binding.name).textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Type") {
                Picker("", selection: binding.kind) {
                    ForEach(AgentConnectionKind.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: connection.kind) { _, kind in
                    if kind == .http && draft.connections[index].auth == .oauth {
                        draft.connections[index].auth = .none
                    }
                }
            }
            SettingsRow(label: "URL") {
                TextField(connection.kind == .mcp ? "https://example.com/mcp" : "https://example.com/agent",
                          text: binding.url)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Authorization") {
                Picker("", selection: binding.auth) {
                    ForEach(ConnectionAuthKind.allCases.filter { $0 != .oauth || connection.kind == .mcp }) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            if connection.auth == .header {
                SettingsRow(label: "Header") {
                    TextField("Authorization", text: binding.authHeaderName).textFieldStyle(.roundedBorder)
                }
                SettingsRow(label: "Value") {
                    SecureField("Bearer …", text: secretBinding(for: connection))
                        .textFieldStyle(.roundedBorder)
                }
                SettingsNote(text: "The value is stored in the Keychain.")
            }
            if connection.auth == .oauth {
                oauthRow(connection)
            }

            if connection.kind == .http {
                SettingsRow(label: "Method") {
                    Picker("", selection: binding.method) {
                        ForEach(["POST", "PUT", "GET"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                if connection.method != "GET" {
                    SettingsRow(label: "Body", alignment: .top) {
                        TemplateEditor(text: binding.bodyTemplate)
                    }
                }
                SettingsNote(text: "Placeholders: {{transcript}}, {{sessionId}}, {{language}}, {{agent}}. Values are JSON-escaped in the body.")
                SettingsRow(label: "Answer path") {
                    TextField("text or choices.0.message.content", text: binding.responseTextPath)
                        .textFieldStyle(.roundedBorder)
                }
                headersEditor(index: index)
            }
            SettingsRow(label: "Timeout") {
                Stepper(value: binding.timeoutSeconds, in: 10...1800, step: 30) {
                    Text("\(Int(connection.timeoutSeconds)) s")
                }
            }
            SettingsNote(text: "Agents may think for a while; the request waits up to this long.")

            HStack(spacing: 12) {
                Color.clear.frame(width: labelWidth, height: 1)
                Button(connection.kind == .mcp ? "Test & load tools" : "Send test") {
                    test(connection)
                }
                .disabled(busyConnections.contains(connection.id) || connection.url.isEmpty)
                if busyConnections.contains(connection.id) {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let status = connectionStatus[connection.id] {
                SettingsNote(text: status)
            }
            if connection.kind == .mcp, !connection.cachedTools.isEmpty {
                SettingsNote(text: "Tools: " + connection.cachedTools.map(\.name).joined(separator: ", "))
            }
        }
    }

    private func oauthRow(_ connection: AgentConnection) -> some View {
        let signedIn = store.oauthTokens(for: connection) != nil
        return SettingsRow(label: "Account") {
            HStack(spacing: 8) {
                Image(systemName: signedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundColor(signedIn ? .green : .secondary)
                Text(signedIn ? "Signed in" : "Not signed in").font(.caption)
                Spacer()
                if signedIn {
                    Button("Sign out") {
                        coordinator.dispatcher.signOut(connection: connection)
                        oauthRefresh = UUID()
                    }
                    .controlSize(.small)
                }
                Button(signedIn ? "Sign in again" : "Sign in with browser") {
                    signIn(connection)
                }
                .controlSize(.small)
                .disabled(connection.url.isEmpty || busyConnections.contains(connection.id))
            }
            .id(oauthRefresh)
        }
    }

    private func headersEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(label: "Extra headers") {
                Button {
                    draft.connections[index].headers.append(HTTPHeaderField())
                } label: {
                    Label("Add header", systemImage: "plus")
                }
                .controlSize(.small)
            }
            ForEach($draft.connections[index].headers) { $header in
                HStack(spacing: 6) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    TextField("Name", text: $header.name).textFieldStyle(.roundedBorder).frame(width: 120)
                    TextField("Value", text: $header.value).textFieldStyle(.roundedBorder).frame(width: 170)
                    Button {
                        draft.connections[index].headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func secretBinding(for connection: AgentConnection) -> Binding<String> {
        Binding(
            get: { headerSecrets[connection.id] ?? store.headerSecret(for: connection) },
            set: { headerSecrets[connection.id] = $0 }
        )
    }

    private func addConnection(_ kind: AgentConnectionKind) {
        var connection = AgentConnection()
        connection.kind = kind
        connection.name = kind == .mcp ? "MCP server" : "HTTP agent"
        if kind == .mcp { connection.auth = .oauth }
        draft.connections.append(connection)
        selectedConnectionId = connection.id
    }

    private func removeConnection(_ id: UUID) {
        draft.connections.removeAll { $0.id == id }
        for index in draft.agents.indices where draft.agents[index].connectionId == id {
            draft.agents[index].connectionId = nil
        }
        draft.live.mcpConnectionIds.removeAll { $0 == id }
        headerSecrets[id] = nil
        if selectedConnectionId == id { selectedConnectionId = draft.connections.first?.id }
    }

    /// Secrets are needed by the test before the draft is saved.
    private func persistSecret(for connection: AgentConnection) {
        if let secret = headerSecrets[connection.id] {
            store.setHeaderSecret(secret, for: connection)
        }
    }

    private func test(_ connection: AgentConnection) {
        persistSecret(for: connection)
        busyConnections.insert(connection.id)
        connectionStatus[connection.id] = nil
        Task { @MainActor in
            defer { busyConnections.remove(connection.id) }
            do {
                switch connection.kind {
                case .mcp:
                    let tools = try await coordinator.dispatcher.listTools(connection: connection)
                    if let index = draft.connections.firstIndex(where: { $0.id == connection.id }) {
                        draft.connections[index].cachedTools = tools
                    }
                    var saved = connection
                    saved.cachedTools = tools
                    store.updateConnection(saved)
                    connectionStatus[connection.id] = "Connected. \(tools.count) tool\(tools.count == 1 ? "" : "s") available."
                case .http:
                    let values = AgentTemplateValues(transcript: "Hello from TinyAI. Reply with a short greeting.",
                                                     sessionId: UUID().uuidString, language: "en", agentName: connection.name)
                    let answer = try await HTTPAgentClient.send(connection: connection, values: values,
                                                               secret: headerSecrets[connection.id] ?? store.headerSecret(for: connection))
                    connectionStatus[connection.id] = "Answer: " + StatusBarController.truncated(answer, 200)
                }
                oauthRefresh = UUID()
            } catch {
                connectionStatus[connection.id] = "⚠️ " + error.localizedDescription
            }
        }
    }

    private func signIn(_ connection: AgentConnection) {
        busyConnections.insert(connection.id)
        connectionStatus[connection.id] = "Continue in your browser…"
        Task { @MainActor in
            defer { busyConnections.remove(connection.id) }
            do {
                try await coordinator.dispatcher.signIn(connection: connection)
                connectionStatus[connection.id] = "Signed in."
            } catch {
                connectionStatus[connection.id] = "⚠️ " + error.localizedDescription
            }
            oauthRefresh = UUID()
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                Button {
                    var agent = AgentProfile()
                    agent.name = "Agent \(draft.agents.count + 1)"
                    agent.connectionId = draft.connections.first?.id
                    draft.agents.append(agent)
                    selectedAgentId = agent.id
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            Text("Each agent has its own shortcut: speak, the transcript goes to the agent, and its answer is shown and/or spoken.")
                .font(.caption)
                .foregroundColor(.secondary)

            if draft.agents.isEmpty {
                Text("No agents yet.").foregroundColor(.secondary).padding(.vertical, 4)
            }
            ForEach(draft.agents) { agent in
                listRow(
                    title: agent.name,
                    subtitle: [agent.hotkey?.displayString, draft.connections.first { $0.id == agent.connectionId }?.name]
                        .compactMap { $0 }.joined(separator: " · "),
                    selected: selectedAgentId == agent.id,
                    onSelect: { selectedAgentId = agent.id },
                    onDelete: {
                        draft.agents.removeAll { $0.id == agent.id }
                        draft.live.agentIdsAsTools.removeAll { $0 == agent.id }
                        if selectedAgentId == agent.id { selectedAgentId = draft.agents.first?.id }
                    }
                )
            }
            if let index = draft.agents.firstIndex(where: { $0.id == selectedAgentId }) {
                agentEditor(index: index)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    private func agentEditor(index: Int) -> some View {
        let binding = $draft.agents[index]
        let agent = draft.agents[index]
        let connection = draft.connections.first { $0.id == agent.connectionId }
        return VStack(alignment: .leading, spacing: 8) {
            SettingsRow(label: "Name") {
                TextField("Name", text: binding.name).textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Shortcut", alignment: .top) {
                VoiceHotkeyField(hotkey: binding.hotkey) { candidate in
                    VoiceHotkeySlots.validationError(for: candidate, slotId: VoiceTrigger.agent(agent.id).hotkeyId,
                                                     draft: draft, popupHotkey: popupHotkey)
                }
            }
            SettingsRow(label: "Connection") {
                Picker("", selection: binding.connectionId) {
                    Text("None").tag(UUID?.none)
                    ForEach(draft.connections) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            if connection?.kind == .mcp {
                SettingsRow(label: "Tool") {
                    if let tools = connection?.cachedTools, !tools.isEmpty {
                        Picker("", selection: binding.mcpToolName) {
                            Text("Choose a tool").tag("")
                            ForEach(tools) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    } else {
                        TextField("Tool name (use Test & load tools)", text: binding.mcpToolName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if let tool = connection?.cachedTools.first(where: { $0.name == agent.mcpToolName }), !tool.description.isEmpty {
                    SettingsNote(text: tool.description)
                }
                SettingsRow(label: "Arguments", alignment: .top) {
                    TemplateEditor(text: binding.argumentsTemplate, height: 56)
                }
                SettingsNote(text: "JSON object; {{transcript}} and {{sessionId}} are replaced.")
            }
            SettingsRow(label: "Description") {
                TextField("What this agent is good at (for the live model)", text: binding.summary)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Answer", alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show in a floating panel", isOn: binding.showPanel)
                    Toggle("Paste at the cursor", isOn: binding.pasteAtCursor)
                    Toggle("Copy to the clipboard", isOn: binding.copyToClipboard)
                }
            }
            SettingsRow(label: "Conversation") {
                Stepper(value: binding.sessionIdleMinutes, in: 1...240, step: 5) {
                    Text("Same session for \(agent.sessionIdleMinutes) min")
                }
            }
            SpeechConfigEditor(config: binding.speech, apiKeyProvider: coordinator.openAIKeyProvider)
        }
    }

    private func listRow(title: String, subtitle: String, selected: Bool, onSelect: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title).fontWeight(selected ? .semibold : .regular)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Voice settings for spoken answers.
private struct SpeechConfigEditor: View {
    @Binding var config: VoiceOutputConfig
    let apiKeyProvider: () -> String
    @State private var preview = SpeechPlayer()
    @State private var isPreviewing = false
    @State private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(label: "Speak answer") {
                Picker("", selection: $config.engine) {
                    ForEach(SpeechEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            if config.engine == .openAI {
                SettingsRow(label: "Voice") {
                    HStack {
                        Picker("", selection: $config.openAIVoice) {
                            ForEach(VoiceOutputConfig.openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Picker("", selection: $config.openAIModel) {
                            ForEach(VoiceOutputConfig.openAIModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                if config.openAIModel.hasPrefix("gpt-") {
                    SettingsRow(label: "Style") {
                        TextField("e.g. Calm, friendly, speak quickly", text: $config.instructions)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            if config.engine == .system {
                SettingsRow(label: "Voice") {
                    Picker("", selection: $config.systemVoiceIdentifier) {
                        Text("System default").tag("")
                        ForEach(SpeechPlayer.systemVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
            }
            if config.engine != .off {
                SettingsRow(label: "Speed") {
                    HStack {
                        Slider(value: $config.speed, in: 0.5...2, step: 0.1).frame(width: 160)
                        Text(String(format: "%.1f×", config.speed)).monospacedDigit().font(.caption)
                        Spacer()
                        Button(isPreviewing ? "Stop" : "Preview") {
                            if isPreviewing {
                                preview.stop()
                            } else {
                                isPreviewing = true
                                previewError = nil
                                preview.speak("Hi! This is how your agent will sound.", config: config, apiKey: apiKeyProvider()) { error in
                                    isPreviewing = false
                                    previewError = error?.localizedDescription
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if let previewError {
                    SettingsNote(text: previewError, color: .red)
                }
            }
        }
        .onDisappear { preview.stop() }
    }
}

// MARK: - Live tab

struct LiveSettingsTab: View {
    @Binding var draft: VoiceConfiguration
    let popupHotkey: KeyboardShortcut

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live conversation").font(.headline)
                    Text("A two-way voice conversation with GPT-Live-1. It keeps talking while its backend model thinks and calls your tools.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SettingsRow(label: "Shortcut", alignment: .top) {
                        VoiceHotkeyField(hotkey: $draft.live.hotkey, allowsModes: false, defaultMode: .toggle) { candidate in
                            VoiceHotkeySlots.validationError(for: candidate, slotId: VoiceTrigger.liveHotkeyId,
                                                             draft: draft, popupHotkey: popupHotkey)
                        }
                    }
                    SettingsNote(text: "Press once to start the conversation and again (or Esc) to end it.")

                    SettingsRow(label: "Voice") {
                        Picker("", selection: $draft.live.voice) {
                            ForEach(LiveAgentSettings.voices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                    SettingsRow(label: "Instructions", alignment: .top) {
                        TemplateEditor(text: $draft.live.instructions, height: 70)
                    }
                    SettingsRow(label: "Transcript") {
                        Toggle("Show the conversation in a panel", isOn: $draft.live.showTranscriptPanel)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Backend").font(.headline)
                    SettingsRow(label: "Model") {
                        Picker("", selection: $draft.live.backendModel) {
                            ForEach(ModelCatalog.models(for: .openAI)) { entry in
                                Text(entry.displayName).tag(entry.model.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                    SettingsRow(label: "Reasoning") {
                        let entry = ModelCatalog.entry(for: LLMModel(provider: .openAI, name: draft.live.backendModel))
                        Picker("", selection: $draft.live.backendReasoning) {
                            ForEach(entry?.reasoningEfforts ?? ReasoningEffort.allCases) { effort in
                                Text(effort.displayName).tag(effort.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                    SettingsRow(label: "Backend prompt", alignment: .top) {
                        TemplateEditor(text: $draft.live.backendInstructions, height: 56)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tools").font(.headline)
                    SettingsRow(label: "Web search") {
                        Toggle("Let the backend search the web", isOn: $draft.live.webSearch)
                    }
                    let mcpConnections = draft.connections.filter { $0.kind == .mcp }
                    if mcpConnections.isEmpty && draft.agents.isEmpty {
                        SettingsNote(text: "Add MCP servers or agents in the Agents tab to use them here.")
                    }
                    ForEach(mcpConnections) { connection in
                        SettingsRow(label: "MCP") {
                            Toggle(isOn: membership(connection.id, in: \.mcpConnectionIds)) {
                                Text(connection.name + (connection.cachedTools.isEmpty ? "" : " (\(connection.cachedTools.count) tools)"))
                            }
                        }
                    }
                    ForEach(draft.agents) { agent in
                        SettingsRow(label: "Agent") {
                            Toggle("Ask \(agent.name)", isOn: membership(agent.id, in: \.agentIdsAsTools))
                        }
                    }
                    SettingsNote(text: "Uses the OpenAI key from the API tab. Tool calls run on this Mac with the connection's sign-in.")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func membership(_ id: UUID, in keyPath: WritableKeyPath<LiveAgentSettings, [UUID]>) -> Binding<Bool> {
        Binding(
            get: { draft.live[keyPath: keyPath].contains(id) },
            set: { isOn in
                draft.live[keyPath: keyPath].removeAll { $0 == id }
                if isOn { draft.live[keyPath: keyPath].append(id) }
            }
        )
    }
}
