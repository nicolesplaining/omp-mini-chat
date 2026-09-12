import AppKit
import SwiftUI

private enum MiniTheme {
    static let chromeBlue = adaptive(
        light: NSColor(calibratedRed: 0.70, green: 0.80, blue: 0.91, alpha: 0.88),
        dark: NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.34, alpha: 0.88)
    )
    static let border = adaptive(
        light: NSColor(calibratedRed: 0.25, green: 0.39, blue: 0.54, alpha: 1),
        dark: NSColor(calibratedRed: 0.29, green: 0.48, blue: 0.68, alpha: 1)
    )
    static let windowSurface = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.50),
        dark: NSColor(calibratedWhite: 0.02, alpha: 0.52)
    )
    static let footerSurface = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.68),
        dark: NSColor(calibratedWhite: 0.02, alpha: 0.68)
    )
    static let terminalSurface = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.44),
        dark: NSColor(calibratedRed: 0.075, green: 0.09, blue: 0.115, alpha: 0.40)
    )
    static let controlSurface = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.52),
        dark: NSColor(calibratedRed: 0.12, green: 0.145, blue: 0.18, alpha: 0.58)
    )
    static let statusSurface = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.34),
        dark: NSColor(calibratedWhite: 0, alpha: 0.20)
    )
    static let inactiveTabSurface = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.24),
        dark: NSColor(calibratedWhite: 1, alpha: 0.045)
    )
    static let textPrimary = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.90),
        dark: NSColor(calibratedWhite: 1, alpha: 0.96)
    )
    static let textSecondary = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.64),
        dark: NSColor(calibratedWhite: 1, alpha: 0.76)
    )
    static let hairline = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.14),
        dark: NSColor(calibratedWhite: 1, alpha: 0.14)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

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
    @AppStorage("ompMini.darkMode") private var isDarkMode = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            MiniTheme.windowSurface.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Rectangle().fill(MiniTheme.border.opacity(0.55)).frame(height: 1)
                if let terminal = store.terminal, store.showsTerminal {
                    TerminalPane(session: terminal)
                } else {
                    conversation
                    Rectangle().fill(MiniTheme.hairline).frame(height: 1)
                    composer
                }
            }
        }
        .frame(minWidth: 340, minHeight: 360)
        .foregroundStyle(MiniTheme.textPrimary)
        .clipShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(MiniTheme.border.opacity(0.72), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .frame(width: 20, height: 20)
                .help("Drag to resize")
        }
        .onAppear {
            store.connect()
            if !store.showsTerminal {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { composerFocused = true }
            }
        }
        .environment(\.colorScheme, isDarkMode ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if store.terminal != nil {
                Button(store.showsTerminal ? "Chat" : "Terminal") {
                    store.showsTerminal.toggle()
                }
                .fixedSize()
                .help("Switch views of the same OMP session")
            } else {
                Button { store.openTerminal() } label: { Image(systemName: "terminal") }
                    .help("Open full OMP terminal")
            }
            Circle()
                .fill(store.isConnected ? ((store.isBusy || store.isTransitioning) ? Color.orange : Color.green) : Color.red)
                .frame(width: 8, height: 8)
                .help(store.status)
                .accessibilityLabel(store.status)

            Menu {
                Button("New session…", systemImage: "square.and.pencil") { store.createSession() }
                Button("Connect with collaboration link…", systemImage: "link") { store.joinCollab() }
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
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .lineLimit(2)
                        .help(store.currentTitle)
                    if !store.currentProject.isEmpty {
                        Text(store.currentProject)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(MiniTheme.textSecondary)
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

            Button { isDarkMode.toggle() } label: {
                Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                    .frame(width: 28, height: 28)
                    .background(Rectangle().fill(MiniTheme.controlSurface))
                    .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDarkMode ? "Use light mode" : "Use dark mode")
            .help(isDarkMode ? "Use light mode" : "Use dark mode")

            Menu {
                if store.isCollabSession {
                    Button("Copy live-session link", systemImage: "link") { store.copyTerminalCommand() }
                } else {
                    Button("Sign in…", systemImage: "person.crop.circle") { store.login() }
                    Button("Choose model…", systemImage: "cpu") { store.chooseModel() }
                    Divider()
                    Button("Copy terminal command", systemImage: "terminal") { store.copyTerminalCommand() }
                }
                Button("Copy transcript", systemImage: "doc.on.doc") { store.copyTranscript() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(Rectangle().fill(MiniTheme.controlSurface))
                    .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
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
                    .background(Rectangle().fill(MiniTheme.controlSurface))
                    .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isPinned ? "Disable always on top" : "Enable always on top")
            .help(store.isPinned ? "Always on top is on" : "Always on top is off")

            Button { store.onHide?() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Rectangle().fill(MiniTheme.controlSurface))
                    .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize chat popup")
            .help("Minimize popup")
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .contentShape(Rectangle())
        .background(MiniTheme.chromeBlue)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if store.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 26))
                                .foregroundStyle(MiniTheme.textSecondary)
                            Text(store.isTransitioning ? store.status : "Type to OMP while you browse")
                                .font(.headline)
                            Text("This is a real OMP session in \(store.currentProject.isEmpty ? "your selected project" : store.currentProject). Drag the header to move this popup.")
                                .font(.caption)
                                .foregroundStyle(MiniTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 34)
                        .padding(.top, 70)
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(8)
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
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(MiniTheme.textPrimary)
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($composerFocused)
                    .onSubmit { store.sendDraft() }
                    .disabled(store.isTransitioning || store.isReadOnlyCollab)

                if store.isBusy {
                    Button { store.stopTurn() } label: {
                        Image(systemName: "stop.fill").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle)
                    .tint(.secondary)
                    .help("Stop")
                } else {
                    Button { store.sendDraft() } label: {
                        Image(systemName: "arrow.up").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle)
                    .disabled(
                        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !store.canSubmit
                    )
                    .help("Send")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                Rectangle()
                    .fill(MiniTheme.terminalSurface)
                    .overlay {
                        Rectangle()
                            .stroke(MiniTheme.hairline, lineWidth: 1)
                    }
            }

            Text("Return to send  ·  drag header to move  ·  drag corner to resize")
                .frame(maxWidth: .infinity, alignment: .center)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(MiniTheme.textSecondary)
        }
        .padding(8)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @AppStorage("ompMini.darkMode") private var isDarkMode = false
    @State private var isDetailExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if message.role == .user { Spacer(minLength: 34) }
            VStack(alignment: .leading, spacing: 4) {
                if message.role == .thinking {
                    DisclosureGroup(isExpanded: $isDetailExpanded) {
                        MarkdownText(value: message.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(MiniTheme.textSecondary)
                            .padding(.top, 4)
                    } label: {
                        messageHeader
                    }
                    .disclosureGroupStyle(.automatic)
                } else {
                    if message.role != .user { messageHeader }
                    messageBody
                }
                HStack {
                    Spacer()
                    Button { copy() } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MiniTheme.textSecondary)
                    .help("Copy message")
                }
                .frame(height: 18)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Rectangle().fill(backgroundColor))
            .overlay(Rectangle().stroke(messageBorderColor, lineWidth: 1))
            if message.role == .assistant || message.role == .notice { Spacer(minLength: 14) }
        }
        .contextMenu { Button("Copy Message", systemImage: "doc.on.doc") { copy() } }
    }

    @ViewBuilder
    private var messageHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: headerIcon)
            Text(message.title ?? headerTitle)
                .lineLimit(1)
            if message.isStreaming {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        .foregroundStyle(message.isError ? Color.red : MiniTheme.textSecondary)
    }

    @ViewBuilder
    private var messageBody: some View {
        if message.role == .tool {
            Text(message.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(message.isError ? Color.red : MiniTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownText(value: message.text)
                .font(.system(size: message.role == .status ? 11.5 : 12.5, design: .monospaced))
                .foregroundStyle(
                    message.role == .notice || message.role == .status
                        ? MiniTheme.textSecondary
                        : MiniTheme.textPrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerTitle: String {
        switch message.role {
        case .assistant: return "OMP"
        case .notice: return "Notice"
        case .tool: return "Tool"
        case .thinking: return "Thinking"
        case .status: return "Status"
        case .user: return "You"
        }
    }

    private var headerIcon: String {
        switch message.role {
        case .assistant: return "sparkles"
        case .notice: return "exclamationmark.circle"
        case .tool: return message.isError ? "terminal.fill" : "terminal"
        case .thinking: return "brain"
        case .status: return "info.circle"
        case .user: return "person"
        }
    }

    private var backgroundColor: Color {
        if isDarkMode {
            switch message.role {
            case .user: return Color(red: 0.075, green: 0.16, blue: 0.27).opacity(0.42)
            case .assistant: return Color(red: 0.065, green: 0.078, blue: 0.10).opacity(0.34)
            case .notice: return Color(red: 0.17, green: 0.12, blue: 0.055).opacity(0.42)
            case .tool: return message.isError ? Color.red.opacity(0.18) : MiniTheme.terminalSurface
            case .thinking: return Color(red: 0.12, green: 0.08, blue: 0.15).opacity(0.38)
            case .status: return message.isError ? Color.red.opacity(0.18) : Color(red: 0.06, green: 0.11, blue: 0.17).opacity(0.38)
            }
        }
        switch message.role {
        case .user: return Color(red: 0.64, green: 0.78, blue: 0.93).opacity(0.46)
        case .assistant: return Color.white.opacity(0.36)
        case .notice: return Color(red: 1.0, green: 0.88, blue: 0.56).opacity(0.42)
        case .tool: return message.isError ? Color.red.opacity(0.18) : MiniTheme.terminalSurface
        case .thinking: return Color(red: 0.82, green: 0.74, blue: 0.92).opacity(0.38)
        case .status: return message.isError ? Color.red.opacity(0.18) : Color(red: 0.68, green: 0.82, blue: 0.96).opacity(0.38)
        }
    }

    private var messageBorderColor: Color {
        switch message.role {
        case .user: return MiniTheme.border.opacity(0.46)
        case .notice: return Color.orange.opacity(0.28)
        case .tool, .assistant, .thinking, .status: return MiniTheme.hairline
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

struct FooterView: View {
    @ObservedObject var store: ChatStore
    @AppStorage("ompMini.darkMode") private var isDarkMode = false
    var onHideBar: () -> Void

    private var primaryLive: [LiveSessionSummary] { Array(store.liveSessions.prefix(5)) }
    private var regularCapacity: Int { max(0, 5 - primaryLive.count) }
    private var nonLiveSessions: [OmpSessionSummary] {
        let liveIDs = Set(store.liveSessions.map(\.id))
        return store.recentSessions.filter { !liveIDs.contains($0.id) }
    }
    private var primary: [OmpSessionSummary] { Array(nonLiveSessions.prefix(regularCapacity)) }
    private var overflowLive: [LiveSessionSummary] { Array(store.liveSessions.dropFirst(5)) }
    private var overflow: [OmpSessionSummary] { Array(nonLiveSessions.dropFirst(regularCapacity)) }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow).ignoresSafeArea()
            MiniTheme.footerSurface.ignoresSafeArea()
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("OMP")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 10)

                Divider().frame(height: 24)

                HStack(spacing: 0) {
                    ForEach(primaryLive) { session in
                        FooterTab(
                            title: session.title,
                            projectName: session.projectName,
                            preview: session.preview,
                            live: true,
                            unread: store.unreadSessionIDs.contains(session.id),
                            working: store.workingSessionIDs.contains(session.id),
                            open: store.openSessionIDs.contains(session.id)
                        ) { store.openLiveSession(session) }
                    }
                    ForEach(primary) { session in
                        FooterTab(
                            title: session.title,
                            projectName: session.projectName,
                            preview: session.preview,
                            live: false,
                            unread: store.unreadSessionIDs.contains(session.id),
                            working: store.workingSessionIDs.contains(session.id),
                            open: store.openSessionIDs.contains(session.id)
                        ) { store.openSession(session) }
                    }
                }

                Spacer(minLength: 0)

                if !overflow.isEmpty || !overflowLive.isEmpty {
                    Menu {
                        ForEach(overflowLive) { session in
                            Button {
                                store.openLiveSession(session)
                            } label: {
                                Label(session.title, systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        if !overflowLive.isEmpty, !overflow.isEmpty { Divider() }
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
                            Text("More").font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Rectangle().fill(MiniTheme.controlSurface))
                        .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button { store.createSession() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Rectangle().fill(MiniTheme.chromeBlue))
                        .overlay(Rectangle().stroke(MiniTheme.border.opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("New session")

                Button { isDarkMode.toggle() } label: {
                    Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Rectangle().fill(MiniTheme.controlSurface))
                        .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(isDarkMode ? "Use light mode" : "Use dark mode")

                Button(action: onHideBar) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Rectangle().fill(MiniTheme.controlSurface))
                        .overlay(Rectangle().stroke(MiniTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Hide footer")
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 5)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(MiniTheme.border.opacity(0.72)).frame(height: 1)
        }
        .foregroundStyle(MiniTheme.textPrimary)
        .environment(\.colorScheme, isDarkMode ? .dark : .light)
    }
}

private struct FooterTab: View {
    let title: String
    let projectName: String
    let preview: String
    let live: Bool
    let unread: Bool
    let working: Bool
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if working {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.72)
                    } else if live && !unread {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Circle().fill(unread ? Color.blue : Color.clear)
                    }
                }
                .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 11, weight: open ? .bold : .regular, design: .monospaced))
                        .lineLimit(1)
                    Text(projectName)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(MiniTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                Rectangle()
                    .fill(open ? MiniTheme.chromeBlue : MiniTheme.inactiveTabSurface)
                    .overlay {
                        Rectangle()
                            .stroke(open ? MiniTheme.border.opacity(0.62) : MiniTheme.hairline, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 108, maxWidth: 180)
        .help(working ? "OMP is responding…" : preview)
    }
}

struct FloatingFooterControlView: View {
    @ObservedObject var store: ChatStore
    @AppStorage("ompMini.darkMode") private var isDarkMode = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                VisualEffectBackground(material: .popover)
                MiniTheme.footerSurface
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(store.isFooterVisible ? Color.primary : Color.accentColor)
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        store.isFooterVisible ? Color.primary.opacity(0.16) : Color.accentColor.opacity(0.55),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isFooterVisible ? "Hide OMP footer" : "Show OMP footer")
        .help(store.isFooterVisible ? "Hide OMP footer" : "Show OMP footer")
        .environment(\.colorScheme, isDarkMode ? .dark : .light)
    }
}
