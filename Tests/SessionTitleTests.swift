import Foundation
import XCTest
@testable import OmpMiniChat

final class SessionTitleTests: XCTestCase {
    func testSavedChatUsesFirstPromptThenLatestRenameBeyondInitialChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var entries: [[String: Any]] = [
            ["type": "session", "id": "test", "cwd": "/tmp/project"],
            ["type": "message", "message": ["role": "user", "content": "Plan the garden\nMore details"]]
        ]
        func write() throws {
            let lines = try entries.map { try JSONSerialization.data(withJSONObject: $0) }
            var data = Data()
            for line in lines { data.append(line); data.append(10) }
            try data.write(to: url)
        }
        try write()
        XCTAssertEqual(SessionCatalog.shared.parseSummary(at: url, modified: Date())?.title, "Plan the garden")
        entries.append(["type": "title_change", "title": "Garden plan"])
        entries.append(["type": "message", "message": ["role": "assistant", "content": String(repeating: "x", count: 70000)]])
        entries.append(["type": "title_change", "title": "September planting"])
        try write()
        XCTAssertEqual(SessionCatalog.shared.parseSummary(at: url, modified: Date())?.title, "September planting")
    }
}
