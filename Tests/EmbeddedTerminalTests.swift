import AppKit
import XCTest
@testable import OmpMiniChat

final class EmbeddedTerminalTests: XCTestCase {
    @MainActor
    func testTerminalKeepsOneProcessAcrossRepeatedStartsAndStopsIt() async throws {
        _ = NSApplication.shared
        let terminal = EmbeddedTerminalSession(cwd: NSTemporaryDirectory())
        terminal.start(executable: "/bin/cat", arguments: [], environment: ["TERM": "xterm-256color"])
        defer { terminal.stop() }
        let pid = try XCTUnwrap(terminal.pid)
        XCTAssertGreaterThan(pid, 0)
        terminal.start(executable: "/bin/cat", arguments: [], environment: [:])
        XCTAssertEqual(terminal.pid, pid, "Remounting a terminal must never create a second writer")
        terminal.view.send(txt: "MINI_TERMINAL_IO_CHECK\n")
        for _ in 0..<100 {
            if String(data: terminal.view.getTerminal().getBufferAsData(), encoding: .utf8)?
                .contains("MINI_TERMINAL_IO_CHECK") == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(String(data: terminal.view.getTerminal().getBufferAsData(), encoding: .utf8)!
            .contains("MINI_TERMINAL_IO_CHECK"))
        terminal.stop()
        for _ in 0..<100 {
            if terminal.hasExited { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(terminal.hasExited)
        XCTAssertNil(terminal.pid)
    }

    @MainActor
    func testLoginRemainsReachableWhenRPCIsDisconnected() {
        let store = ChatStore(target: .newSession(cwd: NSTemporaryDirectory()))
        var openedTerminal = false
        store.onOpenTerminal = { openedTerminal = true }
        store.isConnected = false
        store.isTransitioning = false
        store.draft = "/login"
        XCTAssertTrue(store.canSubmit)
        store.sendDraft()
        XCTAssertTrue(openedTerminal)
        XCTAssertTrue(store.messages.isEmpty, "A login command must not become an agent prompt")
    }
}
