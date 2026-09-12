import Foundation
import XCTest
@testable import OmpMiniChat

final class SessionHistoryTests: XCTestCase {
    func testCatalogIncludesChatsOlderThan48Hours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("old.jsonl")
        let entry: [String: Any] = ["type": "session", "id": "old", "cwd": "/tmp/project", "title": "Old chat"]
        try JSONSerialization.data(withJSONObject: entry).write(to: file)
        let oldDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let sessions = SessionCatalog.shared.listSessions(in: root)
        XCTAssertEqual(sessions.map(\.id), ["old"])
        XCTAssertEqual(sessions.first?.modifiedAt, oldDate)
    }

    func testFooterCombinesAndOrdersAllHistoryWithoutPrioritizingLiveHeartbeats() {
        let saved = (0..<8).map { index in
            OmpSessionSummary(id: "\(index)", path: "/tmp/\(index).jsonl", title: "Chat \(index)",
                              preview: "", cwd: "/tmp", modifiedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let live = [LiveSessionSummary(id: "0", title: "Renamed live chat", projectName: "tmp", modifiedAt: Date()),
                    LiveSessionSummary(id: "new", title: "New chat", projectName: "tmp", modifiedAt: Date())]
        let entries = FooterSession.ordered(saved: saved, live: live)
        XCTAssertEqual(entries.count, 9)
        XCTAssertEqual(Array(entries.prefix(5)).map(\.id), ["new", "7", "6", "5", "4"])
        XCTAssertEqual(Array(entries.dropFirst(5)).map(\.id), ["3", "2", "1", "0"])
        XCTAssertEqual(entries.last?.title, "Renamed live chat")
        XCTAssertNotNil(entries.last?.live)
    }
}
