import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, notice, tool, thinking, status }

    let id: UUID
    let role: Role
    var title: String?
    var text: String
    var isStreaming: Bool
    var isError: Bool
    let detailID: String?

    init(
        id: UUID = UUID(),
        role: Role,
        title: String? = nil,
        text: String,
        isStreaming: Bool = false,
        isError: Bool = false,
        detailID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.text = text
        self.isStreaming = isStreaming
        self.isError = isError
        self.detailID = detailID
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

struct LiveSessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var projectName: String

    var modifiedAt: Date = Date()

    var preview: String { "Live through OMP’s end-to-end encrypted relay" }
}

struct OmpLiveSessionRecord: Codable, Equatable {
    let version: Int
    let sessionId: String
    let sessionFile: String?
    let title: String?
    let cwd: String
    let link: String
    let viewLink: String?
    let pid: Int32
    let updatedAt: String

    var summary: OmpSessionSummary {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = resolvedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "New chat"
        return OmpSessionSummary(
            id: sessionId,
            path: sessionFile ?? "",
            title: displayTitle,
            preview: "Live through OMP’s end-to-end encrypted relay",
            cwd: cwd,
            modifiedAt: Self.dateFormatter.date(from: updatedAt) ?? Date()
        )
    }

    var liveSummary: LiveSessionSummary {
        LiveSessionSummary(id: sessionId, title: summary.title, projectName: summary.projectName, modifiedAt: summary.modifiedAt)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum ChatStartupTarget {
    case listOnly
    case session(OmpSessionSummary)
    case newSession(cwd: String)
    case collab(OmpCollabLink, session: OmpSessionSummary?)
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

/// One footer item per session, ordered by conversation activity rather than live status.
struct FooterSession: Identifiable {
    let saved: OmpSessionSummary?
    let live: LiveSessionSummary?
    var id: String { saved?.id ?? live!.id }
    var title: String { live?.title ?? saved!.title }
    var projectName: String { live?.projectName ?? saved!.projectName }
    var preview: String { live?.preview ?? saved!.preview }
    var modifiedAt: Date { saved?.modifiedAt ?? live!.modifiedAt }

    static func ordered(saved: [OmpSessionSummary], live: [LiveSessionSummary]) -> [FooterSession] {
        var seen = Set<String>()
        var entries = saved.compactMap { session -> FooterSession? in
            guard seen.insert(session.id).inserted else { return nil }
            return FooterSession(saved: session, live: live.first { $0.id == session.id })
        }
        entries += live.compactMap { session -> FooterSession? in
            guard seen.insert(session.id).inserted else { return nil }
            return FooterSession(saved: nil, live: session)
        }
        return entries.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt
        }
    }
}
