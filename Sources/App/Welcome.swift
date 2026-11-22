import SwiftUI
import AppKit
@preconcurrency import UserNotifications

/// First run: ask, in plain words, for everything the app needs. Each step can be skipped and changed later in Settings.
@MainActor
enum Welcome {
    private static var window: NSWindow?
    static func show(_ model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView { close(model) }.environmentObject(model))
            host.sizingOptions = []       // fixed size: windows must not size themselves from content (layout loop)
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 520, height: 600))
            w.styleMask = [.titled, .closable]
            w.title = "Welcome to Editor Workflow"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    static func close(_ model: AppModel) {
        model.settings.onboarded = true
        model.saveSettings()
        window?.close(); window = nil
        model.openMainWindow()
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    let done: () -> Void
    @Local private var login = true
    @Local private var notified: Bool?
    @Local private var drivesChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome").font(.title.weight(.semibold))
                    Text("A few permissions so cards and drives open the panel by themselves.").foregroundStyle(.secondary)
                }
            }
            step("power", "Open at login", "Keeps the menu bar icon running after you restart, so a card is noticed.") {
                Toggle("", isOn: Binding(get: { login }, set: { login = $0; model.settings.openAtLogin = $0; LoginItem.setEnabled($0) })).labelsHidden()
            }
            if LoginItem.needsApproval {
                Button("Allow in System Settings › Login Items") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                    .buttonStyle(.link).padding(.leading, 40)
            }
            step("bell", "Notifications", "Tells you when a copy is done or a drive connects.") {
                if let n = notified { Label(n ? "Allowed" : "Off", systemImage: n ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(n ? Theme.verified : .secondary) }
                else { Button("Allow") { requestNotifications() } }
            }
            step("externaldrive", "Drives and cards", "macOS asks once before the app can read a card or drive.") {
                if drivesChecked { Label("Asked", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.verified) }
                else { Button("Allow") { touchDrives() } }
            }
            step("lock.shield", "Full disk access (recommended)", "One switch lets the app read every folder you choose, on any drive, without asking each time.") {
                Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
            }
            step("bolt", "Resolve automation (Studio)", "In Resolve: Preferences › System › General › External scripting using: Local. Then projects open with bins made for you.") {
                if FileManager.default.fileExists(atPath: ResolveAdapter.appPath) {
                    Button("Open Resolve") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: ResolveAdapter.appPath), configuration: .init()) }
                } else {
                    Link("Get DaVinci Resolve", destination: URL(string: "https://www.blackmagicdesign.com/products/davinciresolve")!)
                }
            }
            Spacer()
            HStack {
                Text("You can change all of this in Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start") { done() }.buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 600)
        .onAppear { login = model.settings.openAtLogin ?? true; if login { LoginItem.setEnabled(true) } }
    }

    func step<Trailing: View>(_ icon: String, _ title: String, _ detail: String, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 26).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in notified = ok }
        }
    }

    /// Reading each external drive once makes macOS show its "access files on a removable volume" question now, not mid-copy.
    func touchDrives() {
        for v in Volumes.mounted() where !v.isInternal { _ = try? FileManager.default.contentsOfDirectory(atPath: v.mountPath) }
        _ = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")
        drivesChecked = true
    }
}
