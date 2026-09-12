import AppKit
import Foundation
import SwiftUI

@MainActor
final class ChatStore: ObservableObject {
    private static let transcriptItemLimit = 240

    @Published var messages: [ChatMessage] = []
    @Published var recentSessions: [OmpSessionSummary] = []
    @Published var liveSessions: [LiveSessionSummary] = []
    @Published var unreadSessionIDs = Set<String>()
    @Published var draft = ""
    @Published var status = "Starting…"
    @Published var currentTitle = "New chat"
    @Published var currentProject = ""
    @Published var currentModel = "No model"
    @Published var selectedSessionID: String?
    @Published var isConnected = false
    @Published var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            onWorkingStateChanged?(selectedSessionID, isBusy)
        }
    }
    @Published var isTransitioning = false
    @Published var isPinned = true
    @Published var isFooterVisible = true
    @Published var openSessionIDs = Set<String>()
    @Published var workingSessionIDs = Set<String>()
    @Published var isReadOnlyCollab = false
    @Published var terminal: EmbeddedTerminalSession?
    @Published var showsTerminal = false
    var onOpenTerminal: (() -> Void)?

    func openTerminal() {
        if terminal != nil { showsTerminal = true }
        else { onOpenTerminal?() }
    }

    var isCollabSession: Bool {
        if case .collab = startupTarget { return true }
        return false
    }

    var canSubmit: Bool {
        let isCommand = draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
        return (isConnected || isCommand) && !isTransitioning && !isReadOnlyCollab && (!isBusy || isCollabSession)
    }

    var onHide: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleFooter: (() -> Void)?
    var onSessionsChanged: (([OmpSessionSummary]) -> Void)?
    var onSelectedSessionChanged: ((String?) -> Void)?
    var onResponseCompleted: ((String?) -> Void)?
    var onWorkingStateChanged: ((String?, Bool) -> Void)?
    var onOpenSession: ((OmpSessionSummary) -> Void)?
    var onNewSession: (() -> Void)?
    var onJoinCollab: (() -> Void)?
    var onLiveMetadataChanged: ((String, String, String) -> Void)?
    var onOpenLiveSession: ((LiveSessionSummary) -> Void)?
    var onCollabUnavailable: ((String) -> Void)?

    private let startupTarget: ChatStartupTarget
    private var connection: OmpRPCConnection?
    private var collabConnection: OmpCollabConnection?
    private var collabLink: OmpCollabLink?
    private var collabEntries: [[String: Any]] = []
    private var collabSnapshotEntries: [[String: Any]] = []
    private var collabSnapshotComplete = false
    private var sessionPath: String?
    private var cwd: String
    private var streamingMessageID: UUID?
    private var pendingPromptID: String?
    private var didEstablishUnreadBaseline = false
    private var externalSyncTimer: Timer?
    private var lastObservedFileSignature: String?
    private var isSynchronizingFromDisk = false
    private var supportsLeafNavigation = false
    private var suppressedPromptResultIDs = Set<String>()
    private var activeToolContexts: [String: ActiveToolContext] = [:]

    private var managesUnread: Bool {
        if case .listOnly = startupTarget { return true }
        return false
    }

    init(target: ChatStartupTarget) {
        startupTarget = target
        switch target {
        case .listOnly:
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
            status = "Ready"
            isConnected = true
        case .session(let session):
            cwd = session.cwd
            sessionPath = session.path
            selectedSessionID = session.id
            currentTitle = session.title
            currentProject = session.projectName
        case .newSession(let directory):
            cwd = directory
            currentProject = URL(fileURLWithPath: directory).lastPathComponent
        case .collab(let link, let session):
            cwd = session?.cwd ?? ""
            collabLink = link
            sessionPath = session?.path
            selectedSessionID = session?.id ?? link.sessionID
            currentTitle = session?.title ?? "New chat"
            currentProject = session?.projectName ?? "Encrypted relay"
            status = "Connecting…"
        }
        refreshSessions()
    }

    func connect() {
        guard connection == nil else { return }
        if terminal != nil && !isCollabSession { return }
        if case .listOnly = startupTarget { return }
        startConnection()
    }

    func shutdown() {
        externalSyncTimer?.invalidate()
        externalSyncTimer = nil
        connection?.stop()
        connection = nil
        collabConnection?.close()
        collabConnection = nil
    }

    func releaseForTerminal(completion: @escaping () -> Void) {
        externalSyncTimer?.invalidate()
        externalSyncTimer = nil
        isTransitioning = true
        if let connection {
            self.connection = nil
            connection.stop(completion: completion)
        } else { completion() }
    }

    var terminalCwd: String { cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : cwd }
    var terminalSessionPath: String? { sessionPath }

    func refreshSessions() {
        DispatchQueue.global(qos: .utility).async {
            let sessions = SessionCatalog.shared.listSessions()
            DispatchQueue.main.async {
                self.recentSessions = sessions
                if self.managesUnread { self.recomputeUnread(sessions) }
                self.onSessionsChanged?(sessions)
            }
        }
    }

    func markRead(_ id: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ompMini.lastRead.\(id)")
        unreadSessionIDs.remove(id)
    }

    func markUnread(_ id: String) {
        unreadSessionIDs.insert(id)
    }

    func setWorking(_ working: Bool, for sessionID: String?) {
        guard let sessionID else { return }
        if working { workingSessionIDs.insert(sessionID) }
        else { workingSessionIDs.remove(sessionID) }
    }

    func openSession(_ summary: OmpSessionSummary) {
        markRead(summary.id)
        onOpenSession?(summary)
    }

    func createSession() {
        onNewSession?()
    }

    func joinCollab() {
        onJoinCollab?()
    }

    func openLiveSession(_ summary: LiveSessionSummary) {
        markRead(summary.id)
        onOpenLiveSession?(summary)
    }

    func upsertLiveSession(id: String, title: String, projectName: String) {
        let summary = LiveSessionSummary(id: id, title: title, projectName: projectName)
        if let index = liveSessions.firstIndex(where: { $0.id == id }) { liveSessions[index] = summary }
        else { liveSessions.append(summary) }
    }

    func replaceLiveSessions(_ sessions: [LiveSessionSummary]) {
        liveSessions = sessions
    }

    func toggleFooter() {
        onToggleFooter?()
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/"), (!isConnected || isCollabSession) {
            openTerminal()
            return
        }
        guard !text.isEmpty, canSubmit else { return }
        if text == "/login" { draft = ""; login(); return }
        if text == "/model" { draft = ""; chooseModel(); return }
        if text == "/terminal" { openTerminal(); return }
        if isCollabSession {
            draft = ""
            collabConnection?.sendPrompt(text)
            status = isBusy ? "Steering…" : "Sent…"
            return
        }
        guard let connection else { return }
        if hasUnseenDiskChanges() {
            synchronizeFromDisk { [weak self] in self?.sendDraft() }
            return
        }
        draft = ""
        messages.append(ChatMessage(role: .user, text: text))
        isBusy = true
        status = "Thinking…"
        connection.request("prompt", parameters: ["message": text], timeout: 45) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.pendingPromptID = response["id"] as? String
                let data = response["data"] as? [String: Any]
                if data?["agentInvoked"] as? Bool == false { self.finishLocalPrompt() }
            case .failure(let error):
                self.isBusy = false
                self.status = "Ready"
                self.draft = text
                self.addNotice(error.localizedDescription)
            }
        }
    }

    func stopTurn() {
        if isCollabSession {
            collabConnection?.sendAbort()
            status = "Stopping…"
            return
        }
        connection?.request("abort", timeout: 10) { [weak self] result in
            if case .failure(let error) = result { self?.addNotice(error.localizedDescription) }
        }
    }

    func chooseModel() {
        if isCollabSession || !isConnected {
            openTerminal()
            return
        }
        guard let connection else { return }
        status = "Loading models…"
        connection.request("get_available_models", timeout: 60) { [weak self] result in
            guard let self else { return }
            self.status = self.isBusy ? "Thinking…" : "Ready"
            switch result {
            case .failure(let error): self.addNotice(error.localizedDescription)
            case .success(let response):
                let data = response["data"] as? [String: Any]
                let models = data?["models"] as? [[String: Any]] ?? []
                self.presentModelPicker(models)
            }
        }
    }

    func login() {
        if isCollabSession || !isConnected {
            openTerminal()
            return
        }
        guard let connection else { return }
        status = "Checking sign-in…"
        connection.request("get_login_providers", timeout: 60) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.status = "Ready"
                self.addNotice(error.localizedDescription)
            case .success(let response):
                let data = response["data"] as? [String: Any]
                let providers = (data?["providers"] as? [[String: Any]] ?? []).filter { $0["available"] as? Bool != false }
                self.presentLoginPicker(providers)
            }
        }
    }

    func copyTranscript() {
        let text = messages.map { message in
            let label: String
            switch message.role {
            case .user: label = "You"
            case .assistant: label = "OMP"
            case .notice: label = "Notice"
            case .tool: label = "Tool · \(message.title ?? "OMP")"
            case .thinking: label = "Thinking"
            case .status: label = message.title ?? "Status"
            }
            return "\(label): \(message.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyTerminalCommand() {
        if let collabLink {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(collabLink.original, forType: .string)
            status = "Live link copied"
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installedOMP = home.appendingPathComponent(".local/bin/omp")
        let executable: String
        if FileManager.default.isExecutableFile(atPath: installedOMP.path) {
            executable = installedOMP.path
        } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("omp").path {
            executable = bundled
        } else {
            executable = "omp"
        }
        let command = "cd \(Self.shellQuote(cwd)) && \(Self.shellQuote(executable))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        status = "Terminal command copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.isBusy, self.status == "Terminal command copied" else { return }
            self.status = "Ready"
        }
    }

    private func startConnection() {
        if let collabLink {
            startCollabConnection(collabLink)
            return
        }
        let rpc = OmpRPCConnection()
        connection = rpc
        isTransitioning = true
        status = sessionPath == nil ? "Starting session…" : "Opening session…"
        rpc.onEvent = { [weak self] event in self?.handleEvent(event) }
        rpc.onExtensionUIRequest = { [weak self] request in self?.handleExtensionUI(request) }
        rpc.onExit = { [weak self] message in
            self?.isConnected = false
            self?.isBusy = false
            self?.isTransitioning = false
            self?.status = "Disconnected"
            self?.addNotice(message)
        }
        rpc.start(sessionPath: sessionPath, cwd: cwd) { [weak self] result in
            guard let self else { return }
            self.isTransitioning = false
            switch result {
            case .failure(let error):
                self.status = "Couldn’t open"
                self.addNotice(error.localizedDescription)
            case .success:
                self.isConnected = true
                self.status = "Ready"
                self.prepareConnectedSession()
            }
        }
    }

    private func startCollabConnection(_ link: OmpCollabLink) {
        guard collabConnection == nil else { return }
        isTransitioning = true
        isConnected = false
        status = "Connecting…"
        let collab = OmpCollabConnection(link: link)
        collabConnection = collab
        collab.onPhaseChanged = { [weak self] phase, _ in
            guard let self else { return }
            self.status = phase
            if phase.hasPrefix("Connection lost") || phase == "Reconnecting…" {
                self.isConnected = false
                self.isTransitioning = true
            } else if !["Connecting…", "Waiting for host…"].contains(phase) {
                self.isConnected = false
                self.isTransitioning = false
                self.isBusy = false
                self.addNotice(phase)
                if phase == "No such live room"
                    || phase == "Room closed"
                    || phase == "Timed out waiting for the OMP host" {
                    self.onCollabUnavailable?(phase)
                }
            }
        }
        collab.onFrame = { [weak self] frame in self?.handleCollabFrame(frame) }
        collab.connect()
    }

    private func handleCollabFrame(_ frame: [String: Any]) {
        guard let type = frame["t"] as? String else { return }
        switch type {
        case "welcome":
            collabSnapshotEntries = []
            collabSnapshotComplete = false
            isReadOnlyCollab = frame["readOnly"] as? Bool == true
            if let header = frame["header"] as? [String: Any] {
                applyCollabMetadata(header: header, state: frame["state"] as? [String: Any])
            }
            if let state = frame["state"] as? [String: Any] { applyCollabState(state, notifyCompletion: false) }
            if frame["entryCount"] as? Int == 0 { finishCollabSnapshot() }

        case "snapshot-chunk":
            if let entries = frame["entries"] as? [[String: Any]] { collabSnapshotEntries.append(contentsOf: entries) }
            if frame["final"] as? Bool == true { finishCollabSnapshot() }

        case "entry":
            guard collabSnapshotComplete, let entry = frame["entry"] as? [String: Any] else { return }
            collabEntries.append(entry)
            let message = entry["message"] as? [String: Any]
            let isAssistantMessage = entry["type"] as? String == "message" && message?["role"] as? String == "assistant"
            rebuildCollabMessages(preservingStream: !isAssistantMessage)

        case "event":
            if let event = frame["event"] as? [String: Any] { handleCollabEvent(event) }

        case "state":
            if let state = frame["state"] as? [String: Any] {
                applyCollabMetadata(header: nil, state: state)
                applyCollabState(state, notifyCompletion: true)
            }

        case "ui-request":
            if terminal != nil {
                // The owned TUI already renders and answers this dialog. Do not
                // open a competing native alert for the same request.
                showsTerminal = true
                return
            }
            if let request = frame["request"] as? [String: Any] { presentCollabRequest(request) }

        case "error":
            addNotice(frame["message"] as? String ?? "The OMP host reported an error.")

        case "bye":
            isConnected = false
            isTransitioning = false
            isBusy = false
            status = "Session ended"
            addNotice(frame["reason"] as? String ?? "The live session ended.")

        default: break
        }
    }

    private func finishCollabSnapshot() {
        collabEntries = collabSnapshotEntries
        collabSnapshotEntries = []
        collabSnapshotComplete = true
        streamingMessageID = nil
        messages = Array(parseCollabEntries(collabEntries).suffix(Self.transcriptItemLimit))
        updateCollabTitle()
        isConnected = true
        isTransitioning = false
        status = isReadOnlyCollab ? "Live · read only" : "Live"
        if let id = selectedSessionID { onLiveMetadataChanged?(id, currentTitle, currentProject) }
    }

    private func applyCollabMetadata(header: [String: Any]?, state: [String: Any]?) {
        if let title = state?["sessionName"] as? String ?? header?["title"] as? String, !title.isEmpty {
            currentTitle = title
        }
        if let hostCwd = state?["cwd"] as? String ?? header?["cwd"] as? String, !hostCwd.isEmpty {
            cwd = hostCwd
            let project = URL(fileURLWithPath: hostCwd).lastPathComponent
            currentProject = project.isEmpty ? hostCwd : project
        }
        if let model = state?["model"] as? [String: Any],
           let provider = model["provider"] as? String,
           let id = model["id"] as? String {
            currentModel = "\(provider) / \(id)"
        }
        if let id = selectedSessionID { onLiveMetadataChanged?(id, currentTitle, currentProject) }
    }

    private func applyCollabState(_ state: [String: Any], notifyCompletion: Bool) {
        let busy = state["isStreaming"] as? Bool == true
        setCollabBusy(busy, notifyCompletion: notifyCompletion)
        guard collabSnapshotComplete else { return }
        if busy {
            status = state["isAborting"] as? Bool == true ? "Stopping…" : "Thinking…"
        } else {
            let participants = (state["participants"] as? [[String: Any]])?.count ?? 1
            status = participants > 1 ? "Live · \(participants) connected" : (isReadOnlyCollab ? "Live · read only" : "Live")
        }
    }

    private func setCollabBusy(_ busy: Bool, notifyCompletion: Bool) {
        let wasBusy = isBusy
        isBusy = busy
        if notifyCompletion, wasBusy, !busy {
            onResponseCompleted?(selectedSessionID)
        }
    }

    private func handleCollabEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "agent_start":
            setCollabBusy(true, notifyCompletion: false)
            status = "Thinking…"
        case "agent_end":
            setCollabBusy(false, notifyCompletion: true)
            status = isReadOnlyCollab ? "Live · read only" : "Live"
        case "message_start", "message_update":
            guard let message = event["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return }
            let text = SessionCatalog.textContent(message["content"])
            if !text.isEmpty { setCollabStreaming(text) }
        case "message_end":
            guard let message = event["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return }
            let text = SessionCatalog.textContent(message["content"])
            if !text.isEmpty { finishStreaming(with: text) }
        case "tool_execution_start":
            updateToolMessage(from: event, phase: .started)
        case "tool_execution_update":
            updateToolMessage(from: event, phase: .updated)
        case "tool_execution_end":
            updateToolMessage(from: event, phase: .finished)
        case "notice":
            addNotice(event["message"] as? String ?? "OMP notification")
        case "auto_retry_start":
            status = "Retrying…"
            let attempt = event["attempt"] as? Int ?? 1
            let maximum = event["maxAttempts"] as? Int ?? attempt
            let reason = event["errorMessage"] as? String ?? "The model request failed."
            addStatus(title: "Retry \(attempt)/\(maximum)", text: reason, isError: true)
        case "auto_retry_end":
            if event["success"] as? Bool == false {
                addStatus(title: "Retry failed", text: event["finalError"] as? String ?? "OMP could not recover.", isError: true)
            }
        case "auto_compaction_start":
            status = "Compacting…"
            addStatus(title: "Compacting context", text: event["reason"] as? String ?? "Preparing more context space.")
        case "auto_compaction_end":
            if event["aborted"] as? Bool == true,
               let error = event["errorMessage"] as? String {
                addStatus(title: "Compaction stopped", text: error, isError: true)
            }
        default: break
        }
    }

    private func setCollabStreaming(_ fullText: String) {
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = fullText
            messages[index].isStreaming = true
        } else {
            let message = ChatMessage(role: .assistant, text: fullText, isStreaming: true)
            streamingMessageID = message.id
            messages.append(message)
        }
    }

    private func updateCollabTitle() {
        if let title = collabEntries.reversed().first(where: { ["title", "title_change"].contains($0["type"] as? String ?? "") })?["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentTitle = title
        } else if currentTitle == "New chat",
                  let firstUser = collabEntries.compactMap({ $0["message"] as? [String: Any] })
                    .first(where: { $0["role"] as? String == "user" }) {
            let text = SessionCatalog.textContent(firstUser["content"])
            if let line = text.split(whereSeparator: \.isNewline).first {
                currentTitle = String(line.prefix(80))
            }
        }
        if let id = selectedSessionID { onLiveMetadataChanged?(id, currentTitle, currentProject) }
    }

    private func rebuildCollabMessages(preservingStream: Bool) {
        updateCollabTitle()
        let stream = preservingStream ? streamingMessageID.flatMap { id in messages.first(where: { $0.id == id }) } : nil
        messages = Array(parseCollabEntries(collabEntries).suffix(Self.transcriptItemLimit))
        if let stream { messages.append(stream) }
        else { streamingMessageID = nil }
    }

    private func parseCollabEntries(_ entries: [[String: Any]]) -> [ChatMessage] {
        let rawMessages = entries.compactMap { entry -> [String: Any]? in
            guard entry["type"] as? String == "message" else { return nil }
            return entry["message"] as? [String: Any]
        }
        let toolResults = collectToolResults(rawMessages)
        let knownToolCalls = collectToolCallIDs(rawMessages)

        return entries.flatMap { entry -> [ChatMessage] in
            switch entry["type"] as? String {
            case "message":
                guard let message = entry["message"] as? [String: Any],
                      let role = message["role"] as? String else { return [] }
                if role == "toolResult",
                   let callID = message["toolCallId"] as? String,
                   knownToolCalls.contains(callID) { return [] }
                return renderWireMessage(message, toolResults: toolResults)
            case "custom_message":
                guard entry["display"] as? Bool != false else { return [] }
                let text = SessionCatalog.textContent(entry["content"])
                guard !text.isEmpty else { return [] }
                if entry["customType"] as? String == "collab-prompt" {
                    return [ChatMessage(role: .user, text: text)]
                }
                return [ChatMessage(
                    role: .notice,
                    title: entry["customType"] as? String,
                    text: text
                )]
            case "compaction":
                let summary = entry["shortSummary"] as? String ?? entry["summary"] as? String ?? "Earlier context was summarized."
                let tokens = entry["tokensBefore"] as? Int
                let title = tokens.map { "Context compacted · \(Self.formatTokenCount($0)) tokens" } ?? "Context compacted"
                return [ChatMessage(role: .status, title: title, text: summary)]
            case "branch_summary":
                return [ChatMessage(
                    role: .status,
                    title: "Branch summary",
                    text: entry["summary"] as? String ?? "The conversation continued from another branch."
                )]
            case "model_change":
                guard let model = entry["model"] as? String else { return [] }
                return [ChatMessage(role: .status, title: "Model changed", text: model)]
            case "thinking_level_change":
                let level = entry["thinkingLevel"] as? String ?? "default"
                return [ChatMessage(role: .status, title: "Thinking level", text: level)]
            default: return []
            }
        }
    }

    private func presentCollabRequest(_ request: [String: Any]) {
        guard !isReadOnlyCollab, let requestID = request["reqId"] as? Int else { return }
        let alert = NSAlert()
        alert.messageText = request["title"] as? String ?? "OMP needs input"
        if request["kind"] as? String == "select" {
            let rawOptions = request["options"] as? [Any] ?? []
            let options = rawOptions.compactMap { option -> String? in
                if let text = option as? String { return text }
                return (option as? [String: Any])?["label"] as? String
            }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            popup.addItems(withTitles: options)
            if let initial = request["initialIndex"] as? Int, options.indices.contains(initial) { popup.selectItem(at: initial) }
            alert.accessoryView = popup
            alert.addButton(withTitle: "Submit")
            alert.addButton(withTitle: "Cancel")
            let value = alert.runModal() == .alertFirstButtonReturn && popup.indexOfSelectedItem >= 0
                ? options[popup.indexOfSelectedItem]
                : nil
            collabConnection?.sendUIResponse(requestID: requestID, value: value)
        } else {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            field.stringValue = request["prefill"] as? String ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "Submit")
            alert.addButton(withTitle: "Cancel")
            let value = alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
            collabConnection?.sendUIResponse(requestID: requestID, value: value)
        }
    }

    private func prepareConnectedSession() {
        connection?.request("get_available_commands") { [weak self] result in
            guard let self else { return }
            if case .success(let response) = result,
               let data = response["data"] as? [String: Any],
               let commands = data["commands"] as? [[String: Any]] {
                self.supportsLeafNavigation = commands.contains { $0["name"] as? String == "mini-sync-leaf" }
            }
            if self.sessionPath != nil, self.supportsLeafNavigation {
                self.synchronizeFromDisk { self.startExternalSyncTimer() }
            } else {
                self.refreshStateAndHistory()
                self.startExternalSyncTimer()
            }
        }
    }

    private func refreshStateAndHistory() {
        refreshState()
        reloadHistory()
    }

    private func refreshState() {
        connection?.request("get_state") { [weak self] result in
            guard let self, case .success(let response) = result,
                  let data = response["data"] as? [String: Any] else { return }
            if let id = data["sessionId"] as? String {
                let didChangeSession = self.selectedSessionID != id
                self.selectedSessionID = id
                if didChangeSession { self.onSelectedSessionChanged?(id) }
            }
            if let file = data["sessionFile"] as? String { self.sessionPath = file }
            if let name = data["sessionName"] as? String, !name.isEmpty { self.currentTitle = name }
            if let model = data["model"] as? [String: Any],
               let provider = model["provider"] as? String,
               let id = model["id"] as? String {
                self.currentModel = "\(provider) / \(id)"
            } else {
                self.currentModel = "Choose model"
            }
            if data["isStreaming"] as? Bool == true {
                self.isBusy = true
                self.status = "Thinking…"
            }
            self.refreshSessions()
        }
    }

    private func reloadHistory(rememberSignature: Bool = true, completion: (() -> Void)? = nil) {
        connection?.request("get_messages", timeout: 60) { [weak self] result in
            guard let self else { completion?(); return }
            guard case .success(let response) = result,
                  let data = response["data"] as? [String: Any],
                  let rawMessages = data["messages"] as? [[String: Any]] else {
                completion?()
                return
            }
            let parsed = self.parseMessages(rawMessages)
            if !parsed.isEmpty || !self.isBusy {
                self.messages = Array(parsed.suffix(Self.transcriptItemLimit))
            }
            if rememberSignature { self.rememberCurrentFileSignature() }
            completion?()
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "agent_start", "turn_start":
            isBusy = true
            status = "Thinking…"
        case "message_update":
            guard let assistantEvent = event["assistantMessageEvent"] as? [String: Any],
                  assistantEvent["type"] as? String == "text_delta",
                  let delta = assistantEvent["delta"] as? String else { return }
            appendStreaming(delta)
        case "message_end":
            if let raw = event["message"] as? [String: Any],
               raw["role"] as? String == "assistant" {
                let text = SessionCatalog.textContent(raw["content"])
                if !text.isEmpty { finishStreaming(with: text) }
            }
        case "tool_execution_start":
            updateToolMessage(from: event, phase: .started)
        case "tool_execution_update":
            updateToolMessage(from: event, phase: .updated)
        case "tool_execution_end":
            updateToolMessage(from: event, phase: .finished)
        case "agent_end":
            if event["isTerminal"] as? Bool == false { return }
            finishAgentTurn()
        case "prompt_result":
            if let id = event["id"] as? String,
               suppressedPromptResultIDs.remove(id) != nil { return }
            if event["agentInvoked"] as? Bool == false { finishLocalPrompt() }
        case "command_output":
            let text = SessionCatalog.textContent(event["content"] ?? event["message"] ?? event["output"])
            if !text.isEmpty { messages.append(ChatMessage(role: .tool, title: "Command output", text: text)) }
        case "auto_retry_start":
            status = "Retrying…"
            let attempt = event["attempt"] as? Int ?? 1
            let maximum = event["maxAttempts"] as? Int ?? attempt
            addStatus(
                title: "Retry \(attempt)/\(maximum)",
                text: event["errorMessage"] as? String ?? "The model request failed.",
                isError: true
            )
        case "auto_retry_end":
            if event["success"] as? Bool == false {
                addStatus(title: "Retry failed", text: event["finalError"] as? String ?? "OMP could not recover.", isError: true)
            }
        case "auto_compaction_start":
            status = "Compacting…"
            addStatus(title: "Compacting context", text: event["reason"] as? String ?? "Preparing more context space.")
        case "auto_compaction_end":
            if event["aborted"] as? Bool == true,
               let error = event["errorMessage"] as? String {
                addStatus(title: "Compaction stopped", text: error, isError: true)
            }
        case "model_changed": refreshState()
        case "session_switch":
            if !isSynchronizingFromDisk { refreshStateAndHistory() }
        case "extension_error":
            addNotice(event["error"] as? String ?? "An OMP extension failed.")
        case "notice":
            addNotice(event["message"] as? String ?? "OMP reported an issue.")
        case "async_command_error":
            if event["command"] as? String == "prompt" {
                isBusy = false
                status = "Ready"
            }
            addNotice(event["message"] as? String ?? "An OMP command failed.")
        default: break
        }
    }

    private func finishAgentTurn() {
        isBusy = false
        status = "Ready"
        streamingMessageID = nil
        pendingPromptID = nil
        reloadHistory()
        refreshState()
        onResponseCompleted?(selectedSessionID)
    }

    private func finishLocalPrompt() {
        isBusy = false
        status = "Ready"
        pendingPromptID = nil
        reloadHistory()
        refreshState()
        onResponseCompleted?(selectedSessionID)
    }

    private func appendStreaming(_ delta: String) {
        if let id = streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += delta
        } else {
            let message = ChatMessage(role: .assistant, text: delta, isStreaming: true)
            streamingMessageID = message.id
            messages.append(message)
        }
    }

    private func finishStreaming(with text: String) {
        if let id = streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
            messages[index].isStreaming = false
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
        streamingMessageID = nil
    }

    private func parseMessages(_ raw: [[String: Any]]) -> [ChatMessage] {
        let toolResults = collectToolResults(raw)
        let knownToolCalls = collectToolCallIDs(raw)
        return raw.flatMap { message -> [ChatMessage] in
            if message["role"] as? String == "toolResult",
               let callID = message["toolCallId"] as? String,
               knownToolCalls.contains(callID) { return [] }
            return renderWireMessage(message, toolResults: toolResults)
        }
    }

    private func collectToolResults(_ messages: [[String: Any]]) -> [String: [String: Any]] {
        var results: [String: [String: Any]] = [:]
        for message in messages where message["role"] as? String == "toolResult" {
            if let callID = message["toolCallId"] as? String { results[callID] = message }
        }
        return results
    }

    private func collectToolCallIDs(_ messages: [[String: Any]]) -> Set<String> {
        var ids = Set<String>()
        for message in messages where message["role"] as? String == "assistant" {
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "toolCall" {
                if let callID = block["id"] as? String { ids.insert(callID) }
            }
        }
        return ids
    }

    private func renderWireMessage(
        _ message: [String: Any],
        toolResults: [String: [String: Any]]
    ) -> [ChatMessage] {
        guard let role = message["role"] as? String else { return [] }
        switch role {
        case "user":
            let text = SessionCatalog.textContent(message["content"])
            return text.isEmpty ? [] : [ChatMessage(role: .user, text: text)]

        case "assistant":
            guard let blocks = message["content"] as? [[String: Any]] else {
                let text = SessionCatalog.textContent(message["content"])
                return text.isEmpty ? [] : [ChatMessage(role: .assistant, text: text)]
            }
            var rendered: [ChatMessage] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text", "input_text", "output_text":
                    guard let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    rendered.append(ChatMessage(role: .assistant, text: text))
                case "thinking":
                    guard let text = block["thinking"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    rendered.append(ChatMessage(role: .thinking, title: "Thinking", text: text))
                case "redactedThinking":
                    rendered.append(ChatMessage(role: .thinking, title: "Thinking · redacted", text: "Redacted by the model provider."))
                case "toolCall":
                    guard let callID = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "tool"
                    let result = toolResults[callID]
                    rendered.append(ChatMessage(
                        role: .tool,
                        title: name,
                        text: Self.formatToolBody(
                            intent: block["intent"] as? String,
                            arguments: block["arguments"],
                            result: result,
                            running: result == nil
                        ),
                        isStreaming: result == nil,
                        isError: result?["isError"] as? Bool == true,
                        detailID: callID
                    ))
                default: continue
                }
            }
            if let stopReason = message["stopReason"] as? String,
               ["error", "aborted", "length"].contains(stopReason) {
                let detail = message["errorMessage"] as? String ?? "The response ended with \(stopReason)."
                rendered.append(ChatMessage(
                    role: .status,
                    title: stopReason == "error" ? "Response error" : "Response \(stopReason)",
                    text: detail,
                    isError: stopReason == "error"
                ))
            }
            return rendered

        case "toolResult":
            let callID = message["toolCallId"] as? String
            return [ChatMessage(
                role: .tool,
                title: message["toolName"] as? String ?? "tool",
                text: Self.formatToolBody(intent: nil, arguments: nil, result: message, running: false),
                isError: message["isError"] as? Bool == true,
                detailID: callID
            )]

        default: return []
        }
    }

    private struct ActiveToolContext {
        var name: String
        var intent: String?
        var arguments: Any?
    }

    private enum ToolPhase { case started, updated, finished }

    private func updateToolMessage(from event: [String: Any], phase: ToolPhase) {
        guard let callID = event["toolCallId"] as? String else { return }
        var context = activeToolContexts[callID] ?? ActiveToolContext(
            name: event["toolName"] as? String ?? "tool",
            intent: nil,
            arguments: nil
        )
        if let name = event["toolName"] as? String { context.name = name }
        if let intent = event["intent"] as? String { context.intent = intent }
        if let arguments = event["args"] { context.arguments = arguments }
        if phase != .finished { activeToolContexts[callID] = context }

        let result: Any?
        switch phase {
        case .started: result = nil
        case .updated: result = event["partialResult"]
        case .finished: result = event["result"]
        }
        let running = phase != .finished
        let body = Self.formatToolBody(
            intent: context.intent,
            arguments: context.arguments,
            result: result,
            running: running
        )
        if let index = messages.lastIndex(where: { $0.role == .tool && $0.detailID == callID }) {
            messages[index].title = context.name
            messages[index].text = body
            messages[index].isStreaming = running
            messages[index].isError = event["isError"] as? Bool == true
        } else {
            messages.append(ChatMessage(
                role: .tool,
                title: context.name,
                text: body,
                isStreaming: running,
                isError: event["isError"] as? Bool == true,
                detailID: callID
            ))
        }
        if phase == .finished { activeToolContexts.removeValue(forKey: callID) }
    }

    private static func formatToolBody(
        intent: String?,
        arguments: Any?,
        result: Any?,
        running: Bool
    ) -> String {
        var sections: [String] = []
        if let intent = intent?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty {
            sections.append(intent)
        }
        let input = displayValue(arguments)
        if !input.isEmpty && input != "{}" { sections.append("Input\n\(input)") }
        let output = displayToolResult(result)
        if !output.isEmpty { sections.append("Output\n\(output)") }
        else if running { sections.append("Running…") }
        else { sections.append("Completed with no output") }
        return sections.joined(separator: "\n\n")
    }

    private static func displayToolResult(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let object = value as? [String: Any] {
            let content = SessionCatalog.textContent(object["content"])
            if !content.isEmpty { return content }
            for key in ["output", "message", "text"] {
                let nested = displayValue(object[key])
                if !nested.isEmpty { return nested }
            }
            if let details = object["details"] { return displayValue(details) }
        }
        return displayValue(value)
    }

    private static func displayValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let blocks = value as? [[String: Any]] {
            let text = SessionCatalog.textContent(blocks)
            if !text.isEmpty { return text }
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return String(count)
    }

    private func recomputeUnread(_ sessions: [OmpSessionSummary]) {
        if !didEstablishUnreadBaseline {
            for session in sessions where UserDefaults.standard.object(forKey: "ompMini.lastRead.\(session.id)") == nil {
                UserDefaults.standard.set(session.modifiedAt.timeIntervalSince1970, forKey: "ompMini.lastRead.\(session.id)")
            }
            didEstablishUnreadBaseline = true
        }
        let liveUnread = unreadSessionIDs.filter { $0.hasPrefix("collab:") }
        unreadSessionIDs = Set(sessions.compactMap { session in
            let lastRead = UserDefaults.standard.double(forKey: "ompMini.lastRead.\(session.id)")
            return session.modifiedAt.timeIntervalSince1970 > lastRead ? session.id : nil
        }).union(liveUnread)
    }

    private func addNotice(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(ChatMessage(role: .notice, text: text))
    }

    private func addStatus(title: String, text: String, isError: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(ChatMessage(role: .status, title: title, text: text, isError: isError))
    }

    private func presentLoginPicker(_ providers: [[String: Any]]) {
        guard !providers.isEmpty else {
            status = "Ready"
            addNotice("No sign-in providers are available in this OMP build.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to OMP"
        alert.informativeText = "Choose an account provider. Your browser may open to finish authentication."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        providers.forEach { provider in
            let authenticated = provider["authenticated"] as? Bool == true ? " — signed in" : ""
            popup.addItem(withTitle: "\(provider["name"] as? String ?? provider["id"] as? String ?? "Provider")\(authenticated)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { status = "Ready"; return }
        let provider = providers[max(0, popup.indexOfSelectedItem)]
        guard let providerID = provider["id"] as? String else { status = "Ready"; return }
        status = "Signing in…"
        connection?.request("login", parameters: ["providerId": providerID], timeout: 600) { [weak self] result in
            guard let self else { return }
            self.status = "Ready"
            switch result {
            case .failure(let error): self.addNotice(error.localizedDescription)
            case .success:
                self.addNotice("Signed in. Choose a model if OMP did not select one automatically.")
                self.refreshState()
            }
        }
    }

    private func presentModelPicker(_ models: [[String: Any]]) {
        guard !models.isEmpty else { addNotice("No models are available yet. Sign in first."); return }
        let alert = NSAlert()
        alert.messageText = "Choose an OMP model"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for model in models {
            let provider = model["provider"] as? String ?? ""
            let id = model["id"] as? String ?? "Unknown"
            popup.addItem(withTitle: "\(provider) / \(id)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Model")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let model = models[max(0, popup.indexOfSelectedItem)]
        guard let provider = model["provider"] as? String, let id = model["id"] as? String else { return }
        connection?.request("set_model", parameters: ["provider": provider, "modelId": id], timeout: 60) { [weak self] result in
            switch result {
            case .failure(let error): self?.addNotice(error.localizedDescription)
            case .success: self?.refreshState()
            }
        }
    }

    private func handleExtensionUI(_ request: [String: Any]) {
        guard let method = request["method"] as? String else { return }
        let id = request["id"] as? String
        switch method {
        case "open_url":
            if let raw = request["launchUrl"] as? String ?? request["url"] as? String,
               let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        case "notify":
            addNotice(request["message"] as? String ?? "OMP notification")
        case "setStatus":
            status = request["text"] as? String ?? request["status"] as? String ?? status
        case "setTitle":
            if let title = request["title"] as? String, !title.isEmpty { currentTitle = title }
        case "set_editor_text":
            draft = request["text"] as? String ?? draft
        case "confirm":
            let confirmed = runAlert(request, choices: ["Continue", "Cancel"]) == .alertFirstButtonReturn
            respondToUI(id: id, ["confirmed": confirmed])
        case "select":
            presentExtensionSelect(request, id: id)
        case "input", "editor":
            presentExtensionInput(request, id: id)
        case "cancel":
            if let id { respondToUI(id: id, ["cancelled": true]) }
        default: break
        }
    }

    private func runAlert(_ request: [String: Any], choices: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = request["title"] as? String ?? "OMP"
        alert.informativeText = request["message"] as? String ?? ""
        choices.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    private func presentExtensionSelect(_ request: [String: Any], id: String?) {
        let options = request["options"] as? [String] ?? []
        guard !options.isEmpty else { respondToUI(id: id, ["cancelled": true]); return }
        let alert = NSAlert()
        alert.messageText = request["title"] as? String ?? "Choose"
        alert.informativeText = request["message"] as? String ?? ""
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        popup.addItems(withTitles: options)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            respondToUI(id: id, ["value": options[max(0, popup.indexOfSelectedItem)]])
        } else { respondToUI(id: id, ["cancelled": true]) }
    }

    private func presentExtensionInput(_ request: [String: Any], id: String?) {
        let alert = NSAlert()
        alert.messageText = request["title"] as? String ?? "OMP needs input"
        alert.informativeText = request["message"] as? String ?? ""
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = request["placeholder"] as? String
        field.stringValue = request["initialValue"] as? String ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            respondToUI(id: id, ["value": field.stringValue])
        } else { respondToUI(id: id, ["cancelled": true]) }
    }

    private func respondToUI(id: String?, _ values: [String: Any]) {
        guard let id else { return }
        var response = values
        response["type"] = "extension_ui_response"
        response["id"] = id
        connection?.send(response)
    }

    private func startExternalSyncTimer() {
        guard externalSyncTimer == nil else { return }
        externalSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForExternalChanges() }
        }
        rememberCurrentFileSignature()
    }

    private func pollForExternalChanges() {
        guard !isBusy, !isTransitioning, !isSynchronizingFromDisk, hasUnseenDiskChanges() else { return }
        synchronizeFromDisk()
    }

    private func hasUnseenDiskChanges() -> Bool {
        guard let signature = currentFileSignature() else { return false }
        guard let lastObservedFileSignature else {
            self.lastObservedFileSignature = signature
            return false
        }
        return signature != lastObservedFileSignature
    }

    private func currentFileSignature() -> String? {
        guard let sessionPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: sessionPath),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return "\(modified.timeIntervalSince1970):\(size.uint64Value)"
    }

    private func rememberCurrentFileSignature() {
        if let signature = currentFileSignature() { lastObservedFileSignature = signature }
    }

    private func synchronizeFromDisk(completion: (() -> Void)? = nil) {
        guard !isSynchronizingFromDisk, !isBusy, let connection, let sessionPath else {
            completion?()
            return
        }
        isSynchronizingFromDisk = true
        isTransitioning = true
        status = "Syncing terminal changes…"
        rememberCurrentFileSignature()
        connection.request("switch_session", parameters: ["sessionPath": sessionPath], timeout: 45) { [weak self] result in
            guard let self else { completion?(); return }
            switch result {
            case .failure(let error):
                self.isSynchronizingFromDisk = false
                self.isTransitioning = false
                self.status = "Sync failed"
                self.addNotice(error.localizedDescription)
                completion?()
            case .success(let response):
                let data = response["data"] as? [String: Any]
                if data?["cancelled"] as? Bool == true {
                    self.isSynchronizingFromDisk = false
                    self.isTransitioning = false
                    self.status = "Sync cancelled"
                    completion?()
                    return
                }
                self.refreshState()
                self.navigateToLatestDiskLeaf {
                    self.reloadHistory(rememberSignature: false) {
                        self.isSynchronizingFromDisk = false
                        self.isTransitioning = false
                        self.status = "Ready"
                        self.refreshSessions()
                        completion?()
                    }
                }
            }
        }
    }

    private func navigateToLatestDiskLeaf(completion: @escaping () -> Void) {
        guard supportsLeafNavigation, let sessionPath else {
            completion()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let entryID = SessionCatalog.shared.latestNonExitEntryID(atPath: sessionPath)
            DispatchQueue.main.async {
                guard let entryID, let connection = self.connection else {
                    completion()
                    return
                }
                let requestID = "mini_leaf_\(UUID().uuidString)"
                self.suppressedPromptResultIDs.insert(requestID)
                connection.request(
                    "prompt",
                    parameters: ["message": "/mini-sync-leaf \(entryID)"],
                    timeout: 45,
                    requestID: requestID
                ) { [weak self] result in
                    guard let self else { completion(); return }
                    if case .failure(let error) = result {
                        self.suppressedPromptResultIDs.remove(requestID)
                        self.addNotice("Couldn’t select the newest terminal history: \(error.localizedDescription)")
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            self?.suppressedPromptResultIDs.remove(requestID)
                        }
                    }
                    completion()
                }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
