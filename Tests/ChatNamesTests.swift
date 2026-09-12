import Foundation
import XCTest
@testable import OmpMiniChat

final class ChatNamesTests: XCTestCase {
    func testRenamePersistsBySessionIDAndSurvivesHostTitleChanges() {
        let suite = "test.chatnames.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = ChatNames(defaults: defaults)
        names.rename("first", to: "  Garden\n planning  ")
        names.rename("first", to: " \n ")
        let reloaded = ChatNames(defaults: defaults)
        XCTAssertEqual(reloaded.title(for: "first", fallback: "New host title"), "Garden planning")
        XCTAssertEqual(reloaded.title(for: "second", fallback: "Another chat"), "Another chat")
        reloaded.reset("first")
        XCTAssertEqual(ChatNames(defaults: defaults).title(for: "first", fallback: "OMP title"), "OMP title")
    }
}
