import CryptoKit
import Foundation

struct OmpCollabLink: Equatable {
    let original: String
    let webSocketURL: URL
    let roomID: String
    let roomKey: Data
    let writeToken: Data?

    var sessionID: String { "collab:\(roomID)" }
    var isReadOnly: Bool { writeToken == nil }

    static func parse(_ input: String) throws -> OmpCollabLink {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%23", with: "#", options: .caseInsensitive)
        if text.hasPrefix("omp join ") { text = String(text.dropFirst("omp join ".count)).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("/join ") { text = String(text.dropFirst("/join ".count)).trimmingCharacters(in: .whitespaces) }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }

        if let components = URLComponents(string: text),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
           let fragment = components.fragment,
           !fragment.isEmpty,
           let nested = try? parse(fragment) {
            return nested
        }

        let barePattern = #"^([A-Za-z0-9_-]{10,64})[.#]([A-Za-z0-9_-]+)$"#
        let bareMatch = text.firstMatch(pattern: barePattern)
        if bareMatch.count == 2 {
            text = "wss://my.omp.sh/r/\(bareMatch[0]).\(bareMatch[1])"
        } else if !text.contains("://") {
            text = "wss://\(text)"
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            throw OmpMiniError.server("Invalid OMP collaboration link.")
        }
        switch scheme {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws":
            guard ["localhost", "127.0.0.1", "::1"].contains(host) else {
                throw OmpMiniError.server("Collaboration links must use the encrypted wss:// relay.")
            }
            components.scheme = "ws"
        default:
            throw OmpMiniError.server("Unsupported collaboration relay scheme.")
        }

        let pathPattern = #"^/r/([A-Za-z0-9_-]{10,64})(?:\.([A-Za-z0-9_-]+))?$"#
        let pathMatch = components.path.firstMatch(pattern: pathPattern)
        guard !pathMatch.isEmpty else {
            throw OmpMiniError.server("The collaboration link is missing its room path.")
        }
        let roomID = pathMatch[0]
        let encodedSecret = pathMatch.count > 1 ? pathMatch[1] : (components.fragment ?? "")
        guard let secret = Data(base64URLEncoded: encodedSecret), [32, 48].contains(secret.count) else {
            throw OmpMiniError.server("The collaboration link has an invalid room key.")
        }

        components.fragment = nil
        components.query = nil
        components.path = "/r/\(roomID)"
        guard let socketURL = components.url else { throw OmpMiniError.server("Invalid collaboration relay URL.") }
        let relayHost = "\(host)\(components.port.map { ":\($0)" } ?? "")"
        let canonicalLink: String
        if host == "my.omp.sh" {
            canonicalLink = "\(roomID).\(encodedSecret)"
        } else if components.scheme == "ws" {
            canonicalLink = "ws://\(relayHost)/r/\(roomID).\(encodedSecret)"
        } else {
            canonicalLink = "\(relayHost)/r/\(roomID).\(encodedSecret)"
        }
        return OmpCollabLink(
            original: canonicalLink,
            webSocketURL: socketURL,
            roomID: roomID,
            roomKey: secret.prefix(32),
            writeToken: secret.count == 48 ? Data(secret.suffix(16)) : nil
        )
    }
}

final class OmpCollabConnection: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    typealias JSONObject = [String: Any]

    var onPhaseChanged: ((String, Bool) -> Void)?
    var onFrame: ((JSONObject) -> Void)?

    private let link: OmpCollabLink
    private let queue = DispatchQueue(label: "omp-mini-chat.collab")
    private let delegateQueue: OperationQueue
    private var urlSession: URLSession!
    private var socketTask: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var welcomeWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var stopped = false
    private var welcomed = false

    init(link: OmpCollabLink) {
        self.link = link
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "omp-mini-chat.collab.delegate"
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
    }

    func connect() {
        queue.async {
            guard self.socketTask == nil else { return }
            self.stopped = false
            self.reconnectAttempt = 0
            self.openSocket()
        }
    }

    func close() {
        queue.async {
            self.stopped = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.welcomeWorkItem?.cancel()
            self.welcomeWorkItem = nil
            self.socketTask?.cancel(with: .normalClosure, reason: nil)
            self.socketTask = nil
            self.urlSession.invalidateAndCancel()
        }
    }

    func sendPrompt(_ text: String) { send(["t": "prompt", "text": text]) }
    func sendAbort() { send(["t": "abort"]) }

    func sendUIResponse(requestID: Int, value: String?) {
        var frame: JSONObject = ["t": "ui-response", "reqId": requestID]
        if let value { frame["value"] = value }
        send(frame)
    }

    private func openSocket() {
        guard !stopped, socketTask == nil else { return }
        var components = URLComponents(url: link.webSocketURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "role", value: "guest")]
        guard let url = components?.url else {
            publishPhase("Invalid relay URL", false)
            return
        }
        welcomed = false
        let task = urlSession.webSocketTask(with: url)
        socketTask = task
        publishPhase(reconnectAttempt == 0 ? "Connecting…" : "Reconnecting…", false)
        task.resume()
        receiveNext(from: task)
        armWelcomeTimeout()
    }

    private func receiveNext(from task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async {
                guard self.socketTask === task, !self.stopped else { return }
                switch result {
                case .failure(let error): self.handleDisconnect(error.localizedDescription, task: task)
                case .success(let message):
                    self.handle(message)
                    if self.socketTask === task { self.receiveNext(from: task) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            if let data = text.data(using: .utf8),
               let control = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
               control["t"] as? String == "room-closed" {
                finish("Room closed")
            }
        case .data(let envelope):
            guard envelope.count > 4 else { return }
            do {
                let box = try AES.GCM.SealedBox(combined: envelope.dropFirst(4))
                let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: link.roomKey))
                guard let frame = try JSONSerialization.jsonObject(with: plaintext) as? JSONObject,
                      let type = frame["t"] as? String else { return }
                if type == "welcome" {
                    welcomed = true
                    if frame["entryCount"] as? Int == 0 {
                        welcomeWorkItem?.cancel()
                        welcomeWorkItem = nil
                    } else {
                        armWelcomeTimeout(snapshotInProgress: true)
                    }
                } else if type == "snapshot-chunk" {
                    welcomed = true
                    if frame["final"] as? Bool == true {
                        welcomeWorkItem?.cancel()
                        welcomeWorkItem = nil
                    } else {
                        armWelcomeTimeout(snapshotInProgress: true)
                    }
                }
                if type == "error", !welcomed {
                    finish(frame["message"] as? String ?? "The OMP host rejected the connection.")
                    return
                }
                if type == "bye" {
                    publishFrame(frame)
                    finish(frame["reason"] as? String ?? "Session ended")
                    return
                }
                publishFrame(frame)
            } catch {
                finish("Bad collaboration key or corrupted encrypted frame")
            }
        @unknown default: break
        }
    }

    private func send(_ object: JSONObject) {
        queue.async {
            guard !self.stopped, let task = self.socketTask else { return }
            do {
                let plaintext = try JSONSerialization.data(withJSONObject: object)
                let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: self.link.roomKey))
                guard let combined = sealed.combined else { throw OmpMiniError.invalidResponse }
                var envelope = Data(repeating: 0, count: 4)
                envelope.append(combined)
                task.send(.data(envelope)) { [weak self, weak task] error in
                    guard let self, let task, let error else { return }
                    self.queue.async { self.handleDisconnect(error.localizedDescription, task: task) }
                }
            } catch {
                self.publishPhase(error.localizedDescription, false)
            }
        }
    }

    private func sendHello() {
        var hello: JSONObject = ["t": "hello", "proto": 3, "name": NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()]
        if let token = link.writeToken { hello["writeToken"] = token.base64URLEncodedString() }
        send(hello)
    }

    private func armWelcomeTimeout(snapshotInProgress: Bool = false) {
        welcomeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finish(snapshotInProgress ? "Timed out loading the live session" : "Timed out waiting for the OMP host")
        }
        welcomeWorkItem = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func handleDisconnect(_ reason: String, task: URLSessionWebSocketTask) {
        guard socketTask === task, !stopped else { return }
        socketTask = nil
        welcomeWorkItem?.cancel()
        welcomeWorkItem = nil
        publishPhase("Connection lost · reconnecting…", false)
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30) * Double.random(in: 0.75...1.25)
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconnectWorkItem = nil
            self.openSocket()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func finish(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        reconnectWorkItem?.cancel()
        welcomeWorkItem?.cancel()
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        publishPhase(reason, false)
    }

    private func publishPhase(_ phase: String, _ live: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onPhaseChanged?(phase, live) }
    }

    private func publishFrame(_ frame: JSONObject) {
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard self.socketTask === webSocketTask, !self.stopped else { return }
            self.reconnectAttempt = 0
            self.publishPhase("Waiting for host…", false)
            self.sendHello()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            let code = closeCode.rawValue
            let fatal: [Int: String] = [4001: "Room closed", 4004: "No such live room", 4009: "Host conflict", 4029: "Room is full"]
            if let message = fatal[code] { self.finish(message) }
            else { self.handleDisconnect(String(data: reason ?? Data(), encoding: .utf8) ?? "Connection closed", task: webSocketTask) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask, let error else { return }
        queue.async { self.handleDisconnect(error.localizedDescription, task: webSocketTask) }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    func firstMatch(pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: self) else { return nil }
            return String(self[swiftRange])
        }
    }
}
