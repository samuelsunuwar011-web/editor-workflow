import SwiftUI
import AppKit
import ApplicationServices

/// Keyboard cleaning mode (modeled on Vorssaint's CleaningMode, GPL-3.0):
/// one CGEventTap swallows every keyboard, scroll and gesture event while it runs;
/// mouse buttons and pointer movement pass through, so the Unlock button always works.
/// Unlock: the button, or Esc pressed 5 times (each within 6 s of the last; any other key resets).
/// Accessibility permission is required — without it the mode never engages (no lock without a way out).

/// Tap-side state and logic. The callback runs on the main run loop but not in actor context,
/// so everything it touches lives here, deliberately not actor-isolated.
final class CleaningTapState: @unchecked Sendable {
    weak var controller: CleaningModeController?
    var tap: CFMachPort?
    var pointerDown = false
    var escCount = 0
    var lastEscape: Date?
    static let escKeycode: Int64 = 53

    /// Returns the event to pass through, or nil to swallow it.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pointerDown = true
            return Unmanaged.passUnretained(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pointerDown = false
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        // Keyboard, flags, scroll, gestures, media keys: swallowed. Only Escape is observed for unlock.
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == Self.escKeycode,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let now = Date()
            if let last = lastEscape, now.timeIntervalSince(last) > 6 { escCount = 0 }
            lastEscape = now
            escCount += 1
            let progress = escCount
            DispatchQueue.main.async { [weak controller] in
                controller?.escapeProgress = progress
                if progress >= 5 { controller?.stop() }
            }
        } else if type == .keyDown || type == .flagsChanged {
            // Any other key or modifier resets the unlock counter.
            escCount = 0
            lastEscape = nil
            DispatchQueue.main.async { [weak controller] in controller?.escapeProgress = 0 }
        }
        return nil   // swallow
    }
}

private let tapState = CleaningTapState()

/// C callback for the tap.
private func cleaningTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<CleaningTapState>.fromOpaque(refcon).takeUnretainedValue()
    return state.handle(type: type, event: event)
}

@MainActor
final class CleaningModeController: NSObject, ObservableObject {
    static let shared = CleaningModeController()
    @Published private(set) var active = false
    @Published var escapeProgress = 0
    private var source: CFRunLoopSource?
    private var panels: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var overlayHost: NSHostingController<CleaningOverlayView>?

    // MARK: Start / stop

    /// Returns false when the mode did not engage (no Accessibility permission).
    func start() -> Bool {
        guard !active else { return true }
        guard AXIsProcessTrusted() else {
            let a = NSAlert()
            a.messageText = "Accessibility permission needed"
            a.informativeText = "Cleaning mode blocks keyboard input with a system event tap. macOS requires Accessibility permission for that — without a tap there is no way to block keys, and the mode never engages without a guaranteed way out."
            a.addButton(withTitle: "Open Accessibility Settings")
            a.addButton(withTitle: "Not Now")
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << 14) |                               // systemDefined: media/brightness/volume keys
            (CGEventMask(1) << NSEvent.EventType.gesture.rawValue)     // trackpad gestures
        tapState.controller = self
        tapState.escCount = 0; tapState.lastEscape = nil; tapState.pointerDown = false
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cleaningTapCallback,
                                        userInfo: Unmanaged.passUnretained(tapState).toOpaque()) else {
            tapState.controller = nil
            let a = NSAlert()
            a.messageText = "Cleaning mode could not start"
            a.informativeText = "The system refused the event tap. Check System Settings → Privacy & Security → Accessibility, then try again."
            a.runModal()
            return false
        }
        tapState.tap = t
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        escapeProgress = 0
        active = true
        showPanels()
        observeScreenChanges()
        return true
    }

    func stop() {
        guard active else { return }
        if tapState.pointerDown {
            // Never tear down while a button is held: wait for a real mouse-up (Vorssaint's release gate).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.active else { return }
                if self.tapStatePointerDown { self.stop() } else { self.stopNow() }
            }
            return
        }
        stopNow()
    }

    private var tapStatePointerDown: Bool { tapState.pointerDown }

    private func stopNow() {
        active = false
        escapeProgress = 0
        tapState.escCount = 0; tapState.lastEscape = nil
        if let t = tapState.tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tapState.tap = nil; tapState.controller = nil
        source = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs); screenObserver = nil }
    }

    func toggle() {
        if active { stop() } else { _ = start() }
    }

    // MARK: Overlay panels (one per screen, above the shield level)

    private func showPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        let host = NSHostingController(rootView: CleaningOverlayView())
        overlayHost = host
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.contentView = host.view
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.ignoresMouseEvents = false
            p.isMovable = false
            p.setFrame(screen.frame, display: true)
            p.orderFrontRegardless()
            panels.append(p)
        }
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.showPanelsForCurrentScreens()
            }
        }
    }

    private func showPanelsForCurrentScreens() {
        let screens = NSScreen.screens
        // Rebuild when the screen count changed; otherwise just re-fit.
        if screens.count != panels.count { showPanels(); return }
        for (i, screen) in screens.enumerated() { panels[i].setFrame(screen.frame, display: true) }
    }
}

// MARK: Overlay UI

/// Panel tab page: start/stop cleaning mode, status, and how it works.
struct CleaningPage: View {
    @ObservedObject private var controller: CleaningModeController = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Keyboard Cleaning Mode", systemImage: "keyboard").font(.headline)
                Spacer()
                status
            }
            Text("Blocks keyboard, media keys, scrolling, gestures and modifier shortcuts system-wide while it runs — no stray keystrokes reach DaVinci while you wipe the keys. The mouse keeps working.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    if controller.active { controller.stop() } else { _ = controller.start() }
                } label: {
                    Label(controller.active ? "Stop & Unlock" : "Start Cleaning Mode",
                          systemImage: controller.active ? "lock.open" : "lock")
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(controller.active ? Color.red.opacity(0.85) : Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                if controller.active {
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            Circle().fill(i < controller.escapeProgress ? Theme.accent : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                        Text("Esc \(controller.escapeProgress)/5").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Unlock: the button above, or press Esc 5 times within 6 s of each other.", systemImage: "escape")
                Label("Needs Accessibility permission — macOS requires it for any event tap. The mode never engages without a guaranteed way out.", systemImage: "hand.raised")
                Label("Other keys reset the Esc counter.", systemImage: "arrow.counterclockwise")
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle().fill(controller.active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(controller.active ? "Active — keys blocked" : "Off").font(.caption.weight(.medium))
        }
    }
}

struct CleaningOverlayView: View {
    @ObservedObject private var controller: CleaningModeController = .shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.96)
            VStack(spacing: 18) {
                Image(systemName: "keyboard.fill").font(.system(size: 46)).foregroundStyle(.white.opacity(0.9))
                Text("Keyboard cleaning").font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text("Keyboard, scrolling and gestures are off.\nThe mouse still works.")
                    .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle().fill(i < controller.escapeProgress ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 9, height: 9)
                    }
                }
                Button { CleaningModeController.shared.stop() } label: {
                    Text("Unlock").padding(.horizontal, 26).padding(.vertical, 9)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black).font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Unlock cleaning mode")
                Text("Or press Esc 5 times · mouse and clicks still work")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
