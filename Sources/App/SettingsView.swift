import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Local private var selfTesting = false
    @Local private var loginOn = LoginItem.isEnabled
    @Local private var selfTestResult: String?

    var body: some View {
        Form {
            Section("DaVinci Resolve") {
                EditionLine()
                if let s = model.resolveStatus {
                    LabeledContent("Installed", value: s.installedVersion ?? "not found")
                    LabeledContent("Live product", value: s.product ?? "not reachable")
                    LabeledContent("Automation", value: s.canAutomate ? "Studio: proven steps only" : "Guided manual import")
                    if !s.reachable && s.installed {
                        Label("Studio: set Preferences › System › General › External scripting to Local", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Then press Recheck. Resolve Free 21.1+ does not allow external scripting; the guided workflow is used.")
                    }
                }
                if let s = model.resolveStatus, s.reachable, s.edition == .studio {
                    LabeledContent("Proven capabilities", value: s.capabilities.isEmpty ? "none for this version" : s.capabilities.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "can", with: "")) \($0.value ? "✓" : "✗")" }.joined(separator: "  "))
                    LabeledContent("Source", value: s.capabilitySource)
                    HStack {
                        Button(selfTesting ? "Testing…" : "Run Capability Self-Test") {
                            selfTesting = true
                            model.runCapabilitySelfTest { msg in selfTestResult = msg; selfTesting = false }
                        }.disabled(selfTesting)
                        .help("Creates two throwaway projects in Resolve, tests each step, then deletes them.")
                        if let selfTestResult { Text(selfTestResult).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Link("Capability matrix (what is automated and why)", destination: URL(fileURLWithPath: Bundle.main.path(forResource: "capability-matrix", ofType: "md") ?? "/"))
            }
            Section("Default folders") {
                folderRow("Transfer destination", \.defaultDestination)
                folderRow("Projects folder", \.defaultProjectsFolder)
            }
            Section("Menu bar companion") {
                Toggle("Open at login (runs in the menu bar)", isOn: Binding(get: { loginOn }, set: { model.settings.openAtLogin = $0; LoginItem.setEnabled($0); loginOn = LoginItem.isEnabled }))
                if LoginItem.needsApproval {
                    Text("Allow Editor Workflow in System Settings › General › Login Items.").font(.caption).foregroundStyle(.orange)
                }
                Picker("When a drive connects", selection: Binding(get: { model.settings.autoOpen ?? .open }, set: { model.settings.autoOpen = $0 })) {
                    ForEach(AutoOpenMode.allCases, id: \.self) { Text($0.label) }
                }
                Toggle("Only for drives I trust", isOn: Binding(get: { model.settings.trustedOnly ?? false }, set: { model.settings.trustedOnly = $0 }))
                if let t = model.settings.trustedDrives, !t.isEmpty {
                    ForEach(t, id: \.self) { u in
                        HStack {
                            Text(model.volumes.first { $0.uuid == u }?.name ?? "Drive \(u.prefix(8))")
                            Text(u.prefix(8)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") { model.settings.trustedDrives = t.filter { $0 != u } }
                        }
                    }
                }
                Stepper("Transfers at once: \(model.settings.maxConcurrent ?? 4)", value: Binding(get: { model.settings.maxConcurrent ?? 4 }, set: { model.settings.maxConcurrent = $0; model.pump() }), in: 1...6)
                HStack {
                    LabeledContent("DaVinci Resolve app", value: model.settings.resolveAppPath ?? ResolveAdapter.appPath)
                    Button("Choose…") { model.chooseResolveApp() }
                }
            }
            Section("Project naming") {
                TextField("Name preset", text: Binding(get: { model.settings.namePattern ?? "" }, set: { model.settings.namePattern = $0.isEmpty ? nil : $0 }), prompt: Text("{date} {template}"))
                LabeledContent("Example", value: ProjectStore.applyPattern(model.settings.namePattern ?? "{date} {template}", template: model.templateList.first))
                    .help("Tokens: {template} {category} {date} {year}")
            }
            Section("Transfers") {
                Picker("Default conflict rule", selection: $model.settings.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases.filter { $0 != .replace }, id: \.self) { Text($0.label) }
                }
                LabeledContent("Verification", value: "SHA-256, every file, always")
                Toggle("Notify when a transfer finishes", isOn: $model.settings.notifyOnFinish)
            }
            Section("Storage access") {
                ForEach(model.locations) { l in
                    HStack { Text(l.name); Text(model.resolvedPath(l)).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Remove") { model.removeLocation(l) } }
                }
                Button("Add Folder…") { if let u = AppModel.chooseFolder(prompt: "Authorize") { model.addLocation(u) } }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full disk access")
                        Text("Lets the app read every folder you point it at, including other drives, without a prompt each time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }
            Section("Accessibility") {
                LabeledContent("Shortcuts", value: "⌘N New Project · ⌘T New Transfer · ⌘I Import Template · ⌘↩ Review Transfer")
                Button("Open macOS Accessibility Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!) }
            }
            Section("Diagnostics") {
                HStack { Button("Export Diagnostics…") { model.exportDiagnostics() }; Button("Show Log") { NSWorkspace.shared.open(model.paths.logs) } }
            }
            Section("Template photos") {
                SecureField("Unsplash access key (optional)", text: Binding(get: { model.settings.unsplashKey ?? "" }, set: { model.settings.unsplashKey = $0.isEmpty ? nil : $0 }))
                    .help("With a free key from unsplash.com/developers, photos come from Unsplash. Without it, from Openverse (openly licensed).")
            }
            Section("Your data") {
                LabeledContent("App data", value: model.paths.root.path)
                HStack {
                    Button("Back Up Library…", action: backup)
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.root) }
                    Spacer()
                    Button("Delete App Records…", role: .destructive, action: deleteRecords)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }

    func folderRow(_ title: String, _ key: WritableKeyPath<AppSettings, String>) -> some View {
        HStack {
            LabeledContent(title, value: model.settings[keyPath: key].isEmpty ? "Not set" : model.settings[keyPath: key])
            Button("Choose…") { if let u = AppModel.chooseFolder(prompt: "Use") { model.settings[keyPath: key] = u.path } }
        }
    }

    /// Copies the whole app data folder (database, masters, thumbnails, manifests) to a folder the user picks.
    func backup() {
        guard let dir = AppModel.chooseFolder(prompt: "Back Up Here") else { return }
        // A destination inside the app data folder would copy the backup into itself.
        let root = model.paths.root.standardizedFileURL.path
        let target = dir.standardizedFileURL.path
        guard target != root, !target.hasPrefix(root + "/") else {
            model.errorMessage = "Choose a folder outside \(model.paths.root.path). Backing up inside the app data folder would copy it into itself."
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dst = dir.appendingPathComponent("Editor Workflow Backup \(stamp)")
        do {
            try model.db.exec("PRAGMA wal_checkpoint(FULL)")
            try FileManager.default.copyItem(at: model.paths.root, to: dst)
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        } catch { model.report(error) }
    }

    func deleteRecords() {
        let a = NSAlert()
        a.messageText = "Delete all of the app's own records?"
        a.informativeText = "This removes the template library (stored master copies), project and transfer history, covers, logs and settings from \(model.paths.root.path). Your footage, project folders, original .drp files and Resolve projects are not touched. This cannot be undone. Back up first if unsure."
        a.alertStyle = .critical
        a.addButton(withTitle: "Delete Records"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for t in model.templateList { try? model.templates.remove(t.id) }
        try? model.db.exec("DELETE FROM docs")
        try? FileManager.default.removeItem(at: model.paths.manifests)
        try? FileManager.default.removeItem(at: model.paths.thumbnails)
        try? FileManager.default.removeItem(at: model.paths.covers)
        try? FileManager.default.removeItem(at: model.paths.logs)
        try? model.paths.create()
        model.settings = AppSettings()
        model.reload()
    }
}
