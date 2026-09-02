import AppKit
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

private struct MarkdownText: View {
    let value: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: value,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(value)
            }
        }
        .textSelection(.enabled)
    }
}

private final class ResizeGripNSView: NSView {
    private var initialFrame = NSRect.zero
    private var initialMouse = NSPoint.zero

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let deltaX = mouse.x - initialMouse.x
        let deltaY = mouse.y - initialMouse.y
        let width = max(window.minSize.width, initialFrame.width + deltaX)
        let height = max(window.minSize.height, initialFrame.height - deltaY)
        let originY = initialFrame.maxY - height
        window.setFrame(NSRect(x: initialFrame.minX, y: originY, width: width, height: height), display: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: bounds.maxX - 4, y: bounds.minY + 3))
        path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 4))
        path.move(to: NSPoint(x: bounds.maxX - 9, y: bounds.minY + 3))
        path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 9))
        path.move(to: NSPoint(x: bounds.maxX - 14, y: bounds.minY + 3))
        path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 14))
        path.stroke()
    }
}

private struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeGripNSView { ResizeGripNSView() }
    func updateNSView(_ nsView: ResizeGripNSView, context: Context) {}
}

struct MiniChatView: View {
    @ObservedObject var store: ChatStore
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.35)
                conversation
                Divider().opacity(0.35)
                composer
            }
        }
        .frame(minWidth: 340, minHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .frame(width: 20, height: 20)
                .help("Drag to resize")
        }
        .onAppear {
            store.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { composerFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isConnected ? ((store.isBusy || store.isTransitioning) ? Color.orange : Color.green) : Color.red)
                .frame(width: 8, height: 8)

            Menu {
                Button("New session…", systemImage: "square.and.pencil") { store.createSession() }
                Divider()
                ForEach(Array(store.recentSessions.prefix(5))) { session in
                    Button(session.title) { store.openSession(session) }
                }
                if store.recentSessions.count > 5 {
                    Divider()
                    Menu("More…", systemImage: "ellipsis") {
                        ForEach(Array(store.recentSessions.dropFirst(5))) { session in
                            Button(session.title) { store.openSession(session) }
                        }
                    }
                }
                if store.recentSessions.isEmpty { Text("No active sessions") }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.currentTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !store.currentProject.isEmpty {
                        Text(store.currentProject)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: 150, alignment: .leading)
            .layoutPriority(1)
            .disabled(store.isBusy || store.isTransitioning)

            Spacer(minLength: 0)

            Text(store.status)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.045)))
                .fixedSize()

            Menu {
                Button("Sign in…", systemImage: "person.crop.circle") { store.login() }
                Button("Choose model…", systemImage: "cpu") { store.chooseModel() }
                Divider()
                Button("Copy terminal command", systemImage: "terminal") { store.copyTerminalCommand() }
                Button("Copy transcript", systemImage: "doc.on.doc") { store.copyTranscript() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.055)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Session actions")

            Button {
                store.isPinned.toggle()
                store.onTogglePin?()
            } label: {
                Image(systemName: store.isPinned ? "pin.fill" : "pin")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isPinned ? "Disable always on top" : "Enable always on top")
            .help(store.isPinned ? "Always on top is on" : "Always on top is off")

            Button { store.onHide?() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize chat popup")
            .help("Minimize popup")
        }
        .padding(.horizontal, 11)
        .frame(height: 48)
        .contentShape(Rectangle())
        .background(Color.clear)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary)
                            Text(store.isTransitioning ? store.status : "Type to OMP while you browse")
                                .font(.headline)
                            Text("This is a real OMP session in \(store.currentProject.isEmpty ? "your selected project" : store.currentProject). Drag the header to move this popup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 34)
                        .padding(.top, 70)
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.messages.last.map { "\($0.id.uuidString):\($0.text.count)" }) { _ in
                guard let id = store.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message OMP…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($composerFocused)
                    .onSubmit { store.sendDraft() }
                    .disabled(!store.isConnected || store.isBusy || store.isTransitioning)

                if store.isBusy {
                    Button { store.stopTurn() } label: {
                        Image(systemName: "stop.fill").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.secondary)
                    .help("Stop")
                } else {
                    Button { store.sendDraft() } label: {
                        Image(systemName: "arrow.up").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !store.isConnected
                            || store.isTransitioning
                    )
                    .help("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                    }
            }

            Text("Return to send  ·  drag header to move  ·  drag corner to resize")
                .frame(maxWidth: .infinity, alignment: .center)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 5) {
                if message.role == .assistant {
                    Label("OMP", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                MarkdownText(value: message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(message.role == .notice ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.isStreaming { ProgressView().controlSize(.mini) }
                HStack {
                    Spacer()
                    Button { copy() } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy message")
                }
                .frame(height: 18)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(backgroundColor))
            if message.role != .user { Spacer(minLength: 26) }
        }
        .contextMenu { Button("Copy Message", systemImage: "doc.on.doc") { copy() } }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.16)
        case .assistant: return Color.clear
        case .notice: return Color.orange.opacity(0.12)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

struct FooterView: View {
    @ObservedObject var store: ChatStore
    var onHideBar: () -> Void

    private var primary: [OmpSessionSummary] { Array(store.recentSessions.prefix(5)) }
    private var overflow: [OmpSessionSummary] { Array(store.recentSessions.dropFirst(5)) }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("OMP")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.leading, 4)

                Divider().frame(height: 24)

                HStack(spacing: 6) {
                    ForEach(primary) { session in
                        FooterTab(
                            session: session,
                            unread: store.unreadSessionIDs.contains(session.id),
                            working: store.workingSessionIDs.contains(session.id),
                            selected: store.selectedSessionID == session.id
                        ) { store.openSession(session) }
                    }
                }

                Spacer(minLength: 0)

                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow) { session in
                            Button {
                                store.openSession(session)
                            } label: {
                                if store.workingSessionIDs.contains(session.id) {
                                    Label(session.title, systemImage: "hourglass")
                                } else if store.unreadSessionIDs.contains(session.id) {
                                    Label(session.title, systemImage: "circle.fill")
                                } else {
                                    Text(session.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if overflow.contains(where: { store.workingSessionIDs.contains($0.id) }) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.72)
                                    .frame(width: 9, height: 9)
                            } else if overflow.contains(where: { store.unreadSessionIDs.contains($0.id) }) {
                                Circle().fill(Color.blue).frame(width: 7, height: 7)
                            }
                            Image(systemName: "ellipsis")
                            Text("More").font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button { store.createSession() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.accentColor.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help("New session")

                Button(action: onHideBar) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("Hide footer")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
    }
}

private struct FooterTab: View {
    let session: OmpSessionSummary
    let unread: Bool
    let working: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if working {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.72)
                    } else {
                        Circle().fill(unread ? Color.blue : Color.clear)
                    }
                }
                .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(session.projectName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.045))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(selected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.055), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 108, maxWidth: 180)
        .help(working ? "OMP is responding…" : session.preview)
    }
}

struct FloatingFooterControlView: View {
    @ObservedObject var store: ChatStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                VisualEffectBackground(material: .popover)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(store.isFooterVisible ? Color.primary : Color.accentColor)
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(
                        store.isFooterVisible ? Color.primary.opacity(0.16) : Color.accentColor.opacity(0.55),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isFooterVisible ? "Hide OMP footer" : "Show OMP footer")
        .help(store.isFooterVisible ? "Hide OMP footer" : "Show OMP footer")
    }
}
