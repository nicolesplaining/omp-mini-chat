import Foundation

final class OmpRPCConnection {
    typealias JSONObject = [String: Any]
    typealias Reply = Result<JSONObject, Error>

    var onEvent: ((JSONObject) -> Void)?
    var onExtensionUIRequest: ((JSONObject) -> Void)?
    var onExit: ((String) -> Void)?

    private struct PendingRequest {
        let command: String
        let completion: (Reply) -> Void
        let timeout: DispatchWorkItem
    }

    private struct ChunkSequence {
        let id: String
        let count: Int
        let byteLength: Int
        var nextIndex: Int
        var data: Data
    }

    private let queue = DispatchQueue(label: "omp-mini-chat.rpc")
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var pending: [String: PendingRequest] = [:]
    private var nextRequestID = 0
    private var chunkSequence: ChunkSequence?
    private var maximumReassembledBytes = 64 * 1_024 * 1_024
    private var startupCompletion: ((Result<Void, Error>) -> Void)?
    private var stoppedIntentionally = false

    var isRunning: Bool {
        queue.sync { process?.isRunning == true }
    }

    func start(sessionPath: String?, cwd: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.process == nil else {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            guard let executable = Self.findExecutable() else {
                DispatchQueue.main.async { completion(.failure(OmpMiniError.executableNotFound)) }
                return
            }

            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = executable
            var arguments = ["--mode", "rpc"]
            if let extensionURL = Bundle.main.url(forResource: "mini-sync-leaf", withExtension: "js") {
                arguments += ["--extension", extensionURL.path]
            }
            arguments += sessionPath.map { ["--resume", $0] } ?? []
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            environment["PI_RPC_EMIT_TITLE"] = "1"
            process.environment = environment
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.receive(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                self?.queue.async { self?.receiveStderr(text) }
            }
            process.terminationHandler = { [weak self] process in
                self?.queue.async { self?.didTerminate(status: process.terminationStatus) }
            }

            do {
                try process.run()
                self.process = process
                self.stdinPipe = stdinPipe
                self.startupCompletion = completion
                self.stoppedIntentionally = false
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func request(
        _ command: String,
        parameters: JSONObject = [:],
        timeout: TimeInterval = 30,
        requestID: String? = nil,
        completion: @escaping (Reply) -> Void
    ) {
        queue.async {
            guard self.process?.isRunning == true else {
                DispatchQueue.main.async { completion(.failure(OmpMiniError.notRunning)) }
                return
            }
            let id: String
            if let requestID {
                id = requestID
            } else {
                self.nextRequestID += 1
                id = "mini_\(self.nextRequestID)"
            }
            var object = parameters
            object["id"] = id
            object["type"] = command
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self, let request = self.pending.removeValue(forKey: id) else { return }
                DispatchQueue.main.async { request.completion(.failure(OmpMiniError.timeout(command))) }
            }
            self.pending[id] = PendingRequest(command: command, completion: completion, timeout: timeoutItem)
            self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            do {
                try self.write(object)
            } catch {
                timeoutItem.cancel()
                self.pending.removeValue(forKey: id)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func send(_ object: JSONObject) {
        queue.async { try? self.write(object) }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.stoppedIntentionally = true
            self.stdinPipe?.fileHandleForWriting.closeFile()
            let process = self.process
            if process?.isRunning == true { process?.terminate() }
            self.failAllPending(with: OmpMiniError.notRunning)
            if let completion {
                DispatchQueue.global(qos: .userInitiated).async {
                    process?.waitUntilExit()
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    private func write(_ object: JSONObject) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else { throw OmpMiniError.notRunning }
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private func receive(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject else { continue }
            receiveObject(object)
        }
    }

    private func receiveObject(_ object: JSONObject) {
        guard let type = object["type"] as? String else { return }
        if type == "rpc_chunk" {
            receiveChunk(object)
            return
        }
        if chunkSequence != nil {
            failProtocol("OMP interleaved an RPC frame inside a chunk sequence.")
            return
        }
        switch type {
        case "ready":
            if let limit = object["maxReassembledFrameBytes"] as? Int {
                maximumReassembledBytes = min(max(limit, 1_024), 64 * 1_024 * 1_024)
            }
            let versions = object["supportedProtocolVersions"] as? [Int] ?? [1]
            if versions.contains(2) {
                request("negotiate_protocol", parameters: ["protocolVersion": 2]) { [weak self] result in
                    self?.completeStartup(result.map { _ in () })
                }
            } else {
                completeStartup(.success(()))
            }
        case "response":
            guard let id = object["id"] as? String,
                  let request = pending.removeValue(forKey: id) else {
                if object["success"] as? Bool == false {
                    let message = object["error"] as? String ?? "An asynchronous OMP command failed."
                    let command = object["command"] as? String ?? "unknown"
                    DispatchQueue.main.async {
                        self.onEvent?(["type": "async_command_error", "command": command, "message": message])
                    }
                }
                return
            }
            request.timeout.cancel()
            let success = object["success"] as? Bool == true
            DispatchQueue.main.async {
                if success {
                    request.completion(.success(object))
                } else {
                    request.completion(.failure(OmpMiniError.server(object["error"] as? String ?? "OMP command failed.")))
                }
            }
        case "extension_ui_request":
            DispatchQueue.main.async { self.onExtensionUIRequest?(object) }
        default:
            DispatchQueue.main.async { self.onEvent?(object) }
        }
    }

    private func receiveChunk(_ object: JSONObject) {
        guard let id = object["chunkId"] as? String,
              let index = object["index"] as? Int,
              let count = object["count"] as? Int,
              let byteLength = object["byteLength"] as? Int,
              let encoded = object["data"] as? String,
              let bytes = Data(base64Encoded: encoded),
              count > 0, index >= 0, index < count,
              byteLength >= 0, byteLength <= maximumReassembledBytes else {
            failProtocol("OMP sent an invalid chunked RPC frame.")
            return
        }
        if chunkSequence == nil {
            guard index == 0 else { failProtocol("OMP chunk sequence did not begin at zero."); return }
            chunkSequence = ChunkSequence(id: id, count: count, byteLength: byteLength, nextIndex: 0, data: Data())
        }
        guard var sequence = chunkSequence,
              sequence.id == id, sequence.count == count, sequence.byteLength == byteLength,
              sequence.nextIndex == index else {
            failProtocol("OMP sent an interrupted or out-of-order chunk sequence.")
            return
        }
        sequence.data.append(bytes)
        sequence.nextIndex += 1
        guard sequence.data.count <= maximumReassembledBytes else {
            failProtocol("OMP RPC frame exceeded the reassembly limit.")
            return
        }
        if sequence.nextIndex == count {
            chunkSequence = nil
            guard sequence.data.count == byteLength,
                  String(data: sequence.data, encoding: .utf8) != nil,
                  let decoded = try? JSONSerialization.jsonObject(with: sequence.data) as? JSONObject else {
                failProtocol("OMP sent a corrupt chunked RPC frame.")
                return
            }
            receiveObject(decoded)
        } else {
            chunkSequence = sequence
        }
    }

    private func receiveStderr(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        DispatchQueue.main.async { self.onEvent?(["type": "notice", "message": clean]) }
    }

    private func failProtocol(_ message: String) {
        chunkSequence = nil
        DispatchQueue.main.async { self.onEvent?(["type": "notice", "message": message]) }
    }

    private func completeStartup(_ result: Result<Void, Error>) {
        queue.async {
            guard let completion = self.startupCompletion else { return }
            self.startupCompletion = nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func didTerminate(status: Int32) {
        process = nil
        stdinPipe = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        chunkSequence = nil
        let message = status == 0 ? "OMP closed." : "OMP exited with status \(status)."
        if let completion = startupCompletion {
            startupCompletion = nil
            DispatchQueue.main.async { completion(.failure(OmpMiniError.process(message))) }
        }
        failAllPending(with: OmpMiniError.process(message))
        if !stoppedIntentionally { DispatchQueue.main.async { self.onExit?(message) } }
    }

    private func failAllPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        requests.forEach { request in
            request.timeout.cancel()
            DispatchQueue.main.async { request.completion(.failure(error)) }
        }
    }

    private static func findExecutable() -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("omp") { candidates.append(bundled) }
        if let configured = ProcessInfo.processInfo.environment["OMP_EXECUTABLE"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".local/bin/omp"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/omp"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/omp"))
        for directory in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("omp"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
