import Foundation

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    fputs("usage: CollabSmoke <collab-link> [prompt]\n", stderr)
    exit(2)
}

do {
    let link = try OmpCollabLink.parse(CommandLine.arguments[1])
    let connection = OmpCollabConnection(link: link)
    var completed = false
    var promptObserved = CommandLine.arguments.count == 2
    var failure: String?
    connection.onPhaseChanged = { phase, _ in
        if !["Connecting…", "Waiting for host…", "Reconnecting…", "Connection lost · reconnecting…"].contains(phase) {
            failure = phase
        }
    }
    connection.onFrame = { frame in
        if frame["t"] as? String == "snapshot-chunk", frame["final"] as? Bool == true {
            completed = true
            if CommandLine.arguments.count == 3 { connection.sendPrompt(CommandLine.arguments[2]) }
        }
        if frame["t"] as? String == "entry",
           let entry = frame["entry"] as? [String: Any],
           entry["type"] as? String == "custom_message",
           entry["customType"] as? String == "collab-prompt" {
            promptObserved = true
        }
    }
    connection.connect()
    let deadline = Date().addingTimeInterval(15)
    while (!completed || !promptObserved), failure == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    connection.close()
    if completed, promptObserved {
        print(CommandLine.arguments.count == 3 ? "encrypted collab prompt passed" : "encrypted collab handshake passed")
        exit(0)
    }
    fputs("collab handshake failed: \(failure ?? "timeout")\n", stderr)
    exit(1)
} catch {
    fputs("collab handshake failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
