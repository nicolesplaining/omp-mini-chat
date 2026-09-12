import AppKit
import Darwin
import SwiftUI
import SwiftTerm

/// Owns one real OMP TUI process. Switching views never starts another writer.
@MainActor
final class EmbeddedTerminalSession: ObservableObject, LocalProcessTerminalViewDelegate {
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
    let cwd: String
    let sessionPath: String?
    @Published var hasExited = false
    private var started = false
    var pid: Int32? { started && !hasExited ? view.process.shellPid : nil }

    init(cwd: String, sessionPath: String? = nil) {
        self.cwd = cwd
        self.sessionPath = sessionPath
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.06, green: 0.075, blue: 0.10, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
    }

    func start() {
        guard !started else { return }
        let resources = Bundle.main.resourceURL!
        let sync = resources.appendingPathComponent("omp-sync").path
        let executable = FileManager.default.isExecutableFile(atPath: sync)
            ? sync : resources.appendingPathComponent("omp").path
        var args = [executable]
        let extensionPath = resources.appendingPathComponent("omp-mini-auto-sync.js").path
        if executable == sync { args += ["--extension", extensionPath] }
        if let sessionPath, !sessionPath.isEmpty { args += ["--resume", sessionPath] }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // Login-shell configuration supplies the same PATH/provider environment as Terminal.
        // Arguments remain positional, so project paths are never interpreted as shell code.
        start(executable: "/bin/zsh", arguments: ["-l", "-c", "exec \"$@\"", "omp-mini"] + args,
              environment: environment)
    }

    func start(executable: String, arguments: [String], environment: [String: String]) {
        guard !started else { return }
        started = true
        view.startProcess(executable: executable, args: arguments,
                          environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: cwd)
    }

    func stop() {
        // Keep SwiftTerm's exit monitor armed so the child is reaped and the
        // delegate reports completion. terminate() cancels that monitor early.
        if let pid, pid > 0 { kill(pid, SIGTERM) }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.hasExited = true }
    }
}

struct TerminalPane: View {
    @ObservedObject var session: EmbeddedTerminalSession
    var body: some View {
        VStack(spacing: 0) {
            EmbeddedTerminalView(session: session)
            Text(session.hasExited
                 ? "OMP exited. Use + to start another session."
                 : "Full OMP terminal · /login · /model · /settings · Tab to complete commands")
                .font(.system(size: 10, design: .monospaced))
                .padding(6)
        }
    }
}

struct EmbeddedTerminalView: NSViewRepresentable {
    let session: EmbeddedTerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        DispatchQueue.main.async {
            session.start()
            session.view.window?.makeFirstResponder(session.view)
        }
        return session.view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
