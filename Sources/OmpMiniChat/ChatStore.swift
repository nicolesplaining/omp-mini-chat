import AppKit
import Foundation
import SwiftUI

@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var recentSessions: [OmpSessionSummary] = []
    @Published var unreadSessionIDs = Set<String>()
    @Published var draft = ""
    @Published var status = "Starting…"
    @Published var currentTitle = "New OMP session"
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
    @Published var workingSessionIDs = Set<String>()

    var onHide: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleFooter: (() -> Void)?
    var onSessionsChanged: (([OmpSessionSummary]) -> Void)?
    var onSelectedSessionChanged: ((String?) -> Void)?
    var onResponseCompleted: ((String?) -> Void)?
    var onWorkingStateChanged: ((String?, Bool) -> Void)?
    var onOpenSession: ((OmpSessionSummary) -> Void)?
    var onNewSession: (() -> Void)?

    private let startupTarget: ChatStartupTarget
    private var connection: OmpRPCConnection?
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
        }
        refreshSessions()
    }

    func connect() {
        guard connection == nil else { return }
        if case .listOnly = startupTarget { return }
        startConnection()
    }

    func shutdown() {
        externalSyncTimer?.invalidate()
        externalSyncTimer = nil
        connection?.stop()
        connection = nil
    }

    func refreshSessions() {
        DispatchQueue.global(qos: .utility).async {
            let sessions = SessionCatalog.shared.listActiveSessions()
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

    func toggleFooter() {
        onToggleFooter?()
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isConnected, !isBusy, let connection else { return }
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
        connection?.request("abort", timeout: 10) { [weak self] result in
            if case .failure(let error) = result { self?.addNotice(error.localizedDescription) }
        }
    }

    func chooseModel() {
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
            switch message.role { case .user: label = "You"; case .assistant: label = "OMP"; case .notice: label = "Notice" }
            return "\(label): \(message.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyTerminalCommand() {
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
            if !parsed.isEmpty || !self.isBusy { self.messages = Array(parsed.suffix(80)) }
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
        case "agent_end":
            if event["isTerminal"] as? Bool == false { return }
            finishAgentTurn()
        case "prompt_result":
            if let id = event["id"] as? String,
               suppressedPromptResultIDs.remove(id) != nil { return }
            if event["agentInvoked"] as? Bool == false { finishLocalPrompt() }
        case "command_output":
            let text = SessionCatalog.textContent(event["content"] ?? event["message"] ?? event["output"])
            if !text.isEmpty { messages.append(ChatMessage(role: .assistant, text: text)) }
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
        raw.compactMap { item in
            guard let role = item["role"] as? String else { return nil }
            let text = SessionCatalog.textContent(item["content"])
            guard !text.isEmpty else { return nil }
            switch role {
            case "user": return ChatMessage(role: .user, text: text)
            case "assistant": return ChatMessage(role: .assistant, text: text)
            default: return nil
            }
        }
    }

    private func recomputeUnread(_ sessions: [OmpSessionSummary]) {
        if !didEstablishUnreadBaseline {
            for session in sessions where UserDefaults.standard.object(forKey: "ompMini.lastRead.\(session.id)") == nil {
                UserDefaults.standard.set(session.modifiedAt.timeIntervalSince1970, forKey: "ompMini.lastRead.\(session.id)")
            }
            didEstablishUnreadBaseline = true
        }
        unreadSessionIDs = Set(sessions.compactMap { session in
            let lastRead = UserDefaults.standard.double(forKey: "ompMini.lastRead.\(session.id)")
            return session.modifiedAt.timeIntervalSince1970 > lastRead ? session.id : nil
        })
    }

    private func addNotice(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(ChatMessage(role: .notice, text: text))
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
