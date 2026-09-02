import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - App-server transport

enum AppServerError: LocalizedError {
    case codexNotFound
    case notRunning
    case invalidResponse
    case timeout(String)
    case server(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex CLI was not found. Install Codex or the ChatGPT desktop app."
        case .notRunning:
            return "The Codex connection is not running."
        case .invalidResponse:
            return "Codex returned an invalid response."
        case .timeout(let method):
            return "Codex did not answer \(method) in time. You can try again."
        case .server(let message), .process(let message):
            return message
        }
    }
}

final class AppServerConnection {
    typealias JSONObject = [String: Any]
    typealias Completion = (Result<JSONObject, Error>) -> Void

    var onNotification: ((String, JSONObject) -> Void)?
    var onExit: ((String) -> Void)?
    var onServerRequest: ((String, JSONObject, @escaping (JSONObject) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "mini-chat.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var nextID = 1
    private final class PendingRequest {
        let completion: Completion
        var timeoutWorkItem: DispatchWorkItem?

        init(completion: @escaping Completion) {
            self.completion = completion
        }
    }

    private var pending: [Int: PendingRequest] = [:]
    private var stderrTail = ""

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.process == nil else {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            guard let executable = Self.findCodex() else {
                DispatchQueue.main.async { completion(.failure(AppServerError.codexNotFound)) }
                return
            }

            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.consume(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                self?.queue.async {
                    guard let self else { return }
                    self.stderrTail = String((self.stderrTail + text).suffix(4000))
                }
            }
            process.terminationHandler = { [weak self] process in
                self?.queue.async { self?.handleExit(code: process.terminationStatus) }
            }

            do {
                try process.run()
                self.process = process
                self.input = stdinPipe.fileHandleForWriting
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            self.requestLocked(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_mini_chat",
                        "title": "Codex Mini Chat",
                        "version": "2.3.0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ) { result in
                switch result {
                case .success:
                    self.queue.async {
                        self.sendLocked(["method": "initialized", "params": [:]])
                        DispatchQueue.main.async { completion(.success(())) }
                    }
                case .failure(let error):
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    func request(
        method: String,
        params: JSONObject = [:],
        timeout: TimeInterval = 30,
        completion: @escaping Completion
    ) {
        queue.async {
            self.requestLocked(method: method, params: params, timeout: timeout, completion: completion)
        }
    }

    func stop() {
        queue.async {
            self.outputBuffer.removeAll()
            for request in self.pending.values {
                request.timeoutWorkItem?.cancel()
            }
            self.pending.removeAll()
            self.input?.closeFile()
            self.input = nil
            if self.process?.isRunning == true { self.process?.terminate() }
            self.process = nil
        }
    }

    private func requestLocked(
        method: String,
        params: JSONObject,
        timeout: TimeInterval = 15,
        completion: @escaping Completion
    ) {
        guard process?.isRunning == true, input != nil else {
            completion(.failure(AppServerError.notRunning))
            return
        }
        let id = nextID
        nextID += 1
        let request = PendingRequest(completion: completion)
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let expired = self.pending.removeValue(forKey: id) else { return }
            expired.completion(.failure(AppServerError.timeout(method)))
        }
        request.timeoutWorkItem = timeoutWorkItem
        pending[id] = request
        sendLocked(["method": method, "id": id, "params": params])
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
    }

    private func sendLocked(_ object: JSONObject) {
        guard let input,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            handleExit(code: -1, override: error.localizedDescription)
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = value as? JSONObject else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONObject) {
        if let number = message["id"] as? NSNumber {
            let id = number.intValue
            if let method = message["method"] as? String {
                let params = message["params"] as? JSONObject ?? [:]
                guard let onServerRequest else {
                    sendLocked([
                        "id": id,
                        "error": [
                            "code": -32601,
                            "message": "Mini Chat cannot handle \(method)."
                        ]
                    ])
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    onServerRequest(method, params) { result in
                        self?.queue.async {
                            self?.sendLocked(["id": id, "result": result])
                        }
                    }
                }
                return
            }
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timeoutWorkItem?.cancel()
            if let error = message["error"] as? JSONObject {
                request.completion(.failure(AppServerError.server(error["message"] as? String ?? "Codex request failed.")))
            } else if let result = message["result"] as? JSONObject {
                request.completion(.success(result))
            } else {
                request.completion(.failure(AppServerError.invalidResponse))
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? JSONObject ?? [:]
        DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
    }

    private func handleExit(code: Int32, override: String? = nil) {
        guard process != nil else { return }
        let detail = override ?? stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? "Codex App Server exited (\(code))." : detail
        let callbacks = Array(pending.values)
        pending.removeAll()
        process = nil
        input = nil
        callbacks.forEach {
            $0.timeoutWorkItem?.cancel()
            $0.completion(.failure(AppServerError.process(message)))
        }
        DispatchQueue.main.async { [weak self] in self?.onExit?(message) }
    }

    private static func findCodex() -> String? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Conversation model

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, notice }
    let id: UUID
    var itemID: String?
    let role: Role
    var text: String
    var isStreaming: Bool

    init(id: UUID = UUID(), itemID: String? = nil, role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.itemID = itemID
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

struct RecentThread: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let updatedAt: Int
}

enum ChatStartupTarget {
    case lastUsed
    case listOnly
    case thread(RecentThread)
    case newChat
}

@MainActor
final class ChatStore: ObservableObject {
    private static let maxDisplayCharacters = 12_000
    private static let truncationNotice = "\n\n[Message shortened in Mini Chat. Open Codex to see the full text.]"
    private static let activeWindow: TimeInterval = 2 * 24 * 60 * 60

    @Published var messages: [ChatMessage] = []
    @Published var recentThreads: [RecentThread] = []
    @Published var currentThreadID: String?
    @Published private(set) var selectedThreadID: String? {
        didSet {
            if selectedThreadID != oldValue {
                onSelectedThreadChanged?(selectedThreadID)
            }
        }
    }
    @Published private(set) var unreadThreadIDs: Set<String> = []
    @Published private(set) var visiblePopupThreadIDs: Set<String> = []
    @Published var currentTitle = "Mini Chat"
    @Published var draft = ""
    @Published var status = "Connecting…"
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var isTransitioning = false
    @Published var isPinned = true

    var onHide: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onThreadsChanged: (() -> Void)?
    var onSelectedThreadChanged: ((String?) -> Void)?
    var onResponseCompleted: ((String) -> Void)?

    private let startupTarget: ChatStartupTarget
    private let connection = AppServerConnection()
    private var activeTurnID: String?
    private var readOnlySource: RecentThread?
    private var knownThreadRecency: [String: Int] = [:]
    private var hasLoadedThreadList = false
    private var isLoadingThreads = false
    private var isPopupVisible = true
    private var hasConnected = false
    private var didPerformStartup = false
    private var currentCwd = ""
    private var queuedSyncToken: UUID?
    private var queuedSubmissionID: String?

    private var ownedThreadIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "ownedThreadIDs") ?? [])
    }

    init(startupTarget: ChatStartupTarget = .lastUsed) {
        self.startupTarget = startupTarget
        connection.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        connection.onExit = { [weak self] message in
            guard let self else { return }
            self.isConnected = false
            self.isBusy = false
            self.isTransitioning = false
            self.clearWriteConflict()
            self.status = "Disconnected"
            self.addNotice(message)
        }
        connection.onServerRequest = { [weak self] method, params, respond in
            guard let self else {
                if method == "item/permissions/requestApproval" {
                    respond(["permissions": [:]])
                } else {
                    respond(["decision": "decline"])
                }
                return
            }
            self.handleServerRequest(method: method, params: params, respond: respond)
        }
    }

    func connect() {
        guard !hasConnected else { return }
        hasConnected = true
        status = "Connecting…"
        connection.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.isConnected = true
                    if self.didPerformStartup {
                        self.status = "Ready"
                        self.loadRecentThreads()
                        return
                    }
                    self.didPerformStartup = true
                    switch self.startupTarget {
                    case .lastUsed:
                        self.status = "Loading chats…"
                        self.loadRecentThreads(autoResume: true)
                    case .listOnly:
                        self.status = "Ready"
                        self.loadRecentThreads()
                    case .thread(let thread):
                        self.status = "Opening chat…"
                        self.resume(thread)
                        self.loadRecentThreads()
                    case .newChat:
                        self.status = "Starting chat…"
                        self.createNewChat()
                    }
                case .failure(let error):
                    self.status = "Connection failed"
                    self.addNotice(error.localizedDescription)
                }
            }
        }
    }

    func loadRecentThreads(autoResume: Bool = false) {
        guard isConnected, !isLoadingThreads else { return }
        isLoadingThreads = true
        connection.request(
            method: "thread/list",
            params: ["limit": 100, "sortKey": "recency_at", "sortDirection": "desc"]
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingThreads = false
                switch result {
                case .success(let payload):
                    let data = payload["data"] as? [[String: Any]] ?? []
                    let cutoff = Int(Date().timeIntervalSince1970 - Self.activeWindow)
                    let activeThreads = data
                        .compactMap(Self.parseThreadSummary)
                        .filter {
                            !$0.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && $0.updatedAt >= cutoff
                        }
                        .sorted { $0.updatedAt > $1.updatedAt }
                    if self.hasLoadedThreadList {
                        for thread in activeThreads {
                            guard let previous = self.knownThreadRecency[thread.id],
                                  thread.updatedAt > previous else { continue }
                            let isVisibleHere = thread.id == self.selectedThreadID && self.isPopupVisible
                            if !isVisibleHere && !self.visiblePopupThreadIDs.contains(thread.id) {
                                self.unreadThreadIDs.insert(thread.id)
                            }
                        }
                    }
                    self.knownThreadRecency.merge(
                        activeThreads.reduce(into: [:]) { $0[$1.id] = $1.updatedAt },
                        uniquingKeysWith: { _, new in new }
                    )
                    self.hasLoadedThreadList = true
                    self.recentThreads = activeThreads
                    self.onThreadsChanged?()
                    if autoResume {
                        let remembered = UserDefaults.standard.string(forKey: "lastThreadID")
                        if let remembered,
                           let chosen = self.recentThreads.first(where: { $0.id == remembered }) {
                            self.resume(chosen)
                        } else if let mostRecent = self.recentThreads.first {
                            self.resume(mostRecent)
                        } else {
                            // A dedicated thread avoids competing with an active Codex desktop writer.
                            self.createNewChat()
                        }
                    }
                case .failure(let error):
                    self.status = "Couldn’t load chats"
                    self.addNotice(error.localizedDescription)
                }
            }
        }
    }

    func resume(_ thread: RecentThread) {
        guard !isBusy, !isTransitioning else { return }
        clearWriteConflict()
        selectedThreadID = thread.id
        markThreadRead(thread.id)
        if currentThreadID == thread.id, readOnlySource == nil {
            status = "Ready"
            return
        }

        isTransitioning = true
        status = "Opening chat…"
        currentTitle = thread.title
        messages = []

        // Reading does not claim the rollout's single-writer lease. Mini Chat claims
        // it only while sending, then releases it so Codex can continue immediately.
        readThread(thread)
    }

    private func resumeOwnedThread(_ thread: RecentThread) {
        connection.request(
            method: "thread/resume",
            params: ["threadId": thread.id],
            timeout: 30
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    guard let object = payload["thread"] as? [String: Any] else {
                        self.addNotice(AppServerError.invalidResponse.localizedDescription)
                        self.isTransitioning = false
                        return
                    }
                    self.readOnlySource = nil
                    self.currentThreadID = object["id"] as? String ?? thread.id
                    self.selectedThreadID = self.currentThreadID
                    self.currentTitle = Self.threadTitle(object)
                    self.messages = Self.parseHistory(object)
                    self.status = "Ready"
                    self.isTransitioning = false
                    UserDefaults.standard.set(self.currentThreadID, forKey: "lastThreadID")
                case .failure(let error):
                    let message = error.localizedDescription.lowercased()
                    if message.contains("active writer") || message.contains("no rollout found") {
                        self.readThread(thread)
                    } else {
                        self.status = "Couldn’t open chat"
                        self.isTransitioning = false
                        self.addNotice(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func readThread(_ source: RecentThread) {
        connection.request(
            method: "thread/read",
            params: ["threadId": source.id, "includeTurns": true],
            timeout: 30
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    guard let thread = payload["thread"] as? [String: Any] else {
                        self.status = "Couldn’t open chat"
                        self.isTransitioning = false
                        self.addNotice(AppServerError.invalidResponse.localizedDescription)
                        return
                    }
                    self.currentThreadID = nil
                    self.readOnlySource = source
                    self.currentCwd = source.cwd
                    self.selectedThreadID = source.id
                    self.currentTitle = source.title
                    self.messages = Self.parseHistory(thread)
                    self.addNotice("Viewing this Codex task. Sending continues this exact task and never creates a branch.")
                    self.status = "Ready"
                    self.isTransitioning = false
                case .failure(let error):
                    self.status = "Couldn’t open chat"
                    self.isTransitioning = false
                    self.addNotice(error.localizedDescription)
                }
            }
        }
    }

    private func continueOriginal(_ source: RecentThread, sendAfter text: String) {
        guard !isBusy, !isTransitioning else { return }
        isTransitioning = true
        status = "Continuing chat…"
        connection.request(
            method: "thread/resume",
            params: ["threadId": source.id],
            timeout: 30
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    guard let thread = payload["thread"] as? [String: Any] else {
                        self.status = "Couldn’t continue chat"
                        self.isTransitioning = false
                        self.draft = text
                        self.addNotice(AppServerError.invalidResponse.localizedDescription)
                        return
                    }
                    guard let id = thread["id"] as? String, id == source.id else {
                        self.status = "Couldn’t continue chat"
                        self.isTransitioning = false
                        self.draft = text
                        self.addNotice("Codex returned a different task, so Mini Chat stopped before sending.")
                        return
                    }
                    let resumedTitle = Self.threadTitle(thread)
                    self.currentThreadID = id
                    self.readOnlySource = nil
                    self.currentCwd = thread["cwd"] as? String ?? source.cwd
                    self.selectedThreadID = id
                    self.currentTitle = resumedTitle == "Untitled chat" ? source.title : resumedTitle
                    self.messages = Self.parseHistory(thread)
                    self.rememberOwnedThread(id)
                    self.status = "Ready"
                    self.isTransitioning = false
                    self.loadRecentThreads()
                    self.startTurn(text)
                case .failure(let error):
                    self.isTransitioning = false
                    if error.localizedDescription.lowercased().contains("active writer") {
                        self.queueOnActiveWriter(source, text: text)
                    } else {
                        self.status = "Couldn’t continue chat"
                        self.draft = text
                        self.addNotice(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func clearWriteConflict() {
        queuedSyncToken = nil
        queuedSubmissionID = nil
    }

    private func queueOnActiveWriter(_ source: RecentThread, text: String) {
        let token = UUID()
        queuedSyncToken = token
        queuedSubmissionID = nil
        status = "Syncing with Codex…"
        connection.request(
            method: "thread/queue/add",
            params: [
                "threadId": source.id,
                "clientUserMessageId": UUID().uuidString,
                "input": [["type": "text", "text": text]]
            ],
            timeout: 30
        ) { [weak self] result in
            Task { @MainActor in
                guard let self, self.queuedSyncToken == token else { return }
                switch result {
                case .success(let payload):
                    self.queuedSubmissionID = (payload["queuedSubmission"] as? [String: Any])?["id"] as? String
                    self.messages.append(ChatMessage(role: .user, text: Self.compactText(text)))
                    self.currentThreadID = nil
                    self.readOnlySource = source
                    self.currentCwd = source.cwd
                    self.selectedThreadID = source.id
                    self.isBusy = true
                    self.status = "Sent to original task…"
                    self.pollQueuedThread(source, text: text, token: token, attempt: 0)
                case .failure(let error):
                    self.queuedSyncToken = nil
                    self.isBusy = false
                    self.status = "Couldn’t sync"
                    self.draft = text
                    self.addNotice(error.localizedDescription)
                }
            }
        }
    }

    private func pollQueuedThread(_ source: RecentThread, text: String, token: UUID, attempt: Int) {
        guard queuedSyncToken == token else { return }
        connection.request(
            method: "thread/read",
            params: ["threadId": source.id, "includeTurns": true],
            timeout: 30
        ) { [weak self] result in
            Task { @MainActor in
                guard let self, self.queuedSyncToken == token else { return }
                if case .success(let payload) = result,
                   let thread = payload["thread"] as? [String: Any] {
                    let history = Self.parseHistory(thread)
                    let expectedText = Self.compactText(text)
                    if let userIndex = history.lastIndex(where: {
                        $0.role == .user && $0.text == expectedText
                    }), history.dropFirst(userIndex + 1).contains(where: { $0.role == .assistant }) {
                        self.messages = history
                        self.queuedSyncToken = nil
                        self.queuedSubmissionID = nil
                        self.isBusy = false
                        self.status = "Ready"
                        self.loadRecentThreads()
                        self.onResponseCompleted?(source.id)
                        return
                    }
                }

                guard attempt < 120 else {
                    self.queuedSyncToken = nil
                    self.queuedSubmissionID = nil
                    self.isBusy = false
                    self.status = "Queued in Codex"
                    self.addNotice("The message is in the original task’s queue. Codex will run it from that same task—no branch was created.")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.pollQueuedThread(source, text: text, token: token, attempt: attempt + 1)
                }
            }
        }
    }

    func createNewChat(sendAfter text: String? = nil) {
        guard isConnected, !isBusy, !isTransitioning else { return }
        clearWriteConflict()
        isTransitioning = true
        messages = []
        currentThreadID = nil
        selectedThreadID = nil
        readOnlySource = nil
        currentTitle = "New chat"
        status = "Starting chat…"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        connection.request(
            method: "thread/start",
            params: [
                "cwd": home,
                "approvalPolicy": "on-request",
                "sandbox": "workspace-write",
                "config": [
                    "sandbox_workspace_write": ["network_access": true]
                ],
                "personality": "friendly",
                "serviceName": "codex_mini_chat",
                "ephemeral": false
            ],
            timeout: 30
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    guard let thread = payload["thread"] as? [String: Any],
                          let id = thread["id"] as? String else {
                        self.status = "Couldn’t start chat"
                        self.isTransitioning = false
                        self.addNotice(AppServerError.invalidResponse.localizedDescription)
                        return
                    }
                    self.currentThreadID = id
                    self.currentCwd = thread["cwd"] as? String ?? home
                    self.selectedThreadID = id
                    self.currentTitle = "New chat"
                    self.status = "Ready"
                    self.rememberOwnedThread(id)
                    self.isTransitioning = false
                    self.loadRecentThreads()
                    if let text {
                        self.startTurn(text)
                    }
                case .failure(let error):
                    self.status = "Couldn’t start chat"
                    self.isTransitioning = false
                    if let text { self.draft = text }
                    self.addNotice(error.localizedDescription)
                }
            }
        }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isConnected, !isBusy, !isTransitioning else { return }
        draft = ""
        if currentThreadID == nil, let source = readOnlySource {
            continueOriginal(source, sendAfter: text)
        } else if currentThreadID == nil {
            createNewChat(sendAfter: text)
        }
        else { startTurn(text) }
    }

    private func rememberOwnedThread(_ id: String) {
        var ids = ownedThreadIDs
        ids.insert(id)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: "ownedThreadIDs")
        UserDefaults.standard.set(id, forKey: "lastThreadID")
    }

    func stopTurn() {
        if queuedSyncToken != nil {
            queuedSyncToken = nil
            isBusy = false
            guard let source = readOnlySource, let queuedSubmissionID else {
                status = "Queued in Codex"
                addNotice("Mini Chat stopped waiting. The message may already be running in the original task.")
                return
            }
            self.queuedSubmissionID = nil
            status = "Canceling queued message…"
            connection.request(
                method: "thread/queue/delete",
                params: ["threadId": source.id, "queuedSubmissionId": queuedSubmissionID]
            ) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    if case .success(let payload) = result, payload["deleted"] as? Bool == true {
                        self.status = "Queue canceled"
                    } else {
                        self.status = "Already running in Codex"
                        self.addNotice("The queued message had already started in the original task.")
                    }
                }
            }
            return
        }
        guard let threadID = currentThreadID, let turnID = activeTurnID else { return }
        connection.request(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        ) { _ in }
    }

    func shutdown() {
        connection.stop()
    }

    func togglePin() {
        isPinned.toggle()
        onTogglePin?()
    }

    func setPopupVisible(_ visible: Bool) {
        isPopupVisible = visible
        if visible, let selectedThreadID {
            markThreadRead(selectedThreadID)
        }
    }

    func trackPopup(threadID: String, visible: Bool) {
        if visible {
            visiblePopupThreadIDs.insert(threadID)
            markThreadRead(threadID)
        } else {
            visiblePopupThreadIDs.remove(threadID)
        }
    }

    func noteThreadActivity(_ threadID: String) {
        if !visiblePopupThreadIDs.contains(threadID) {
            unreadThreadIDs.insert(threadID)
        }
    }

    func markThreadRead(_ threadID: String) {
        unreadThreadIDs.remove(threadID)
    }

    func hasUnread(_ threadID: String) -> Bool {
        unreadThreadIDs.contains(threadID)
    }

    private func startTurn(_ text: String) {
        guard let threadID = currentThreadID else { return }
        messages.append(ChatMessage(role: .user, text: Self.compactText(text)))
        isBusy = true
        status = "Thinking…"
        connection.request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": text]]
            ]
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.isBusy = false
                    self.status = "Send failed"
                    self.addNotice(error.localizedDescription)
                } else if case .success(let payload) = result,
                          let turn = payload["turn"] as? [String: Any] {
                    self.activeTurnID = turn["id"] as? String
                }
            }
        }
    }

    private enum ApprovalChoice {
        case once
        case session
        case deny
    }

    private func handleServerRequest(
        method: String,
        params: [String: Any],
        respond: @escaping ([String: Any]) -> Void
    ) {
        switch method {
        case "item/commandExecution/requestApproval":
            let choice = presentApproval(
                title: "Allow this command?",
                details: approvalDetails(from: params)
            )
            switch choice {
            case .once: respond(["decision": "accept"])
            case .session: respond(["decision": "acceptForSession"])
            case .deny: respond(["decision": "decline"])
            }

        case "item/fileChange/requestApproval":
            let choice = presentApproval(
                title: "Allow these file changes?",
                details: approvalDetails(from: params)
            )
            switch choice {
            case .once: respond(["decision": "accept"])
            case .session: respond(["decision": "acceptForSession"])
            case .deny: respond(["decision": "decline"])
            }

        case "item/permissions/requestApproval":
            let choice = presentApproval(
                title: "Grant Codex permission?",
                details: approvalDetails(from: params)
            )
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            switch choice {
            case .once: respond(["permissions": permissions, "scope": "turn"])
            case .session: respond(["permissions": permissions, "scope": "session"])
            case .deny: respond(["permissions": [:], "scope": "turn"])
            }

        case "execCommandApproval", "applyPatchApproval":
            let title = method == "execCommandApproval" ? "Allow this command?" : "Allow these file changes?"
            let choice = presentApproval(
                title: title,
                details: approvalDetails(from: params)
            )
            switch choice {
            case .once: respond(["decision": "approved"])
            case .session: respond(["decision": "approved_for_session"])
            case .deny:
                respond(["decision": ["denied": ["rejection": "Denied in Mini Chat."]]])
            }

        default:
            respond(["decision": "decline"])
        }
    }

    private func presentApproval(title: String, details: String) -> ApprovalChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Allow for Session")
        alert.addButton(withTitle: "Deny")
        alert.window.level = .floating
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return .once }
        if response == .alertSecondButtonReturn { return .session }
        return .deny
    }

    private func approvalDetails(from params: [String: Any]) -> String {
        var lines: [String] = []
        for key in ["reason", "command", "cwd", "grantRoot"] {
            guard let value = params[key] else { continue }
            if let text = value as? String, !text.isEmpty {
                lines.append(key == "reason" ? text : "\(key): \(text)")
            } else {
                lines.append("\(key): \(String(describing: value))")
            }
        }
        if let permissions = params["permissions"] {
            lines.append("permissions: \(String(describing: permissions))")
        }
        if lines.isEmpty,
           JSONSerialization.isValidJSONObject(params),
           let data = try? JSONSerialization.data(withJSONObject: params, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            lines.append(text)
        }
        return String(lines.joined(separator: "\n\n").prefix(2_400))
    }

    private func releaseWriterToCodex() {
        guard let threadID = currentThreadID else {
            loadRecentThreads()
            return
        }
        let source = RecentThread(
            id: threadID,
            title: currentTitle,
            preview: messages.last(where: { $0.role != .notice })?.text ?? "",
            cwd: currentCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : currentCwd,
            updatedAt: Int(Date().timeIntervalSince1970)
        )
        currentThreadID = nil
        readOnlySource = source
        activeTurnID = nil
        isConnected = false
        hasConnected = false
        connection.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.connect()
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        if let eventThread = params["threadId"] as? String,
           let currentThreadID, eventThread != currentThreadID { return }

        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any] {
                activeTurnID = turn["id"] as? String
            }
            isBusy = true
            status = "Thinking…"

        case "item/agentMessage/delta":
            guard let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return }
            if let index = messages.firstIndex(where: { $0.itemID == itemID }) {
                if messages[index].text.count < Self.maxDisplayCharacters {
                    messages[index].text = Self.compactText(messages[index].text + delta)
                }
            } else {
                messages.append(ChatMessage(itemID: itemID, role: .assistant, text: Self.compactText(delta), isStreaming: true))
            }

        case "item/completed":
            guard let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage",
                  let itemID = item["id"] as? String,
                  let text = item["text"] as? String else { return }
            if let index = messages.firstIndex(where: { $0.itemID == itemID }) {
                messages[index].text = Self.compactText(text)
                messages[index].isStreaming = false
            } else if !text.isEmpty {
                messages.append(ChatMessage(itemID: itemID, role: .assistant, text: Self.compactText(text)))
            }

        case "turn/completed":
            if let turn = params["turn"] as? [String: Any] {
                appendMissingAgentItems(from: turn)
                let state = turn["status"] as? String ?? "completed"
                if state == "failed", let error = turn["error"] as? [String: Any] {
                    addNotice(error["message"] as? String ?? "The turn failed.")
                }
            }
            activeTurnID = nil
            isBusy = false
            status = "Ready"
            if !isPopupVisible, let selectedThreadID {
                unreadThreadIDs.insert(selectedThreadID)
            }
            if let selectedThreadID {
                onResponseCompleted?(selectedThreadID)
            }
            releaseWriterToCodex()

        case "error":
            if let error = params["error"] as? [String: Any] {
                addNotice(error["message"] as? String ?? "Codex reported an error.")
            }

        default:
            break
        }
    }

    private func appendMissingAgentItems(from turn: [String: Any]) {
        let items = turn["items"] as? [[String: Any]] ?? []
        for item in items where item["type"] as? String == "agentMessage" {
            guard let id = item["id"] as? String,
                  messages.first(where: { $0.itemID == id }) == nil,
                  let text = item["text"] as? String, !text.isEmpty else { continue }
            messages.append(ChatMessage(itemID: id, role: .assistant, text: Self.compactText(text)))
        }
    }

    private func addNotice(_ text: String) {
        messages.append(ChatMessage(role: .notice, text: text))
    }

    private static func parseThreadSummary(_ object: [String: Any]) -> RecentThread? {
        guard let id = object["id"] as? String else { return nil }
        return RecentThread(
            id: id,
            title: threadTitle(object),
            preview: object["preview"] as? String ?? "",
            cwd: object["cwd"] as? String ?? "",
            updatedAt: (object["recencyAt"] as? NSNumber)?.intValue
                ?? (object["updatedAt"] as? NSNumber)?.intValue
                ?? 0
        )
    }

    private static func threadTitle(_ object: [String: Any]) -> String {
        if let name = object["name"] as? String, !name.isEmpty { return name }
        if let preview = object["preview"] as? String, !preview.isEmpty {
            let oneLine = preview.replacingOccurrences(of: "\n", with: " ")
            return String(oneLine.prefix(52))
        }
        return "Untitled chat"
    }

    private static func parseHistory(_ thread: [String: Any]) -> [ChatMessage] {
        let turns = thread["turns"] as? [[String: Any]] ?? []
        var output: [ChatMessage] = []
        for turn in turns {
            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                switch item["type"] as? String {
                case "userMessage":
                    let content = item["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty {
                        output.append(ChatMessage(itemID: item["id"] as? String, role: .user, text: compactText(text)))
                    }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        output.append(ChatMessage(itemID: item["id"] as? String, role: .assistant, text: compactText(text)))
                    }
                default:
                    break
                }
            }
        }
        // A mini overlay should stay quick even when the underlying Codex task has a
        // very large transcript. The full history remains in the task and its branch.
        return Array(output.suffix(30))
    }

    private static func compactText(_ text: String) -> String {
        guard text.count > maxDisplayCharacters else { return text }
        return String(text.prefix(maxDisplayCharacters)) + truncationNotice
    }
}

// MARK: - Interface

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct MarkdownText: View {
    let value: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(value)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 5) {
                if message.role == .assistant {
                    Label("Codex", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                MarkdownText(value: message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(message.role == .notice ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(backgroundColor)
            }
            if message.role != .user { Spacer(minLength: 26) }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.16)
        case .assistant: return Color.clear
        case .notice: return Color.orange.opacity(0.12)
        }
    }
}

struct MiniChatView: View {
    @ObservedObject var store: ChatStore
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .sidebar).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.35)
                conversation
                Divider().opacity(0.35)
                composer
            }
        }
        .frame(minWidth: 340, minHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
        .onAppear {
            store.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { composerFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(store.isConnected ? ((store.isBusy || store.isTransitioning) ? Color.orange : Color.green) : Color.red)
                .frame(width: 8, height: 8)

            Menu {
                Button("New chat", systemImage: "square.and.pencil") { store.createNewChat() }
                Divider()
                ForEach(Array(store.recentThreads.prefix(5))) { thread in
                    Button(thread.title) { store.resume(thread) }
                }
                if store.recentThreads.count > 5 {
                    Divider()
                    Menu("More…", systemImage: "ellipsis") {
                        ForEach(Array(store.recentThreads.dropFirst(5))) { thread in
                            Button(thread.title) { store.resume(thread) }
                        }
                    }
                }
                if store.recentThreads.isEmpty {
                    Text("No active chats")
                }
            } label: {
                HStack(spacing: 5) {
                    Text(store.currentTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: 190, alignment: .leading)
            .layoutPriority(1)
            .disabled(store.isBusy || store.isTransitioning)

            Spacer()

            Text(store.status)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.045)))
                .fixedSize()

            Button {
                store.togglePin()
            } label: {
                Image(systemName: store.isPinned ? "pin.fill" : "pin")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isPinned ? "Disable always on top" : "Enable always on top")
            .accessibilityIdentifier("toggle-always-on-top")
            .help(store.isPinned ? "Always on top is on" : "Always on top is off")
            .contentShape(Rectangle())

            Button { store.onHide?() } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .background(Circle().fill(Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize chat popup")
            .accessibilityIdentifier("minimize-chat-popup")
            .help("Hide (Control–Option–Space)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
        // The panel itself remains draggable, but controls in the custom title
        // area must win hit testing over the window-drag region.
        .background(Color.clear)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary)
                            Text("Type to Codex while you browse")
                                .font(.headline)
                            Text("This window stays above other apps. Your recent Codex chats are available from the title menu.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 34)
                        .padding(.top, 70)
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.messages.last.map { "\($0.id.uuidString):\($0.text.count)" }) { _ in
                guard let id = store.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Codex…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($composerFocused)
                    .onSubmit { store.sendDraft() }
                    .disabled(!store.isConnected || store.isBusy || store.isTransitioning)

                if store.isBusy {
                    Button { store.stopTurn() } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.secondary)
                    .help("Stop")
                } else {
                    Button { store.sendDraft() } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !store.isConnected
                            || store.isTransitioning
                    )
                    .help("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                    }
            }

            Text("Return to send  ·  ⌃⌥Space to show or hide")
                .frame(maxWidth: .infinity, alignment: .center)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(10)
    }
}

struct ChatTabStripView: View {
    @ObservedObject var store: ChatStore
    let onSelect: (RecentThread) -> Void
    let onNewChat: () -> Void
    let onHideBar: () -> Void

    private var visibleThreads: [RecentThread] {
        Array(store.recentThreads.prefix(5))
    }

    private var overflowThreads: [RecentThread] {
        Array(store.recentThreads.dropFirst(5))
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .sidebar).ignoresSafeArea()
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Codex")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.leading, 4)

                Divider().frame(height: 24)

                HStack(spacing: 6) {
                ForEach(visibleThreads) { thread in
                    Button { onSelect(thread) } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(store.hasUnread(thread.id) ? Color.blue : Color.clear)
                                .frame(width: 7, height: 7)
                            Text(thread.title)
                                .font(.system(size: 11.5, weight: store.visiblePopupThreadIDs.contains(thread.id) ? .semibold : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            Capsule(style: .continuous)
                                .fill(store.visiblePopupThreadIDs.contains(thread.id)
                                    ? Color.accentColor.opacity(0.17)
                                    : Color.primary.opacity(0.045))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(
                                            store.visiblePopupThreadIDs.contains(thread.id)
                                                ? Color.accentColor.opacity(0.3)
                                                : Color.primary.opacity(0.055),
                                            lineWidth: 1
                                        )
                                }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 108, maxWidth: 180)
                    .help(thread.title)
                }
                }

                Spacer(minLength: 0)

                if !overflowThreads.isEmpty {
                    Menu {
                        ForEach(overflowThreads) { thread in
                            Button {
                                onSelect(thread)
                            } label: {
                                if store.hasUnread(thread.id) {
                                    Label(thread.title, systemImage: "circle.fill")
                                } else {
                                    Text(thread.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if overflowThreads.contains(where: { store.hasUnread($0.id) }) {
                                Circle().fill(Color.blue).frame(width: 7, height: 7)
                            }
                            Image(systemName: "ellipsis")
                            Text("More")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button(action: onNewChat) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background {
                            Circle()
                                .fill(Color.accentColor.opacity(0.16))
                        }
                }
                .buttonStyle(.plain)
                .help("New chat")

                Button(action: onHideBar) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("Hide tab bar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
        .onAppear { store.connect() }
    }
}

// MARK: - Native always-on-top panel and global shortcut

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ChatTabPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ChatPopupSession {
    let id = UUID()
    let panel: MiniPanel
    let store: ChatStore
    var threadID: String?
    var isPresented = false

    init(panel: MiniPanel, store: ChatStore, threadID: String?) {
        self.panel = panel
        self.store = store
        self.threadID = threadID
    }
}

private func miniChatHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { owner.action() }
    return noErr
}

final class GlobalHotKey {
    fileprivate let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            miniChatHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D434854), id: 1) // MCHT
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let tabStore = ChatStore(startupTarget: .listOnly)
    private var tabPanel: ChatTabPanel!
    private var popupSessions: [UUID: ChatPopupSession] = [:]
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var tabStripMenuItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var openedInitialPopup = false
    private var isTabStripShown = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false

        let tabPanel = ChatTabPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 48),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        tabPanel.title = "Codex Mini Chat Tabs"
        tabPanel.isReleasedWhenClosed = false
        tabPanel.tabbingMode = .disallowed
        tabPanel.hidesOnDeactivate = false
        tabPanel.level = .floating
        tabPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        tabPanel.backgroundColor = .clear
        tabPanel.isOpaque = false
        tabPanel.hasShadow = false
        tabPanel.contentView = NSHostingView(rootView: ChatTabStripView(
            store: tabStore,
            onSelect: { [weak self] thread in self?.openThread(thread) },
            onNewChat: { [weak self] in self?.startNewChat() },
            onHideBar: { [weak self] in self?.toggleTabStrip() }
        ))
        self.tabPanel = tabPanel
        isTabStripShown = !UserDefaults.standard.bool(forKey: "tabStripHidden")

        tabStore.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.positionPanels()
            self.openInitialPopupIfNeeded()
        }

        positionPanels()
        showTabStrip()
        installStatusItem()
        hotKey = GlobalHotKey { [weak self] in self?.toggleAllPopups() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tabStore.loadRecentThreads() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.openInitialPopupIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        for session in popupSessions.values { session.store.shutdown() }
        tabStore.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTabStrip()
        showAllPopups()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedPanel = notification.object as? MiniPanel,
              let session = popupSessions.values.first(where: { $0.panel === closedPanel }) else { return }
        if let threadID = session.threadID {
            tabStore.trackPopup(threadID: threadID, visible: false)
        }
        session.store.shutdown()
        popupSessions.removeValue(forKey: session.id)
        positionPanels()
    }

    private func makePopupPanel(store: ChatStore) -> MiniPanel {
        let panel = MiniPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex Mini Chat"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 340, height: 360)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MiniChatView(store: store))
        return panel
    }

    private func createPopup(startupTarget: ChatStartupTarget, threadID: String?) -> ChatPopupSession {
        let popupStore = ChatStore(startupTarget: startupTarget)
        let popupPanel = makePopupPanel(store: popupStore)
        let session = ChatPopupSession(panel: popupPanel, store: popupStore, threadID: threadID)
        popupSessions[session.id] = session

        popupStore.onHide = { [weak self, weak session] in
            guard let session else { return }
            self?.hidePopup(session.id)
        }
        popupStore.onTogglePin = { [weak session] in
            guard let session else { return }
            session.panel.level = session.store.isPinned ? .floating : .normal
        }
        popupStore.onSelectedThreadChanged = { [weak self, weak session] newThreadID in
            guard let self, let session else { return }
            self.updateThreadID(for: session, to: newThreadID)
        }
        popupStore.onResponseCompleted = { [weak self] threadID in
            self?.tabStore.noteThreadActivity(threadID)
        }
        return session
    }

    private func updateThreadID(for session: ChatPopupSession, to newThreadID: String?) {
        let oldThreadID = session.threadID
        guard oldThreadID != newThreadID else { return }
        if let oldThreadID {
            tabStore.trackPopup(threadID: oldThreadID, visible: false)
        }
        session.threadID = newThreadID
        if session.isPresented, let newThreadID {
            tabStore.trackPopup(threadID: newThreadID, visible: true)
        }
    }

    private func openInitialPopupIfNeeded() {
        guard !openedInitialPopup, !tabStore.recentThreads.isEmpty else { return }
        openedInitialPopup = true
        let remembered = UserDefaults.standard.string(forKey: "lastThreadID")
        if let remembered,
           let thread = tabStore.recentThreads.first(where: { $0.id == remembered }) {
            openThread(thread)
        } else if let thread = tabStore.recentThreads.first {
            openThread(thread)
        }
    }

    private func openThread(_ thread: RecentThread) {
        tabStore.markThreadRead(thread.id)
        if let existing = popupSessions.values.first(where: { $0.threadID == thread.id }) {
            showPopup(existing.id)
            return
        }
        let session = createPopup(startupTarget: .thread(thread), threadID: thread.id)
        showPopup(session.id)
    }

    private func startNewChat() {
        let session = createPopup(startupTarget: .newChat, threadID: nil)
        showPopup(session.id)
    }

    private func showPopup(_ sessionID: UUID) {
        guard let session = popupSessions[sessionID] else { return }
        session.isPresented = true
        showTabStrip()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.store.setPopupVisible(true)
        if let threadID = session.threadID {
            tabStore.trackPopup(threadID: threadID, visible: true)
        }
        positionPanels()
        orderPresentedPopupsFront(keySessionID: sessionID)
    }

    private func hidePopup(_ sessionID: UUID) {
        guard let session = popupSessions[sessionID] else { return }
        session.isPresented = false
        session.panel.orderOut(nil)
        session.store.setPopupVisible(false)
        if let threadID = session.threadID {
            tabStore.trackPopup(threadID: threadID, visible: false)
        }
        showTabStrip()
        positionPanels()
        orderPresentedPopupsFront()
    }

    private func showAllPopups() {
        if popupSessions.isEmpty {
            openInitialPopupIfNeeded()
            return
        }
        showTabStrip()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for session in popupSessions.values {
            session.isPresented = true
            session.store.setPopupVisible(true)
            if let threadID = session.threadID {
                tabStore.trackPopup(threadID: threadID, visible: true)
            }
        }
        positionPanels()
        orderPresentedPopupsFront()
    }

    private func hideAllPopups() {
        for session in popupSessions.values where session.isPresented {
            session.isPresented = false
            session.panel.orderOut(nil)
            session.store.setPopupVisible(false)
            if let threadID = session.threadID {
                tabStore.trackPopup(threadID: threadID, visible: false)
            }
        }
        showTabStrip()
    }

    private func toggleAllPopups() {
        if popupSessions.values.contains(where: { $0.isPresented }) {
            hideAllPopups()
        } else {
            showAllPopups()
        }
    }

    private func positionPanels() {
        guard tabPanel != nil, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let fullScreen = screen.frame
        tabPanel.setFrame(
            NSRect(
                x: fullScreen.minX,
                y: fullScreen.minY,
                width: fullScreen.width,
                height: 48
            ),
            display: true
        )

        let visibleSessions = popupSessions.values
            .filter { $0.isPresented }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !visibleSessions.isEmpty else { return }
        let gap: CGFloat = 10
        let standardWidth: CGFloat = 420
        let maximumColumns = max(1, Int((visible.width - 16 + gap) / (standardWidth + gap)))
        let columnCount = min(visibleSessions.count, maximumColumns)
        let totalWidth = CGFloat(columnCount) * standardWidth + CGFloat(max(0, columnCount - 1)) * gap
        let startX = max(visible.minX + 8, visible.midX - totalWidth / 2)

        for (index, session) in visibleSessions.enumerated() {
            let column = index % maximumColumns
            let row = index / maximumColumns
            let size = session.panel.frame.size
            let x = min(startX + CGFloat(column) * (standardWidth + gap), visible.maxX - size.width - 8)
            let preferredBaseY = isTabStripShown
                ? max(tabPanel.frame.maxY + 8, visible.minY + 8)
                : visible.minY + 8
            let baseY = min(preferredBaseY, visible.maxY - size.height - 8)
            let y = min(baseY + CGFloat(row) * 26, visible.maxY - size.height - 8)
            session.panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func showTabStrip() {
        guard tabPanel != nil else { return }
        if isTabStripShown {
            tabPanel.orderFrontRegardless()
        } else {
            tabPanel.orderOut(nil)
        }
    }

    private func toggleTabStrip() {
        isTabStripShown.toggle()
        UserDefaults.standard.set(!isTabStripShown, forKey: "tabStripHidden")
        tabStripMenuItem?.title = isTabStripShown ? "Hide Tab Bar" : "Show Tab Bar"
        showTabStrip()
        positionPanels()
        orderPresentedPopupsFront()
    }

    private func orderPresentedPopupsFront(keySessionID: UUID? = nil) {
        for session in popupSessions.values where session.isPresented {
            session.panel.orderFrontRegardless()
        }
        if let keySessionID, let keySession = popupSessions[keySessionID] {
            keySession.panel.makeKey()
            keySession.panel.orderFrontRegardless()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "Codex Mini Chat")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show or Hide Chat Popups", action: #selector(toggleFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "New Chat", action: #selector(newChatFromMenu), keyEquivalent: "n"))
        let tabStripItem = NSMenuItem(
            title: isTabStripShown ? "Hide Tab Bar" : "Show Tab Bar",
            action: #selector(toggleTabStripFromMenu),
            keyEquivalent: ""
        )
        menu.addItem(tabStripItem)
        tabStripMenuItem = tabStripItem
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Codex Mini Chat", action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFromMenu() { toggleAllPopups() }
    @objc private func newChatFromMenu() { startNewChat() }
    @objc private func toggleTabStripFromMenu() { toggleTabStrip() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}

@main
struct MiniChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
