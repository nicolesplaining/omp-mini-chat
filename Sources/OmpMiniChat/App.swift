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

    init(panel: MiniPanel, store: ChatStore, sessionID: String?) {
        self.panel = panel
        self.store = store
        self.sessionID = sessionID
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let footerHeight: CGFloat = 46
    private let defaultPopupSize = NSSize(width: 420, height: 590)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false
        isFooterVisible = !UserDefaults.standard.bool(forKey: "ompMini.footerHidden")

        footerStore = ChatStore(target: .listOnly)
        footerStore.isFooterVisible = isFooterVisible
        footerStore.onOpenSession = { [weak self] session in self?.open(session) }
        footerStore.onNewSession = { [weak self] in self?.chooseProjectAndCreate() }
        createFooter()
        createFooterControl()
        createStatusItem()
        registerHotKey()
        applyFooterVisibility()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.footerStore.refreshSessions()
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
        popups.forEach { $0.store.shutdown() }
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FloatingFooterControlView(store: footerStore) { [weak self] in
            self?.toggleFooter()
        })
        footerControlPanel = panel
        positionFooterControl()
        panel.orderFrontRegardless()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "OMP Mini Chat"
        )
        image?.isTemplate = true
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
        createPopup(target: .newSession(cwd: url.path))
    }

    private func open(_ session: OmpSessionSummary) {
        if let existing = popups.first(where: { $0.sessionID == session.id || $0.store.selectedSessionID == session.id }) {
            footerStore.markRead(session.id)
            show(existing)
            return
        }
        footerStore.markRead(session.id)
        footerStore.selectedSessionID = session.id
        createPopup(target: .session(session))
    }

    private func createPopup(target: ChatStartupTarget) {
        let initialSessionID: String?
        if case .session(let session) = target { initialSessionID = session.id }
        else { initialSessionID = nil }

        let store = ChatStore(target: target)
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

        let popup = PopupSession(panel: panel, store: store, sessionID: initialSessionID)
        popups.append(popup)
        if !restoreFrame(for: popup) { positionNewPopup(popup) }

        store.onHide = { [weak self, weak popup] in
            guard let self, let popup else { return }
            popup.panel.orderOut(nil)
            self.footerStore.refreshSessions()
        }
        store.onTogglePin = { [weak popup] in
            guard let popup else { return }
            popup.panel.level = popup.store.isPinned ? .floating : .normal
        }
        store.onToggleFooter = { [weak self] in self?.toggleFooter() }
        store.onOpenSession = { [weak self] session in self?.open(session) }
        store.onNewSession = { [weak self] in self?.chooseProjectAndCreate() }
        store.onSelectedSessionChanged = { [weak self, weak popup] id in
            guard let self, let popup, let id else { return }
            popup.sessionID = id
            self.footerStore.markRead(id)
            self.footerStore.setWorking(popup.store.isBusy, for: id)
            if popup.panel.isVisible { self.footerStore.selectedSessionID = id }
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
        show(popup)
    }

    private func show(_ popup: PopupSession) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        constrainToScreen(popup.panel)
        popup.panel.orderFrontRegardless()
        popup.panel.makeKey()
        if isFooterVisible { footerPanel?.orderFrontRegardless() }
        if let id = popup.store.selectedSessionID ?? popup.sessionID {
            footerStore.selectedSessionID = id
            footerStore.markRead(id)
        }
    }

    private func hideAllPopups() {
        popups.forEach { $0.panel.orderOut(nil) }
    }

    private func showAllPopups() {
        guard !popups.isEmpty else {
            setFooterVisible(true)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for popup in popups {
            constrainToScreen(popup.panel)
            popup.panel.orderFrontRegardless()
        }
        popups.last?.panel.makeKey()
        if isFooterVisible { footerPanel?.orderFrontRegardless() }
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
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 12,
            y: frame.maxY - panel.frame.height - 12
        ))
    }

    private func positionNewPopup(_ popup: PopupSession) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let index = max(0, popups.count - 1)
        let stagger = CGFloat(index % 7) * 24
        let width = popup.panel.frame.width
        let height = popup.panel.frame.height
        let x = max(visible.minX + 10, visible.maxX - width - 18 - stagger)
        let footerTop = screen.frame.minY + (isFooterVisible ? footerHeight : 0)
        let y = max(visible.minY + 10, footerTop + 10 + stagger)
        popup.panel.setFrameOrigin(NSPoint(x: x, y: min(y, visible.maxY - height - 10)))
    }

    private func constrainToScreen(_ panel: MiniPanel) {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.size.width = min(max(frame.width, panel.minSize.width), min(panel.maxSize.width, visible.width))
        frame.size.height = min(max(frame.height, panel.minSize.height), min(panel.maxSize.height, visible.height))
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    private func frameKey(for popup: PopupSession) -> String {
        let identity = popup.sessionID ?? "new"
        let safe = Data(identity.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return "ompMini.popupFrame.\(safe)"
    }

    private func restoreFrame(for popup: PopupSession) -> Bool {
        guard let value = UserDefaults.standard.string(forKey: frameKey(for: popup)) else { return false }
        let frame = NSRectFromString(value)
        guard frame.width >= popup.panel.minSize.width,
              frame.height >= popup.panel.minSize.height,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return false }
        popup.panel.setFrame(frame, display: false)
        constrainToScreen(popup.panel)
        return true
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
