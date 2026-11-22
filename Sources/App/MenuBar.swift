import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// Owns the status item and the companion popover. AppKit is used so a drive event can open the panel programmatically,
/// and so the popover can be detached into a larger window.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let model: AppModel
    let panel = PanelState()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient               // clicking outside closes the UI, never the transfer
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let host = NSHostingController(rootView: CompanionPanel(panel: panel).environmentObject(model))
        host.sizingOptions = [.preferredContentSize]   // popover resizes with the page
        popover.contentViewController = host
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.setAccessibilityLabel("Editor Workflow")
            // Drop a .drp or footage on the menu bar icon. The view sits on top and passes clicks through to the button.
            let drop = StatusDropView(frame: b.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in self?.clicked() }
            drop.onHighlight = { [weak b] on in b?.highlight(on) }
            drop.onDrop = { [weak self] urls in self?.dropped(urls) }
            drop.onEnter = { [weak self] in self?.startDropMode() }
            b.addSubview(drop)
        }
        model.$running.combineLatest(model.$live, model.$jobs, model.$queue)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)
        updateIcon()
    }

    /// Subtle, distinct states: idle, copying, verifying, paused/attention, failed, complete.
    private func updateIcon() {
        let phases = model.live.values.map(\.phase)
        let symbol: String, label: String
        if phases.contains("Verifying") { symbol = "checkmark.shield"; label = "Verifying" }
        else if !model.running.isEmpty { symbol = "arrow.down.circle"; label = "Copying" }
        else if model.jobs.contains(where: { $0.status == .interrupted }) { symbol = "exclamationmark.triangle"; label = "Needs attention" }
        else if !model.queue.isEmpty || model.jobs.contains(where: { $0.status == .paused }) { symbol = "pause.circle"; label = "Paused or waiting" }
        else if let last = model.jobs.first, last.status == .failed, Date().timeIntervalSince(last.finished ?? .distantPast) < 3600 { symbol = "xmark.octagon"; label = "Last transfer failed" }
        else if let last = model.jobs.first, last.status == .verified, Date().timeIntervalSince(last.finished ?? .distantPast) < 600 { symbol = "checkmark.circle"; label = "Transfer complete" }
        else { symbol = ""; label = "Idle" }
        // The logo always stays; state shows as short text beside it (copy percent, check when done).
        // Attention and failure stay in the tooltip and notifications, without a "!" in the menu bar.
        item.button?.image = Self.logo
        item.button?.imagePosition = .imageLeft
        let running = model.jobs.filter { model.running.contains($0.id) }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }, done = running.reduce(Int64(0)) { $0 + $1.copiedBytes }
        let text: String
        switch symbol {
        case "checkmark.shield", "arrow.down.circle":
            let pct = total > 0 ? "\(Int(Double(done) / Double(total) * 100))%" : "…"
            // Several transfers at once: the count sits before the percentage.
            text = running.count > 1 ? " \(running.count)× \(pct)" : " \(pct)"
        case "exclamationmark.triangle", "xmark.octagon": text = ""
        case "checkmark.circle": text = " ✓"
        default: text = ""
        }
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        item.button?.toolTip = "Editor Workflow: \(label)"
        item.button?.setAccessibilityLabel("Editor Workflow: \(label)")
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showCommandMenu(); return }
        popover.isShown ? popover.close() : show(tab: nil)
    }

    /// The small command menu (Settings, Help, Quit); the panel itself is the main interface.
    private func showCommandMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Open Editor Workflow", action: #selector(openApp), keyEquivalent: "").target = self
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Open Panel in Window", action: #selector(openWindowed), keyEquivalent: "").target = self
        m.addItem(withTitle: "Scratchpad", action: #selector(openScratchpad), keyEquivalent: "").target = self
        m.addItem(withTitle: "Background Activity", action: #selector(openMonitor), keyEquivalent: "").target = self
        m.addItem(withTitle: "Keyboard Cleaning Mode", action: #selector(cleaningMode), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Editor Workflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc private func openApp() { model.openMainWindow() }
    @objc private func openWindowed() { openInWindow() }
    @objc private func cleaningMode() { NSApp.activate(ignoringOtherApps: true); _ = CleaningModeController.shared.start() }
    @objc private func openScratchpad() { ScratchpadController.shared.open() }
    @objc private func openMonitor() { ProcessMonitorController.shared.open() }
    @objc private func openSettings() { model.selection = .settings; model.openMainWindow() }

    func show(tab: CompanionTab?) {
        if let tab { model.companion.tab = tab }
        // Menu bar icon hidden (crowded bar / notch): a popover would have nothing to attach to, so use a window.
        guard let b = item.button, let bw = b.window, bw.occlusionState.contains(.visible) else { openInWindow(); return }
        // A transient popover closes as soon as its app is inactive, so bring the app forward first.
        // The drive policy has already ruled out doing this while Resolve is in front.
        NSApp.activate(ignoringOtherApps: true)
        panel.inPopover = true
        if !popover.isShown { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
    }

    private var detached: NSWindow?

    /// The app's mark: a film frame with a play triangle, drawn as a monochrome template so it follows the menu bar.
    static let logo: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 3.5, width: 14, height: 11), xRadius: 2.6, yRadius: 2.6)
            frame.lineWidth = 1.5; frame.stroke()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 7.4, y: 6.4)); play.line(to: NSPoint(x: 7.4, y: 11.6)); play.line(to: NSPoint(x: 11.8, y: 9)); play.close()
            play.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Editor Workflow"
        return img
    }()

    /// Dropped straight on the icon: no drop screen needed.
    func dropped(_ urls: [URL]) {
        panel.dropMode = false
        model.handleDropped(urls)
        show(tab: nil)
    }

    // MARK: Drag a .drp or footage toward the menu bar: the panel opens as a drop screen

    private var dragMonitors: [Any] = []
    private var lastDragCount = -1
    private var dragIsCandidate = false
    private var openedForDrag = false

    func watchDrags() {
        dragMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.dragMoved() }
        } as Any)
        dragMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.dragEnded() }
        } as Any)
    }

    /// Only file drags of a .drp, a folder or media — or a bare image (Photos, browser, screenshot)
    /// with no file behind it — and only near the top of the screen (on the way to the icon).
    private func dragMoved() {
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != lastDragCount {
            lastDragCount = pb.changeCount
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let hasImage = (pb.types ?? []).contains { UTType($0.rawValue)?.conforms(to: .image) ?? false }
            dragIsCandidate = hasImage || urls.contains { u in
                var d: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &d)
                if d.boolValue || u.pathExtension.lowercased() == "drp" { return true }
                switch MediaCategory.of(u) {
                case .video, .audio, .raw, .photo: return true
                default: return false
                }
            }
        }
        guard dragIsCandidate, !panel.dropMode else { return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }), p.y > screen.frame.maxY - 90 else { return }
        startDropMode()
    }

    func startDropMode() {
        guard !panel.dropMode else { return }
        openedForDrag = !popover.isShown
        panel.dropMode = true
        show(tab: nil)
    }

    /// Let go somewhere else: put the panel back the way it was.
    private func dragEnded() {
        dragIsCandidate = false
        guard panel.dropMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.panel.dropMode else { return }
            self.panel.dropMode = false
            if self.openedForDrag { self.popover.close() }
        }
    }


    /// The same panel and state in a regular, resizable window (spec: detachable/expanded browser).
    func openInWindow() {
        if popover.isShown { popover.performClose(nil) }
        panel.inPopover = false
        panel.expanded = true
        if detached == nil {
            // A window must not size itself from the content: that fed a layout loop (crash 2026-11-09 10:19).
            // The panel scrolls inside a fixed-size, user-resizable window instead.
            let host = NSHostingController(rootView: ScrollView { CompanionPanel(panel: panel).environmentObject(model) })
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 940, height: 640))
            w.minSize = NSSize(width: 720, height: 540)
            w.title = "Editor Workflow Panel"
            w.styleMask.insert(.resizable)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("CompanionPanelWindow")
            detached = w
        }
        // Always land centered on the screen with the menu bar icon: a restored frame can sit half off-screen.
        if let w = detached {
            if w.frame.width < w.minSize.width || w.frame.height < w.minSize.height { w.setContentSize(NSSize(width: 940, height: 640)) }
            var f = w.frame
            let screen = item.button?.window?.screen ?? NSScreen.main
            if let s = screen {
                f.origin.x = s.frame.midX - f.width / 2
                f.origin.y = s.visibleFrame.midY - f.height / 2
                f.origin.x = max(s.frame.minX, min(f.origin.x, s.frame.maxX - f.width))
                f.origin.y = max(s.frame.minY, min(f.origin.y, s.frame.maxY - f.height))
            } else { f.origin = NSPoint(x: 100, y: 100) }
            w.setFrameOrigin(f.origin)
        }
        NSApp.activate(ignoringOtherApps: true)
        detached?.makeKeyAndOrderFront(nil)
    }

    // Dragging the popover off is disabled: a detached popover sizes from its content and can loop; use "Open Panel in Window".
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    /// Clicking elsewhere closes the panel (the copy keeps running), except while a picker window it opened is up.
    /// The menu bar icon still closes it (that path uses close(), which skips this check).
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !model.keepPanelOpen && !panel.dropMode }
    func popoverDidDetach(_ popover: NSPopover) { panel.expanded = true }
    func popoverDidClose(_ notification: Notification) { model.saveCompanionNow() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var menuBar: MenuBarController?

    /// A start counts as "at login" only with our agent's --login flag, the login-item marker, or right after boot.
    /// Anything else (Finder, Spotlight, Dock, `open`) is the user opening the app.
    private var launchedByUser = true
    func applicationWillFinishLaunching(_ notification: Notification) {
        let marker = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let justBooted = ProcessInfo.processInfo.systemUptime < 120
        launchedByUser = !(marker || justBooted || CommandLine.arguments.contains("--login"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Design review: draw the screens to PNG files and quit, without the menu bar, login item or drive watching.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            MainActor.assumeIsolated { Snapshots.run(dir) }
            return
        }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let bar = MenuBarController(model: model)
            menuBar = bar
            bar.watchDrags()
            model.showPanel = { [weak bar] tab in bar?.show(tab: tab) }
            model.showPanelWindow = { [weak bar] in bar?.openInWindow() }
            NSApp.setActivationPolicy(.accessory)
            // First run: start at login so cards are noticed without opening the app.
            LoginItem.ensure(model.settings.openAtLogin ?? true)
            let card = model.checkCardsAtLaunch()
            model.fillMissingCovers()
            // Opened by hand (Applications, Spotlight, Dock): the full app. At login: quiet, unless a card is in.
            if model.settings.onboarded != true { Welcome.show(model) }
            else if self.launchedByUser { model.openMainWindow() }
            if card { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { bar.show(tab: .transfer) } }
        }
        // Back to menu-bar-only (no Dock icon) when the main window closes.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, w.identifier?.rawValue.contains("main") == true else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.contains("main") == true }) { NSApp.setActivationPolicy(.accessory) }
            }
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "openDestination", title: "Open Destination")
        let create = UNNotificationAction(identifier: "createProject", title: "Create Project")
        let panel = UNNotificationAction(identifier: "openPanel", title: "Open Panel")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "transferDone", actions: [open, create], intentIdentifiers: []),
            UNNotificationCategory(identifier: "drive", actions: [panel], intentIdentifiers: []),
        ])
    }

    /// Opening the app again (Finder, Dock, Spotlight) while it runs shows the full window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.openMainWindow() }
        return true
    }

    // The menu bar keeps working with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Never abort transfers silently: ask, and record honestly what was stopped.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let active = model.running.count, waiting = model.queue.count
            guard active + waiting > 0 else { model.saveCompanionNow(); return .terminateNow }
            let a = NSAlert()
            a.messageText = "Transfers are still in progress"
            a.informativeText = "\(active) copying, \(waiting) waiting. If you quit, they stop and are marked Interrupted; finished files are kept and the rest can resume later. Nothing is deleted."
            a.addButton(withTitle: "Keep Running"); a.addButton(withTitle: "Quit Anyway")
            if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            model.saveCompanionNow()
            Log.info("quit with active transfers", ["active": String(active), "waiting": String(waiting)])
            return .terminateNow
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let destination = response.notification.request.content.userInfo["destination"] as? String
        let action = response.actionIdentifier, category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            let model = AppModel.shared
            switch action {
            case "openDestination": if let d = destination { NSWorkspace.shared.open(URL(fileURLWithPath: d)) }
            case "createProject": model.showPanel(.transfer)
            default:
                if category == "drive", let v = model.lastMountedVolume ?? model.pendingTrust {
                    if model.pendingTrust == nil { model.suggestSource(v) }
                    model.showPanel(.transfer)
                } else { model.showPanel(.transfer) }
            }
        }
    }
}

/// "Open at login": the system login item (SMAppService), with a LaunchAgent fallback when macOS refuses it
/// (unsigned builds can be refused). Only the copy in /Applications registers, so test builds never take it over.
enum LoginItem {
    static let agentURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/app.editorworkflow.mac.plist")
    static var isInstalledCopy: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path) }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func ensure(_ on: Bool) {
        guard isInstalledCopy else { return }
        if on, isEnabled { return }
        setEnabled(on)
    }

    static func setEnabled(_ on: Bool) {
        // Only the installed copy may register at login; a build-folder app would break after rebuild.
        guard isInstalledCopy else { Log.info("login item skipped: not in /Applications", ["path": Bundle.main.bundlePath]); return }
        if on {
            do { try SMAppService.mainApp.register() } catch { Log.error("login item", ["detail": error.localizedDescription]) }
            if SMAppService.mainApp.status != .enabled { writeAgent() }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
        }
    }

    /// Starts the app hidden at login; RunAtLoad only, never kept alive against the user's Quit.
    private static func writeAgent() {
        let plist: [String: Any] = ["Label": "app.editorworkflow.mac", "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--login"], "RunAtLoad": true]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL)
            Log.info("login agent written", ["path": agentURL.path])
        } catch { Log.error("login agent", ["detail": error.localizedDescription]) }
    }
}


/// Transparent layer over the status item button: accepts file drops and passes clicks to the button's action.
final class StatusDropView: NSView {
    var onClick: () -> Void = {}
    var onHighlight: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }
    var onEnter: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        // .image covers photo drags that carry data instead of a file URL (Photos, browser).
        registerForDraggedTypes([.fileURL, .tiff, .png, NSPasteboard.PasteboardType("public.image")])
    }
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onHighlight(true) }
    override func mouseUp(with event: NSEvent) { onHighlight(false); onClick() }
    override func rightMouseDown(with event: NSEvent) { onHighlight(true) }
    override func rightMouseUp(with event: NSEvent) { onHighlight(false); onClick() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onHighlight(true); onEnter(); return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHighlight(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight(false)
        let pb = sender.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            DispatchQueue.main.async { self.onDrop(urls) }
            return true
        }
        // Image data with no file behind it: save it into the shelf folder, then treat it as a drop.
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let url = ShelfIngest.saveImage(tiff, suggested: nil) {
            DispatchQueue.main.async { self.onDrop([url]) }
            return true
        }
        return false
    }
}
