import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, notice }

    let id: UUID
    let role: Role
    var text: String
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

struct OmpSessionSummary: Identifiable, Equatable {
    let id: String
    let path: String
    let title: String
    let preview: String
    let cwd: String
    let modifiedAt: Date

    var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

enum ChatStartupTarget {
    case listOnly
    case session(OmpSessionSummary)
    case newSession(cwd: String)
}

enum OmpMiniError: LocalizedError {
    case executableNotFound
    case notRunning
    case invalidResponse
    case timeout(String)
    case server(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The OMP runtime is missing. Reinstall OMP Mini Chat or install the omp command."
        case .notRunning:
            return "The OMP session is not running."
        case .invalidResponse:
            return "OMP returned an invalid response."
        case .timeout(let command):
            return "OMP did not answer \(command) in time."
        case .server(let message), .process(let message):
            return message
        }
    }
}
