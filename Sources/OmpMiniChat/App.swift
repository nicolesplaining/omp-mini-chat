import AppKit
import Carbon
import SwiftUI

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class FooterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FooterControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PopupSession {
    let id = UUID()
    let panel: MiniPanel
    let store: ChatStore
    var sessionID: String?
    let autoSynced: Bool
    let collabRoomID: String?

    init(panel: MiniPanel, store: ChatStore, sessionID: String?, autoSynced: Bool, collabRoomID: String?) {
        self.panel = panel
        self.store = store
        self.sessionID = sessionID
        self.autoSynced = autoSynced
        self.collabRoomID = collabRoomID
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSGestureRecognizerDelegate {
    private let footerHeight: CGFloat = 44
    private let defaultPopupSize = NSSize(width: 370, height: 480)
    private var footerPanel: FooterPanel?
    private var footerControlPanel: FooterControlPanel?
    private var footerStore: ChatStore!
    private var popups: [PopupSession] = []
    private var statusItem: NSStatusItem?
    private var footerMenuItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var isFooterVisible = true
    private var footerControlDragOffset = NSPoint.zero
    private var suppressFooterControlClick = false
    private var discoveredLiveSessions: [String: OmpLiveSessionRecord] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false
        // Discard sizes saved by the release that opened terminals at 720 × 560.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "ompMini.compactChatDefault") {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ompMini.popupFrame.") {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: "ompMini.compactChatDefault")
        }
        isFooterVisible = !UserDefaults.standard.bool(forKey: "ompMini.footerHidden")

        footerStore = ChatStore(target: .listOnly)
        footerStore.isFooterVisible = isFooterVisible
        footerStore.onOpenSession = { [weak self] session in self?.open(session) }
        footerStore.onOpenLiveSession = { [weak self] session in self?.openLive(session) }
        footerStore.onNewSession = { [weak self] in self?.chooseProjectAndCreate() }
        footerStore.onJoinCollab = { [weak self] in self?.promptAndJoinCollab() }
        createFooter()
        createFooterControl()
        createStatusItem()
        registerHotKey()
        applyFooterVisibility()
        refreshAutomaticSync()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.footerStore.refreshSessions()
                self?.refreshAutomaticSync()
                self?.positionFooterControl()
                self?.footerControlPanel?.orderFrontRegardless()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        popups.forEach { $0.store.shutdown(); $0.store.terminal?.stop() }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let popup = popups.last { show(popup) }
        else { setFooterVisible(true) }
        return true
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? MiniPanel else { return }
        saveFrame(for: panel)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? MiniPanel else { return }
        saveFrame(for: panel)
    }

    private func createFooter() {
        let panel = FooterPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "OMP Mini Chat Footer"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: FooterView(store: footerStore) { [weak self] in
            self?.setFooterVisible(false)
        })
        footerPanel = panel
        positionFooter()
    }

    private func createFooterControl() {
        let size = NSSize(width: 42, height: 42)
        let panel = FooterControlPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "OMP Footer Control"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FloatingFooterControlView(store: footerStore) { [weak self] in
            self?.handleFooterControlClick()
        })
        let drag = NSPanGestureRecognizer(target: self, action: #selector(dragFooterControl(_:)))
        drag.delegate = self
        drag.delaysPrimaryMouseButtonEvents = false
        panel.contentView?.addGestureRecognizer(drag)
        footerControlPanel = panel
        positionFooterControl()
        panel.orderFrontRegardless()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let bubble = NSBezierPath()
            bubble.move(to: NSPoint(x: 4, y: 5))
            bubble.line(to: NSPoint(x: 4, y: 2))
            bubble.line(to: NSPoint(x: 7.5, y: 5))
            bubble.line(to: NSPoint(x: 14, y: 5))
            bubble.curve(to: NSPoint(x: 16.5, y: 7.5),
                         controlPoint1: NSPoint(x: 15.5, y: 5), controlPoint2: NSPoint(x: 16.5, y: 6))
            bubble.line(to: NSPoint(x: 16.5, y: 13))
            bubble.curve(to: NSPoint(x: 14, y: 15.5),
                         controlPoint1: NSPoint(x: 16.5, y: 14.5), controlPoint2: NSPoint(x: 15.5, y: 15.5))
            bubble.line(to: NSPoint(x: 4, y: 15.5))
            bubble.curve(to: NSPoint(x: 1.5, y: 13),
                         controlPoint1: NSPoint(x: 2.5, y: 15.5), controlPoint2: NSPoint(x: 1.5, y: 14.5))
            bubble.line(to: NSPoint(x: 1.5, y: 7.5))
            bubble.curve(to: NSPoint(x: 4, y: 5),
                         controlPoint1: NSPoint(x: 1.5, y: 6), controlPoint2: NSPoint(x: 2.5, y: 5))
            bubble.close()
            bubble.lineWidth = 1.4
            bubble.lineJoinStyle = .round
            bubble.stroke()
            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 5, y: 12.5))
            prompt.line(to: NSPoint(x: 7.5, y: 10.5))
            prompt.line(to: NSPoint(x: 5, y: 8.5))
            prompt.move(to: NSPoint(x: 10, y: 8.5))
            prompt.line(to: NSPoint(x: 13, y: 8.5))
            prompt.lineWidth = 1.5
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()
            return true
        }
        image.accessibilityDescription = "OMP Mini Chat"
        image.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "OMP Mini Chat"
        let menu = NSMenu()

        let footer = NSMenuItem(
            title: isFooterVisible ? "Hide Footer" : "Show Footer",
            action: #selector(toggleFooterFromMenu),
            keyEquivalent: ""
        )
        footer.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: nil)
        footer.target = self
        menu.addItem(footer)
        footerMenuItem = footer

        let show = NSMenuItem(title: "Show or Hide Chat Popups", action: #selector(toggleFromMenu), keyEquivalent: "")
        show.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        show.target = self
        menu.addItem(show)

        let new = NSMenuItem(title: "New Session…", action: #selector(newFromMenu), keyEquivalent: "n")
        new.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        new.target = self
        menu.addItem(new)

        let join = NSMenuItem(
            title: "Connect with Collaboration Link…",
            action: #selector(joinFromMenu),
            keyEquivalent: ""
        )
        join.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        join.target = self
        menu.addItem(join)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit OMP Mini Chat", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func registerHotKey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.togglePopups() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        let signature: OSType = 0x4F4D504D
        let id = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    private func chooseProjectAndCreate() {
        let picker = NSOpenPanel()
        picker.title = "Choose a project for this OMP session"
        picker.prompt = "Start Session"
        picker.message = "OMP will run in this folder. OMP Terminal’s Recent list only shows sessions from the folder where the terminal was started."
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        if let recentProject = SessionCatalog.shared.projectDirectories().first {
            picker.directoryURL = URL(fileURLWithPath: recentProject, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        createPopup(target: .newSession(cwd: url.path), terminal: EmbeddedTerminalSession(cwd: url.path))
    }

    private func open(_ session: OmpSessionSummary) {
        if let existing = popups.first(where: { $0.sessionID == session.id || $0.store.selectedSessionID == session.id }) {
            footerStore.markRead(session.id)
            show(existing)
            return
        }
        footerStore.markRead(session.id)
        footerStore.selectedSessionID = session.id
        if let record = discoveredLiveSessions[session.id],
           let link = try? OmpCollabLink.parse(record.link) {
            createPopup(target: .collab(link, session: record.summary))
            return
        }
        createPopup(target: .session(session))
    }

    private func openLive(_ session: LiveSessionSummary) {
        if let popup = popups.first(where: { $0.sessionID == session.id }) {
            footerStore.markRead(session.id)
            show(popup)
            return
        }
        guard let record = discoveredLiveSessions[session.id],
              let link = try? OmpCollabLink.parse(record.link) else { return }
        footerStore.markRead(session.id)
        createPopup(target: .collab(link, session: record.summary))
    }

    private func promptAndJoinCollab() {
        let alert = NSAlert()
        alert.messageText = "Join a live OMP session"
        alert.informativeText = "Run /collab in the OMP terminal, then paste the full-control link here. The room key stays in this app and session traffic is end-to-end encrypted."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        field.placeholderString = "roomId.key or https://my.omp.sh/#…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let link = try OmpCollabLink.parse(field.stringValue)
            if let existing = popups.first(where: { $0.sessionID == link.sessionID }) {
                show(existing)
                return
            }
            createPopup(target: .collab(link, session: nil))
        } catch {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .warning
            errorAlert.messageText = "Couldn’t join live session"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
        }
    }

    @discardableResult
    private func createPopup(target: ChatStartupTarget, showImmediately: Bool = true,
                             terminal: EmbeddedTerminalSession? = nil) -> PopupSession {
        let initialSessionID: String?
        let autoSynced: Bool
        let collabRoomID: String?
        switch target {
        case .session(let session):
            initialSessionID = session.id
            autoSynced = false
            collabRoomID = nil
        case .collab(let link, let session):
            initialSessionID = session?.id ?? link.sessionID
            autoSynced = session != nil
            collabRoomID = link.roomID
        default:
            initialSessionID = nil
            autoSynced = false
            collabRoomID = nil
        }

        let store = ChatStore(target: target)
        store.terminal = terminal
        store.showsTerminal = false
        store.isFooterVisible = isFooterVisible
        let panel = MiniPanel(
            contentRect: NSRect(origin: .zero, size: defaultPopupSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OMP Mini Chat"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 340, height: 360)
        panel.maxSize = NSSize(width: 900, height: 1_100)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MiniChatView(store: store))

        let popup = PopupSession(
            panel: panel,
            store: store,
            sessionID: initialSessionID,
            autoSynced: autoSynced,
            collabRoomID: collabRoomID
        )
        popups.append(popup)
        restoreSize(for: popup)
        if let initialSessionID, store.isCollabSession {
            footerStore.upsertLiveSession(id: initialSessionID, title: store.currentTitle, projectName: store.currentProject)
        }

        store.onHide = { [weak self, weak popup] in
            guard let self, let popup else { return }
            popup.panel.orderOut(nil)
            self.refreshOpenSessionIDs()
            self.footerStore.refreshSessions()
        }
        store.onTogglePin = { [weak popup] in
            guard let popup else { return }
            popup.panel.level = popup.store.isPinned ? .floating : .normal
        }
        store.onToggleFooter = { [weak self] in self?.toggleFooter() }
        store.onOpenTerminal = { [weak self, weak popup] in
            guard let self, let popup else { return }
            self.openTerminal(for: popup)
        }
        store.onOpenSession = { [weak self] session in self?.open(session) }
        store.onNewSession = { [weak self] in self?.chooseProjectAndCreate() }
        store.onJoinCollab = { [weak self] in self?.promptAndJoinCollab() }
        store.onLiveMetadataChanged = { [weak self] id, title, project in
            self?.footerStore.upsertLiveSession(id: id, title: title, projectName: project)
        }
        store.onCollabUnavailable = { [weak self, weak popup] _ in
            guard let self,
                  let popup,
                  popup.autoSynced,
                  let id = popup.sessionID,
                  let roomID = popup.collabRoomID else { return }
            SessionCatalog.shared.requestLiveSessionRefresh(sessionID: id, roomID: roomID)
            self.footerStore.setWorking(false, for: id)
        }
        store.onSelectedSessionChanged = { [weak self, weak popup] id in
            guard let self, let popup, let id else { return }
            popup.sessionID = id
            self.footerStore.setWorking(popup.store.isBusy, for: id)
            if popup.panel.isVisible {
                self.footerStore.selectedSessionID = id
                self.footerStore.markRead(id)
            }
            self.refreshOpenSessionIDs()
            self.saveFrame(for: popup.panel)
        }
        store.onWorkingStateChanged = { [weak self, weak popup] id, working in
            self?.footerStore.setWorking(working, for: id ?? popup?.sessionID)
        }
        store.onResponseCompleted = { [weak self] id in
            guard let self else { return }
            if let id { self.footerStore.markUnread(id) }
            self.footerStore.refreshSessions()
        }
        terminal?.start()
        if showImmediately { show(popup) }
        else { store.connect() }
        return popup
    }

    private func refreshAutomaticSync() {
        DispatchQueue.global(qos: .utility).async {
            let records = SessionCatalog.shared.listLiveSessions()
            DispatchQueue.main.async { [weak self] in self?.applyAutomaticSync(records) }
        }
    }

    private func applyAutomaticSync(_ records: [OmpLiveSessionRecord]) {
        discoveredLiveSessions = Dictionary(uniqueKeysWithValues: records.map { ($0.sessionId, $0) })

        // Match the TUI we own by PID, including after /new or /resume changes its session ID.
        for popup in Array(popups) {
            guard let terminal = popup.store.terminal,
                  let pid = terminal.pid,
                  let record = records.first(where: { $0.pid == pid }),
                  let link = try? OmpCollabLink.parse(record.link),
                  popup.sessionID != record.sessionId || popup.collabRoomID != link.roomID else { continue }
            replace(popup, with: .collab(link, session: record.summary))
        }

        for popup in Array(popups) where !popup.store.isBusy {
            if popup.store.terminal != nil { continue }
            guard let sessionID = popup.sessionID else { continue }
            if let record = discoveredLiveSessions[sessionID],
               let link = try? OmpCollabLink.parse(record.link),
               (!popup.store.isCollabSession || (popup.autoSynced && popup.collabRoomID != link.roomID)) {
                    replace(popup, with: .collab(link, session: record.summary))
            } else if popup.autoSynced, discoveredLiveSessions[sessionID] == nil {
                if popup.panel.isVisible,
                   let summary = footerStore.recentSessions.first(where: { $0.id == sessionID }),
                   !summary.path.isEmpty {
                    replace(popup, with: .session(summary))
                } else {
                    remove(popup)
                }
            }
        }

        for record in records where !popups.contains(where: { $0.sessionID == record.sessionId }) {
            guard let link = try? OmpCollabLink.parse(record.link) else { continue }
            createPopup(target: .collab(link, session: record.summary), showImmediately: false)
        }

        var summaries = records.map { record in
            guard let popup = popups.first(where: { $0.sessionID == record.sessionId }) else {
                return record.liveSummary
            }
            return LiveSessionSummary(id: record.sessionId, title: popup.store.currentTitle,
                                      projectName: popup.store.currentProject)
        }
        let discoveredIDs = Set(summaries.map(\.id))
        summaries.append(contentsOf: popups.compactMap { popup in
            guard popup.store.isCollabSession,
                  !popup.autoSynced,
                  let id = popup.sessionID,
                  !discoveredIDs.contains(id) else { return nil }
            return LiveSessionSummary(id: id, title: popup.store.currentTitle, projectName: popup.store.currentProject)
        })
        footerStore.replaceLiveSessions(summaries)
    }

    private func replace(_ popup: PopupSession, with target: ChatStartupTarget) {
        let wasVisible = popup.panel.isVisible
        let frame = popup.panel.frame
        popup.store.shutdown()
        popup.panel.orderOut(nil)
        popups.removeAll { $0 === popup }
        refreshOpenSessionIDs()

        let replacement = createPopup(target: target, showImmediately: false, terminal: popup.store.terminal)
        replacement.store.showsTerminal = popup.store.showsTerminal
        replacement.panel.setFrame(frame, display: false)
        if wasVisible { show(replacement) }
    }

    private func remove(_ popup: PopupSession) {
        popup.store.shutdown()
        popup.store.terminal?.stop()
        popup.panel.orderOut(nil)
        popups.removeAll { $0 === popup }
        refreshOpenSessionIDs()
    }

    private func openTerminal(for popup: PopupSession) {
        if popup.store.terminal != nil {
            popup.store.showsTerminal = true
            return
        }
        if popup.store.isCollabSession {
            let alert = NSAlert()
            alert.messageText = "This terminal is running outside Mini Chat"
            alert.informativeText = "The chat view can send messages to that host, but cannot take over its terminal screen. Start a new OMP terminal here for full commands and account setup. Its login is shared with your other local OMP sessions."
            alert.addButton(withTitle: "New Terminal")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let cwd = popup.store.terminalCwd
            let newPopup = createPopup(target: .newSession(cwd: cwd), terminal: EmbeddedTerminalSession(cwd: cwd))
            newPopup.store.showsTerminal = true
            return
        }
        guard !popup.store.isBusy else {
            let alert = NSAlert()
            alert.messageText = "Wait for this response or stop it before switching to Terminal."
            alert.runModal()
            return
        }
        popup.store.releaseForTerminal { [weak self, weak popup] in
            guard let self, let popup else { return }
            popup.store.terminal = EmbeddedTerminalSession(cwd: popup.store.terminalCwd,
                                                           sessionPath: popup.store.terminalSessionPath)
            popup.store.showsTerminal = true
            popup.store.isTransitioning = false
            self.show(popup)
        }
    }

    private func show(_ popup: PopupSession) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if popup.panel.isVisible {
            constrainToScreen(popup.panel)
        } else {
            positionNewPopup(popup)
        }
        popup.panel.orderFrontRegardless()
        popup.panel.makeKey()
        if isFooterVisible { footerPanel?.orderFrontRegardless() }
        if let id = popup.store.selectedSessionID ?? popup.sessionID {
            footerStore.selectedSessionID = id
            footerStore.markRead(id)
        }
        refreshOpenSessionIDs()
    }

    private func hideAllPopups() {
        popups.forEach { $0.panel.orderOut(nil) }
        refreshOpenSessionIDs()
    }

    private func showAllPopups() {
        guard !popups.isEmpty else {
            setFooterVisible(true)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for popup in popups {
            if popup.panel.isVisible {
                constrainToScreen(popup.panel)
            } else {
                positionNewPopup(popup)
            }
            popup.panel.orderFrontRegardless()
        }
        popups.last?.panel.makeKey()
        if isFooterVisible { footerPanel?.orderFrontRegardless() }
        refreshOpenSessionIDs()
    }

    private func refreshOpenSessionIDs() {
        footerStore.openSessionIDs = Set(popups.compactMap { popup in
            guard popup.panel.isVisible else { return nil }
            return popup.store.selectedSessionID ?? popup.sessionID
        })
    }

    private func togglePopups() {
        if popups.contains(where: { $0.panel.isVisible }) { hideAllPopups() }
        else { showAllPopups() }
    }

    private func primaryScreen() -> NSScreen? {
        footerPanel?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func positionFooter() {
        guard let screen = primaryScreen(), let panel = footerPanel else { return }
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: footerHeight), display: true)
    }

    private func positionFooterControl() {
        guard let panel = footerControlPanel else { return }
        if let saved = UserDefaults.standard.string(forKey: "ompMini.footerControlOrigin") {
            let origin = NSPointFromString(saved)
            let savedFrame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(savedFrame) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 12,
            y: frame.maxY - panel.frame.height - 12
        ))
    }

    @objc private func dragFooterControl(_ gesture: NSPanGestureRecognizer) {
        guard let panel = footerControlPanel else { return }
        let mouse = NSEvent.mouseLocation
        switch gesture.state {
        case .began:
            suppressFooterControlClick = false
            footerControlDragOffset = NSPoint(
                x: mouse.x - panel.frame.minX,
                y: mouse.y - panel.frame.minY
            )
        case .changed, .ended:
            suppressFooterControlClick = true
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? panel.screen
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let bounds = screen?.visibleFrame.insetBy(dx: 8, dy: 8) else { return }
            let origin = NSPoint(
                x: min(max(mouse.x - footerControlDragOffset.x, bounds.minX), bounds.maxX - panel.frame.width),
                y: min(max(mouse.y - footerControlDragOffset.y, bounds.minY), bounds.maxY - panel.frame.height)
            )
            panel.setFrameOrigin(origin)
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "ompMini.footerControlOrigin")
            if gesture.state == .ended {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.suppressFooterControlClick = false
                }
            }
        default: break
        }
    }

    private func handleFooterControlClick() {
        guard !suppressFooterControlClick else { return }
        toggleFooter()
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }

    private func positionNewPopup(_ popup: PopupSession) {
        guard let screen = primaryScreen() else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 0
        let gap: CGFloat = 0
        let footerTop = screen.frame.minY + (isFooterVisible ? footerHeight : 0)
        let left = visible.minX + margin
        let right = visible.maxX - margin
        let bottom = isFooterVisible ? footerTop - 1 : visible.minY + margin
        let top = visible.maxY - margin

        var size = popup.panel.frame.size
        size.width = min(max(size.width, popup.panel.minSize.width), right - left)
        size.height = min(max(size.height, popup.panel.minSize.height), top - bottom)

        let occupied = popups.compactMap { other -> NSRect? in
            guard other !== popup,
                  other.panel.isVisible,
                  other.panel.frame.intersects(screen.frame) else { return nil }
            return other.panel.frame.insetBy(dx: -gap / 2, dy: -gap / 2)
        }

        // Fill each row from right to left. Existing windows are never moved, so
        // users can still drag and resize them after their initial placement.
        var y = bottom
        while y + size.height <= top + 0.5 {
            var x = right - size.width
            while x >= left - 0.5 {
                let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
                let collisions = occupied.filter { $0.intersects(candidate) }
                if collisions.isEmpty {
                    popup.panel.setFrame(candidate, display: false)
                    return
                }
                guard let nextRight = collisions.map(\.minX).min() else { break }
                x = nextRight - gap / 2 - size.width
            }
            y += size.height + gap
        }

        // Extremely crowded screens still get a usable, on-screen popup.
        popup.panel.setFrame(
            NSRect(x: right - size.width, y: bottom, width: size.width, height: size.height),
            display: false
        )
    }

    private func constrainToScreen(_ panel: MiniPanel) {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let lowerEdge = isFooterVisible && screen === primaryScreen()
            ? screen.frame.minY + footerHeight - 1
            : visible.minY
        var frame = panel.frame
        frame.size.width = min(max(frame.width, panel.minSize.width), min(panel.maxSize.width, visible.width))
        frame.size.height = min(
            max(frame.height, panel.minSize.height),
            min(panel.maxSize.height, visible.maxY - lowerEdge)
        )
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, lowerEdge), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    private func frameKey(for popup: PopupSession) -> String {
        let identity = popup.sessionID ?? "new"
        let safe = Data(identity.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return "ompMini.popupFrame.\(safe)"
    }

    private func restoreSize(for popup: PopupSession) {
        guard let value = UserDefaults.standard.string(forKey: frameKey(for: popup)) else { return }
        let frame = NSRectFromString(value)
        guard frame.width >= popup.panel.minSize.width,
              frame.height >= popup.panel.minSize.height else { return }
        popup.panel.setContentSize(frame.size)
    }

    private func saveFrame(for panel: MiniPanel) {
        guard let popup = popups.first(where: { $0.panel === panel }) else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey(for: popup))
    }

    private func toggleFooter() {
        setFooterVisible(!isFooterVisible)
    }

    private func setFooterVisible(_ visible: Bool) {
        isFooterVisible = visible
        UserDefaults.standard.set(!visible, forKey: "ompMini.footerHidden")
        footerStore.isFooterVisible = visible
        popups.forEach { $0.store.isFooterVisible = visible }
        footerMenuItem?.title = visible ? "Hide Footer" : "Show Footer"
        applyFooterVisibility()
    }

    private func applyFooterVisibility() {
        positionFooter()
        if isFooterVisible {
            footerPanel?.orderFrontRegardless()
            footerStore.refreshSessions()
        } else {
            footerPanel?.orderOut(nil)
        }
        positionFooterControl()
        footerControlPanel?.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        positionFooter()
        positionFooterControl()
        footerControlPanel?.orderFrontRegardless()
        popups.forEach { constrainToScreen($0.panel) }
    }

    @objc private func toggleFromMenu() { togglePopups() }
    @objc private func newFromMenu() { chooseProjectAndCreate() }
    @objc private func joinFromMenu() { promptAndJoinCollab() }
    @objc private func toggleFooterFromMenu() { toggleFooter() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}

@main
struct OmpMiniChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
