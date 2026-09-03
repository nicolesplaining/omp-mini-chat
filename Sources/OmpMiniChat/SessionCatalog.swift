import Foundation
import Darwin

final class SessionCatalog {
    static let shared = SessionCatalog()
    static let activeWindow: TimeInterval = 2 * 24 * 60 * 60

    private let fileManager = FileManager.default

    var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/sessions", isDirectory: true)
    }

    var liveSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/mini-chat/live", isDirectory: true)
    }

    func listLiveSessions() -> [OmpLiveSessionRecord] {
        let root = liveSessionsRoot
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        var newestBySession: [String: OmpLiveSessionRecord] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(OmpLiveSessionRecord.self, from: data),
                  record.version == 1,
                  record.pid > 0,
                  kill(record.pid, 0) == 0,
                  (try? OmpCollabLink.parse(record.link)) != nil else {
                removeStaleLiveRecord(at: url)
                continue
            }
            if let existing = newestBySession[record.sessionId], existing.summary.modifiedAt >= record.summary.modifiedAt {
                continue
            }
            newestBySession[record.sessionId] = record
        }
        return newestBySession.values.sorted { $0.summary.modifiedAt > $1.summary.modifiedAt }
    }

    func requestLiveSessionRefresh(sessionID: String, roomID: String) {
        guard !sessionID.isEmpty, !roomID.isEmpty else { return }
        let root = liveSessionsRoot
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let safeID = sessionID.replacingOccurrences(
            of: #"[^A-Za-z0-9_-]"#,
            with: "_",
            options: .regularExpression
        )
        let request = root.appendingPathComponent("\(safeID).refresh")
        try? Data(roomID.utf8).write(to: request, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
    }

    func listActiveSessions() -> [OmpSessionSummary] {
        let root = sessionsRoot.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-Self.activeWindow)
        var sessions: [OmpSessionSummary] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff,
                  let summary = parseSummary(at: url, modified: modified) else { continue }
            sessions.append(summary)
        }
        return sessions.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func projectDirectories() -> [String] {
        var seen = Set<String>()
        return listActiveSessions().compactMap { session in
            guard seen.insert(session.cwd).inserted else { return nil }
            return session.cwd
        }
    }

    func latestNonExitEntryID(atPath path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        let chunkSize: UInt64 = 64 * 1_024
        var offset = fileSize
        var continuation = Data()
        while offset > 0 {
            let byteCount = min(chunkSize, offset)
            offset -= byteCount
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(byteCount)),
                  !chunk.isEmpty else { return nil }

            var window = chunk
            window.append(continuation)
            let lines = window.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteIndex = offset == 0 ? 0 : 1
            if firstCompleteIndex < lines.count {
                for line in lines[firstCompleteIndex...].reversed() {
                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          object.keys.contains("parentId"),
                          let id = object["id"] as? String else { continue }
                    if object["type"] as? String == "custom",
                       object["customType"] as? String == "session_exit" { continue }
                    return id
                }
            }
            continuation = lines.first.map { Data($0) } ?? Data()
        }
        return nil
    }

    private func parseSummary(at url: URL, modified: Date) -> OmpSessionSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), !data.isEmpty else { return nil }

        var sessionID: String?
        var cwd: String?
        var title: String?
        var firstUserText: String?

        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "title":
                if let value = object["title"] as? String, !value.isEmpty { title = value }
            case "session":
                sessionID = object["id"] as? String
                cwd = object["cwd"] as? String
                if title == nil, let value = object["title"] as? String, !value.isEmpty { title = value }
            case "message" where firstUserText == nil:
                guard let message = object["message"] as? [String: Any],
                      message["role"] as? String == "user" else { continue }
                let text = Self.textContent(message["content"])
                if !text.isEmpty { firstUserText = text }
            default:
                break
            }
            if sessionID != nil, cwd != nil, title != nil, firstUserText != nil { break }
        }

        guard let sessionID, let cwd else { return nil }
        let fallback = firstUserText?.firstNonemptyLine ?? "Untitled session"
        let displayTitle = (title?.firstNonemptyLine).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return OmpSessionSummary(
            id: sessionID,
            path: url.path,
            title: String(displayTitle.prefix(80)),
            preview: String((firstUserText ?? displayTitle).prefix(240)),
            cwd: cwd,
            modifiedAt: modified
        )
    }

    static func textContent(_ value: Any?) -> String {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String,
                  ["text", "input_text", "output_text"].contains(type) else { return nil }
            return block["text"] as? String
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeStaleLiveRecord(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}

private extension String {
    var firstNonemptyLine: String {
        split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
