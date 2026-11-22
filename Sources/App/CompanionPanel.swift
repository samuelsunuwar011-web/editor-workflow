import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Visual tokens for the companion: native surfaces, one tally-light amber for "active", status colors only for status.
enum Theme {
    static let accent = Color(red: 0.91, green: 0.64, blue: 0.23)        // tally amber #E8A23B
    static let verified = Color(red: 0.25, green: 0.70, blue: 0.50)      // #3FB37F
    static let attention = Color.orange
    static let failed = Color.red
    static let favorite = Color(red: 0.90, green: 0.33, blue: 0.44)  // heart rose #E5546F
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

/// Icon button with a tooltip and a spoken label (icon-only controls must never be unlabeled).
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color? = nil
    var size: CGFloat = 15
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint ?? .primary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Menu bar companion (spec v2.0): three icon pages over the same services as the main window.
struct CompanionPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var panel: PanelState

    var body: some View {
        VStack(spacing: 0) {
            header
            StatusStrip(panel: panel)
            Group {
                if panel.dropMode { DropScreen(panel: panel) }
                else {
                    switch model.companion.tab {
                    case .transfer: TransferPage(panel: panel)
                    case .favorites: FavoritesPage()
                    case .create: CreateTemplatePage()
                    case .shelf: ShelfPage()
                    case .notes: ScratchpadPage()
                    case .activity: ProcessMonitorView()
                    case .cleaning: CleaningPage()
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        // Height follows the content: no empty band under short pages. One width for every tab, so switching tabs doesn't jump;
        // copying needs room for From and To side by side.
        .frame(width: panel.expanded ? 960 : 800)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
        .tint(Theme.accent)
    }

    var header: some View {
        HStack(spacing: 2) {
            tab(.transfer, "square.and.arrow.down.on.square", "square.and.arrow.down.on.square.fill", "Copy")
            tab(.favorites, "film.stack", "film.stack.fill", "New Project")
            tab(.create, "doc.badge.plus", "doc.fill.badge.plus", "Add Template")
            tab(.shelf, "photo.on.rectangle", "photo.on.rectangle.angled", "Shelf")
            tab(.notes, "note.text", "note.text", "Notes")
            tab(.activity, "gauge.with.needle", "gauge.with.needle.fill", "Activity")
            tab(.cleaning, "keyboard", "keyboard.fill", "Clean")
            Spacer()
            let jobs = model.activeJobs.count + model.queue.count
            if jobs > 0 || panel.showQueue {
                Button { model.companion.tab = .transfer; panel.showQueue.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.rectangle")
                        if jobs > 0 { Text("\(jobs)").font(Theme.number(11)) }
                    }
                    .padding(.horizontal, 7).frame(height: 24)
                    .background(panel.showQueue ? Theme.accent.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(panel.showQueue ? "Hide queue" : "Transfer queue")
                .accessibilityLabel(panel.showQueue ? "Hide queue" : "Transfer queue, \(jobs) jobs")
            }
            IconButton(symbol: panel.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: panel.expanded ? "Smaller panel" : "Bigger panel", size: 13) {
                // A popover is stuck to the menu bar icon and would be clipped half off: open a full window, centered.
                if panel.inPopover { model.showPanelWindow() } else { panel.expanded.toggle() }
            }
            Menu {
                Button("Open Editor Workflow") { model.openMainWindow() }
                Button("Open Panel in Window") { model.showPanelWindow() }
                Button("Scratchpad") { ScratchpadController.shared.open() }
                Button("Background Activity") { ProcessMonitorController.shared.open() }
                Button("Keyboard Cleaning Mode") { NSApp.activate(ignoringOtherApps: true); _ = CleaningModeController.shared.start() }
                Button("Settings…") { model.selection = .settings; model.openMainWindow() }
                Button("Help") { NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.path(forResource: "capability-matrix", ofType: "md") ?? "/")) }
                Divider()
                Button("Quit Editor Workflow") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More").accessibilityLabel("More: open app, settings, quit")
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }

    func tab(_ t: CompanionTab, _ icon: String, _ onIcon: String, _ label: String) -> some View {
        let on = model.companion.tab == t
        return Button {
            // Coming from a project setup, Copy carries that footage, so the two pages work as one flow.
            if t == .transfer, model.companion.draft.sources.isEmpty, let src = model.companion.handoff?.mediaSource {
                var d = TransferDraft()
                d.sources = [src]
                d.stage = .destination
                d.policy = model.settings.conflictPolicy
                d.destinationParent = model.recentPairs.first?.destination
                    ?? (model.settings.defaultDestination.isEmpty ? nil : model.settings.defaultDestination)
                    ?? (NSHomeDirectory() + "/Movies")
                let name = model.companion.handoff?.projectName ?? ""
                d.outputName = name.isEmpty ? URL(fileURLWithPath: src).lastPathComponent : name
                model.companion.draft = d
            }
            model.companion.tab = t; panel.showQueue = false
        } label: {
            Label(label, systemImage: on ? onIcon : icon)
                .font(.callout.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).frame(height: 30)
                // Quiet selected state: a soft grey pill, no bright fill.
                .background(on ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(on ? Color.primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

/// Panel-only state that is not worth persisting.
@MainActor final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var showQueue = false
    /// A .drp or footage is being dragged toward the menu bar: show the drop screen.
    @Published var dropMode = false
    /// Shown as a popover: it cannot widen past the screen edge, so "bigger" opens a centered window instead.
    @Published var inPopover = false
}

/// Only shows when something needs a decision: a new drive to trust, or Resolve missing.
struct StatusStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var panel: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let v = model.pendingTrust {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark").foregroundStyle(Theme.accent)
                    Text("Open the panel whenever **\(v.name)** connects?").font(.callout).lineLimit(2)
                    Spacer()
                    Button("Trust") { model.trust(v, true) }.buttonStyle(.borderedProminent).controlSize(.small)
                    IconButton(symbol: "xmark", label: "Not now", size: 11) { model.trust(v, false) }
                }
            }
            if let rs = model.resolveStatus, !rs.installed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.attention)
                    Text("DaVinci Resolve not found").font(.callout)
                    Spacer()
                    Button("Locate…") { model.chooseResolveApp() }.controlSize(.small)
                    Link(destination: URL(string: "https://www.blackmagicdesign.com/products/davinciresolve")!) { Image(systemName: "arrow.down.circle") }
                        .help("Get DaVinci Resolve").accessibilityLabel("Get DaVinci Resolve")
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, (model.pendingTrust != nil || model.resolveStatus?.installed == false) ? 8 : 0)
    }
}

// MARK: - Transfer page: one route, card → drive

struct TransferPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var panel: PanelState
    /// Main window layout: From and To side by side, taller lists.
    var wide = false
    var onQueued: ((TransferJob) -> Void)? = nil
    @Local private var plans: [TransferPlan] = []
    @Local private var planning = false
    @Local private var mergeConfirmed = true
    @Local private var replaceConfirmed = false
    @Local private var showAllWarnings = false
    @Local private var autoName = ""

    var draft: TransferDraft { model.companion.draft }
    var draftJobs: [TransferJob] { draft.jobIDs.compactMap { id in model.jobs.first { $0.id == id } } }
    var draftActive: Bool { draftJobs.contains { model.running.contains($0.id) || model.queue.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if panel.showQueue && !wide { ScrollView { QueueRows() }.frame(maxHeight: 420) }
            // The route stays on top and fully usable: a copy in progress is a card underneath it,
            // so another folder can be queued without leaving the page.
            route
            if !draft.jobIDs.isEmpty { progressOrResult }
        }
    }

    // MARK: Route: From and To on one page

    var route: some View {
        let lists: CGFloat = wide ? 300 : (panel.expanded ? 260 : 190)
        return VStack(alignment: .leading, spacing: 12) {
            // The route reads left to right: what to copy, then where it goes.
            HStack(alignment: .center, spacing: 8) {
                InlineBrowser(browser: model.sourceBrowser, label: "Copy from", symbol: "sdcard", listHeight: lists, status: fromStatus)
                Image(systemName: "arrow.right.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent).accessibilityHidden(true)
                InlineBrowser(browser: model.destBrowser, label: "Copy to", symbol: "externaldrive", forDestination: true, listHeight: lists, status: toStatus)
            }
            if !draft.sources.isEmpty {
                // One row of choices, then one button that says exactly what will happen.
                HStack(spacing: 10) {
                    Text("Save as").foregroundStyle(.secondary)
                    TextField("Folder name", text: $model.companion.draft.outputName).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name of the copied folder")
                        .help("The copy goes into a new folder with this name: \(model.draftDestination?.path ?? "")")
                    Picker("What to copy", selection: whatBinding) {
                        Text("Everything").tag(0)
                        Text("Videos only").tag(1)
                        Text("Pick types…").tag(2)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().help("What to copy")
                    Menu {
                        Picker("If a file already exists", selection: $model.companion.draft.policy) { ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.label) } }
                        Divider()
                        Picker("Compare with destination", selection: Binding(get: { model.companion.draft.scope ?? .all },
                                                                              set: { model.companion.draft.scope = $0 == .all ? nil : $0 })) {
                            ForEach(CopyScope.allCases, id: \.self) { Text($0.label) }
                        }
                        .help("Copy everything, continue where a copy stopped (skip files already copied), or sync only the files missing at the destination.")
                        if draft.mode == .selectiveCopy {
                            Picker("Checking", selection: $model.companion.draft.verification) { ForEach(VerificationPolicy.allCases, id: \.self) { Text($0.label) } }
                        }
                    } label: { Text("Options") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                if whatBinding.wrappedValue == 2 { typeChips }
                issues
                copyButton
            }
        }
        .onAppear(perform: alignBrowsers)
        // The browsers are their own objects: listen to them directly, or a click never reaches the copy setup.
        .onReceive(model.sourceBrowser.$current.combineLatest(model.sourceBrowser.$selection).dropFirst()) { _ in DispatchQueue.main.async { syncSource() } }
        .onReceive(model.destBrowser.$current.combineLatest(model.destBrowser.$selection).dropFirst()) { _ in DispatchQueue.main.async { syncDestination() } }
        .task(id: planKey) {
            guard !draft.sources.isEmpty, draft.destinationParent != nil, !draft.outputName.isEmpty else { plans = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            planning = true
            let d = draft, dest = model.draftDestination
            plans = await Task.detached { AppModel.plan(d, destination: dest) }.value
            planning = false
        }
    }

    static let systemPlaces: Set<String> = ["/", "/Volumes", NSHomeDirectory(), NSHomeDirectory() + "/Desktop"]

    /// Open both browsers where the draft points; with nothing chosen, start on the newest external drive.
    func alignBrowsers() {
        // A card that was ejected leaves a dead source: clear it instead of falling back to whatever folder is open.
        let internalGuess = model.sourceBrowser.selection.isEmpty && draft.sources.count == 1
            && Volumes.identity(of: URL(fileURLWithPath: draft.sources[0]))?.isInternal != false
        let onImage = draft.sources.contains { Volumes.identity(of: URL(fileURLWithPath: $0)).map { Volumes.isDiskImage($0.mountPath) } ?? false }
        let dead = !draft.sources.allSatisfy { FileManager.default.fileExists(atPath: $0) } || draft.sources.contains { Self.systemPlaces.contains($0) } || internalGuess || onImage
        if !draft.sources.isEmpty && dead && draft.jobIDs.isEmpty {
            model.companion.draft.sources = []; model.companion.draft.outputName = ""
        }
        if draft.sources.isEmpty {
            let ext = model.lastMountedVolume.flatMap { Volumes.find($0) } ?? model.volumes.first { !$0.isInternal }
            if let v = ext { model.suggestSource(v) }
            // No card: don't leave Copy from inside an app or system folder from an earlier visit.
            else if model.sourceBrowser.current == nil || model.sourceBrowser.volume.map({ Volumes.isDiskImage($0.mountPath) }) == true
                        || model.sourceBrowser.current.map({ c in c.path == "/" || ["/Applications", "/System", "/Library", "/private", "/usr"].contains { c.path.hasPrefix($0) } }) == true {
                model.sourceBrowser.open(FileManager.default.homeDirectoryForCurrentUser, record: false)
            }
        }
        if let first = draft.sources.first {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first, isDirectory: &isDir)
            let folder = draft.sources.count == 1 && isDir.boolValue ? first : (first as NSString).deletingLastPathComponent
            if model.sourceBrowser.current?.path != folder { model.sourceBrowser.open(URL(fileURLWithPath: folder), record: false) }
        }
        if let d = draft.destinationParent, !FileManager.default.isWritableFile(atPath: d) { model.companion.draft.destinationParent = nil }
        if model.destBrowser.current.map({ !FileManager.default.isWritableFile(atPath: $0.path) }) == true, draft.destinationParent == nil {
            let fallback = model.settings.defaultDestination.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies").path : model.settings.defaultDestination
            model.destBrowser.open(URL(fileURLWithPath: fallback), record: false)
        }
        if let d = draft.destinationParent, model.destBrowser.current?.path != d { model.destBrowser.open(URL(fileURLWithPath: d), record: false) }
        else if draft.destinationParent == nil, model.destBrowser.current == nil {
            model.destBrowser.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies"), record: false)
        }
        autoName = draft.outputName
    }

    /// What is shown is what is copied: the selected rows, or the open folder itself.
    func syncSource() {
        let b = model.sourceBrowser
        guard let cur = b.current else { return }
        // Never auto-pick system places as "the footage": the Mac's root, /Volumes or the home folder need an explicit row selection.
        // Any real folder you open is the choice; the old "Use This Folder" button is gone.
        if b.selection.isEmpty && Self.systemPlaces.contains(cur.path) {
            if !draft.sources.isEmpty { model.companion.draft.sources = []; model.companion.draft.outputName = "" }
            return
        }
        let picked = b.selection.isEmpty ? [cur] : TransferPlanner.normalizeSources(b.selectedURLs)
        guard picked.map(\.path) != draft.sources else { return }
        model.companion.draft.sources = picked.map(\.path)
        // Rename only while the name is still the automatic one; never overwrite what the user typed.
        if draft.outputName.isEmpty || draft.outputName == autoName {
            var isDir: ObjCBool = false
            let one = picked.count == 1 && FileManager.default.fileExists(atPath: picked[0].path, isDirectory: &isDir) && isDir.boolValue
            let name: String
            if one, let v = Volumes.identity(of: picked[0]), v.mountPath == picked[0].path { name = CameraCard.folderName(volumeName: v.name, brand: CameraCard.detect(picked[0])) }
            else { name = one ? picked[0].lastPathComponent : cur.lastPathComponent }
            model.companion.draft.outputName = name; autoName = name
        }
    }

    func syncDestination() {
        let b = model.destBrowser
        guard let cur = b.current else { return }
        let dest = b.selection.count == 1 ? b.selection.first! : cur.path
        if draft.destinationParent != dest { model.companion.draft.destinationParent = dest }
    }

    /// Re-plan whenever anything that changes the copy changes.
    var planKey: String {
        let d = draft
        return [d.sources.joined(separator: "|"), d.destinationParent ?? "", d.outputName, d.mode.rawValue, d.policy.rawValue, d.scope?.rawValue ?? "all", d.verification.rawValue,
                d.filter.categories.map(\.rawValue).sorted().joined(), d.filter.extraExtensions.joined(), d.filter.excludedExtensions.joined()].joined(separator: "#")
    }

    var fromStatus: (icon: String, text: String, ok: Bool) {
        if draft.sources.isEmpty { return ("hand.point.up.left", "Click the footage to copy", false) }
        let names = draft.sources.map { URL(fileURLWithPath: $0).lastPathComponent }
        return ("checkmark.circle.fill", names.count == 1 ? "Copying: \(names[0])" : "Copying: \(names.count) items", true)
    }

    var toStatus: (icon: String, text: String, ok: Bool) {
        guard let parent = draft.destinationParent else { return ("hand.point.up.left", "Click where to copy", false) }
        if !model.destBrowser.isWritable && model.destBrowser.selection.isEmpty { return ("lock.fill", "Can't copy here: read-only", false) }
        let free = model.destBrowser.volume.map { ", \($0.available.bytesText) free" } ?? ""
        return ("checkmark.circle.fill", "Into: \(URL(fileURLWithPath: parent).lastPathComponent)\(free)", true)
    }

    /// 0 everything (whole card, verified), 1 videos only, 2 chosen file types.
    var whatBinding: Binding<Int> {
        Binding(get: {
            if draft.mode == .cameraCardBackup { return 0 }
            return draft.filter.categories == [.video] ? 1 : 2
        }, set: { v in
            switch v {
            case 0: model.companion.draft.mode = .cameraCardBackup
            case 1: model.companion.draft.mode = .selectiveCopy; model.companion.draft.filter.categories = [.video]
            default:
                model.companion.draft.mode = .selectiveCopy
                if draft.filter.categories == [.video] { model.companion.draft.filter.categories = [.video, .audio, .photo] }
            }
        })
    }

    var typeChips: some View {
        HStack(spacing: 6) {
            ForEach(MediaCategory.allCases, id: \.self) { c in
                let on = draft.filter.categories.contains(c)
                Button { if on { model.companion.draft.filter.categories.remove(c) } else { model.companion.draft.filter.categories.insert(c) } } label: {
                    Label(c.rawValue.capitalized, systemImage: on ? "checkmark.circle.fill" : "circle")
                        .font(.caption).padding(.horizontal, 8).frame(height: 24)
                        .background(on ? Theme.accent.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                        .foregroundStyle(on ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain).accessibilityLabel("\(c.rawValue.capitalized) \(on ? "included" : "excluded")")
            }
        }
    }

    @ViewBuilder var issues: some View {
        if model.destBrowser.isWritable || !model.destBrowser.selection.isEmpty {
        let blocks = plans.flatMap { $0.issues.filter { $0.level == .block }.map(\.message) }
        ForEach(blocks, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Theme.failed) }
        // Warnings are one quiet block, two lines at a time: they are advice, not a wall of text.
        let warns = Array(Set(plans.flatMap { $0.issues.filter { $0.level == .warn }.map(\.message) })).sorted()
        if !warns.isEmpty {
            let shown = showAllWarnings ? warns : Array(warns.prefix(2))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.attention).lineLimit(1) }
                if warns.count > shown.count {
                    Button("Show \(warns.count - shown.count) more warning\(warns.count - shown.count == 1 ? "" : "s")…") { showAllWarnings = true }
                        .buttonStyle(.link).font(.caption2)
                }
            }
        }
        if let dest = model.draftDestination, FileManager.default.fileExists(atPath: dest.path) {
            // Merging is the default: no second "DRIVE 1 (2)" folder, no extra confirmation step.
            Label("Adding to the existing “\(dest.lastPathComponent)”. Same-name files: \(draft.policy.label.lowercased()).",
                  systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        // Same-name files are a real choice: keep both with the next number, or replace. Never guessed.
        let conflicts = plans.reduce(0) { $0 + $1.conflicts.count }
        if conflicts > 0 {
            HStack(spacing: 8) {
                Text(conflicts == 1 ? "1 file already exists" : "\(conflicts) files already exist")
                    .font(.caption).foregroundStyle(Theme.attention)
                Spacer()
                Button("Keep both (number the new one)") {
                    model.companion.draft.policy = .skipIdenticalElseKeepBoth
                    replaceConfirmed = false
                }
                .controlSize(.small)
                .disabled(draft.policy == .skipIdenticalElseKeepBoth)
                Button("Replace…") { model.companion.draft.policy = .replace }
                    .controlSize(.small)
                    .disabled(draft.policy == .replace)
            }
            if draft.policy == .replace {
                Toggle("I understand existing files will be replaced", isOn: $replaceConfirmed)
                    .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.failed)
            }
        }
        if plans.contains(where: { $0.job.verification == .sizeOnly }) {
            Toggle("Copy without checksum verification", isOn: $model.companion.draft.acceptUnverified).toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.attention)
        }
        }
    }

    static func icon(_ c: MediaCategory) -> String {
        switch c { case .video: return "video"; case .audio: return "waveform"; case .photo: return "photo"; case .raw: return "camera.aperture"; case .sidecar: return "doc.text"; case .other: return "questionmark.folder" }
    }

    var copyButton: some View {
        let ok = !planning && PreflightView.canCopy(plans, model: model, acceptUnverified: draft.acceptUnverified,
                                                    mergeConfirmed: mergeConfirmed, replaceConfirmed: replaceConfirmed)
        return Button {
            model.startDraft(plans); plans = []
            // The folder is on its way: clear the pick so the next folder can be chosen without
            // the big button copying the same one twice.
            model.companion.draft.sources = []
            panel.showQueue = false
            for id in model.companion.draft.jobIDs { if let j = model.jobs.first(where: { $0.id == id }) { onQueued?(j) } }
        } label: {
            Text(copyLabel(ok)).font(.headline).frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!ok).keyboardShortcut(.defaultAction)
    }

    /// The button says what it will do, or what is still missing.
    func copyLabel(_ ok: Bool) -> String {
        if planning { return "Counting files…" }
        if draft.destinationParent == nil { return "Choose where to copy" }
        if !model.destBrowser.isWritable && model.destBrowser.selection.isEmpty { return "Choose a folder you can write to" }
        if draft.outputName.trimmingCharacters(in: .whitespaces).isEmpty { return "Name the folder" }
        let replacing = plans.contains { $0.job.conflictPolicy == .replace || $0.items.contains { $0.policy == .replace } }
        if replacing && !replaceConfirmed { return "Confirm replacing existing files" }
        let files = plans.reduce(0) { $0 + $1.items.count }, bytes = plans.reduce(Int64(0)) { $0 + $1.job.totalBytes }
        if !ok || files == 0 { return files == 0 && !plans.isEmpty ? "Nothing to copy" : "Can't copy yet" }
        // Scope-aware label: how much actually moves once the destination is compared.
        if let scope = plans.first?.job.scope, scope != .all {
            let est = plans.compactMap(\.copyBytes).reduce(Int64(0), +)
            let skip = plans.reduce(0) { $0 + (scope == .missingOnly ? $1.conflicts.count : $1.presentSame) }
            return "Copy \(max(0, files - skip)) of \(files) files, \(est.bytesText) — \(skip) already at destination"
        }
        return "Copy \(files) files, \(bytes.bytesText)"
    }

    // MARK: Progress and result

    @ViewBuilder var progressOrResult: some View {
        if draftActive {
            let total = draftJobs.reduce(Int64(0)) { $0 + $1.totalBytes }, done = draftJobs.reduce(Int64(0)) { $0 + $1.copiedBytes }
            let live = draftJobs.compactMap { model.live[$0.id] }.first
            let frac = total > 0 ? Double(done) / Double(total) : 0
            let files = draftJobs.reduce(0) { $0 + ($1.doneFiles ?? 0) }, totalFiles = draftJobs.reduce(0) { $0 + $1.totalFiles }
            let paused = !draftJobs.contains { model.running.contains($0.id) }
            // Fixed layout and height: lines never appear or vanish while copying, so the panel stays still.
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(paused ? "Waiting to copy" : "Copying — \(files) of \(totalFiles) files done").font(.title3.weight(.semibold))
                    Spacer()
                    Text(frac >= 0.001 || done == 0 ? "\(Int(frac * 100))%" : "<1%").font(Theme.number(20))
                }
                ProgressView(value: frac).tint(Theme.accent)
                HStack {
                    Text("\(done.bytesText) of \(total.bytesText)")
                    Spacer()
                    if let bps = live?.bytesPerSecond, bps > 0 { Text("\(Int64(bps).bytesText)/s, \(LocalMetrics.duration(Double(total - done) / bps)) left") }
                    else { Text(" ") }
                }
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text((live?.currentFile).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent } ?? " ")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    ForEach(draftJobs) { j in
                        if model.running.contains(j.id) { Button { model.pause(j) } label: { Label("Pause", systemImage: "pause.fill") } }
                        else if [.paused, .interrupted].contains(j.status) && !model.queue.contains(j.id) {
                            Button { model.resume(j) } label: { Label("Continue", systemImage: "play.fill") }
                                .help("Continue the copy. Files already copied are kept and skipped.")
                        } else if [.failed, .partiallyVerified].contains(j.status) {
                            Button { model.retryFailed(j) } label: { Label("Continue", systemImage: "arrow.clockwise") }
                                .help("Continue with the files that are missing or not verified; copied files are skipped.")
                        }
                    }
                    Button(role: .destructive) { draftJobs.forEach { model.cancel($0) } } label: { Label("Stop", systemImage: "stop.fill") }
                    Spacer()
                    Button { model.companion.draft = TransferDraft(mode: draft.mode) } label: { Label("Copy another", systemImage: "plus") }
                        .help("Set up another copy. This one keeps running.")
                }
                Text(draftJobs.first(where: { $0.status == .interrupted })?.warnings.last ?? "You can close this panel. The copy keeps going.")
                    .font(.caption).foregroundStyle(draftJobs.contains { $0.status == .interrupted } ? Theme.attention : .secondary).lineLimit(1)
            }
            .frame(height: 190, alignment: .top)
            .accessibilityElement(children: .contain)
        } else {
            CompletionCard(ids: draft.jobIDs)
            HandoffSection(jobIDs: draft.jobIDs)
            HStack {
                Spacer()
                Button { model.companion.draft = TransferDraft(mode: draft.mode); model.companion.handoff = nil } label: { Label("Copy More", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .help("Start another copy")
            }
        }
    }
}

/// After a copy: favorite templates with the copied folder preselected; partial copies need an explicit decision.
struct HandoffSection: View {
    @EnvironmentObject var model: AppModel
    let jobIDs: [UUID]
    @Local private var continuePartial = false

    var body: some View {
        let r = model.report(for: jobIDs)
        // Favorites first, then every other template: any of them can start the project.
        let favs = model.orderedFavorites + model.templateList.filter { !$0.favorite }
        VStack(alignment: .leading, spacing: 6) {
            Label("Start a project with this footage", systemImage: "film.stack").font(.subheadline.weight(.semibold))
            if !r.isVerified {
                Toggle("Use anyway (\(r.failed + r.notVerified) files not verified)", isOn: $continuePartial)
                    .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.attention)
            }
            if favs.isEmpty {
                Button { model.companion.tab = .create } label: { Label("Add a template first", systemImage: "doc.badge.plus") }.buttonStyle(.link).font(.caption)
            }
            TemplateTiles(templates: favs, disabled: !r.isVerified && !continuePartial, compact: true) { t in
                model.companion.handoff = ProjectHandoff(transferJobIDs: jobIDs, mediaSource: model.draftDestination?.path, templateID: t.id,
                                                         projectName: model.draftDestination?.lastPathComponent ?? "", continueWithPartial: continuePartial)
                model.companion.tab = .favorites
            }
        }
    }
}

/// Template tiles: thumbnail + name. Context menu holds the less common actions.
struct TemplateTiles: View {
    @EnvironmentObject var model: AppModel
    let templates: [Template]
    var disabled = false
    var manualOrder = false
    /// Denser tiles for the copy-result band, where the tiles sit under a result card.
    var compact = false
    let open: (Template) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 108 : 150, maximum: compact ? 148 : 200),
                                     spacing: compact ? 8 : 12)],
                  spacing: compact ? 8 : 12) {
            ForEach(templates) { t in
                Button { open(t) } label: {
                    VStack(spacing: compact ? 3 : 6) {
                        TemplateIcon(template: t, large: true, compact: compact)
                        Text(t.name).font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(compact ? 5 : 8)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(t.summary.isEmpty ? t.name : t.summary)
                .accessibilityLabel("Template \(t.name)")
                .contextMenu {
                    Button(t.favorite ? "Remove from favorites" : "Add to favorites") { var x = t; x.favorite.toggle(); try? model.templates.updateMetadata(x); model.reloadTemplates() }
                    if manualOrder {
                        Button("Move Earlier") { model.moveFavorite(t, by: -1) }
                        Button("Move Later") { model.moveFavorite(t, by: 1) }
                    }
                    Button("Edit in Full App") { model.openTemplateDetail = t.id; model.selection = .templates; model.openMainWindow() }
                }
            }
        }
    }
}

struct TemplateIcon: View {
    let template: Template
    var large = false
    var compact = false
    var body: some View {
        if large { CoverImage(template: template, corner: 8).frame(height: compact ? 52 : 84).frame(maxWidth: .infinity) }
        else { CoverImage(template: template, corner: 4).frame(width: 34, height: 24) }
    }
}

// MARK: - Favorites page: quick project launch (spec p.12–13)

struct FavoritesPage: View {
    @EnvironmentObject var model: AppModel
    @Local private var search = ""
    @Local private var recentFirst = false
    @Local private var showAll = false
    @Local private var showProjects = false
    @Local private var choosingFootage = false

    var body: some View {
        if model.companion.handoff?.templateID != nil {
            ProjectSetupView()
        } else {
            VStack { // content-sized; shortcut: very long template lists grow the panel, add scrolling past ~12 favorites
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Search templates", text: $search).textFieldStyle(.plain)
                        Picker("Sort", selection: $recentFirst) { Text("My order").tag(false); Text("Recently used").tag(true) }
                            .pickerStyle(.menu).labelsHidden().fixedSize().help("Sort templates")
                    }
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    if let last = footage {
                        let selectedJob = model.jobs.first { $0.outputPath == last }
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.verified)
                            // Every copied folder, not only the last one: pick the footage this project uses.
                            Menu {
                                ForEach(copiedFolders, id: \.self) { path in
                                    Button { chooseFootage(path) } label: {
                                        if path == last { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark") }
                                        else { Text(URL(fileURLWithPath: path).lastPathComponent) }
                                    }
                                }
                                Divider()
                                Button("Choose Folder…") { choosingFootage = true }
                            } label: {
                                Text("Footage: \(URL(fileURLWithPath: last).lastPathComponent)").font(.callout.weight(.medium))
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                            .help(last)
                            if let j = selectedJob {
                                Text("\(j.totalFiles) files · \(j.totalBytes.bytesText) · \(j.status.label.lowercased())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.companion.handoff?.mediaSource != nil {
                                Button("Clear") { model.companion.handoff = nil }.controlSize(.small)
                            } else {
                                Text("Last checked copy").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Footage \(URL(fileURLWithPath: last).lastPathComponent)")
                    }
                    Text("Pick a template to start the project").font(.headline)
                    let favs = list(model.orderedFavorites)
                    if favs.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "heart").font(.system(size: 28)).foregroundStyle(Theme.favorite)
                            Text("Tap the heart on a template to keep it here").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    TemplateTiles(templates: favs, manualOrder: !recentFirst) { start($0) }
                    let others = list(model.templateList.filter { !$0.favorite })
                    if !others.isEmpty {
                        DisclosureGroup(isExpanded: $showAll) {
                            TemplateTiles(templates: others) { start($0) }.padding(.top, 6)
                        } label: { Label("All templates", systemImage: "square.grid.2x2").font(.callout) }
                    }
                    if !model.sessions.isEmpty { recentProjects }
                }
            }
            .sheet(isPresented: $choosingFootage) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose footage").font(.headline)
                    BrowserView(browser: model.sourceBrowser, title: "Footage", compact: true) { urls in
                        if let u = urls.first { chooseFootage(u.path) }
                        choosingFootage = false
                    }
                    HStack { Spacer(); Button("Cancel") { choosingFootage = false } }
                }
                .padding(16).frame(width: 720, height: 520)
            }
        }
    }

    /// Folders a verified copy produced, newest first, plus the last checked one.
    var copiedFolders: [String] {
        var seen = Set<String>(), out: [String] = []
        for j in model.jobs.sorted(by: { $0.created > $1.created }) where j.status == .verified {
            if seen.insert(j.outputPath).inserted { out.append(j.outputPath) }
        }
        if let last = model.companion.lastVerifiedDestination, seen.insert(last).inserted { out.append(last) }
        return Array(out.prefix(8))
    }

    func chooseFootage(_ path: String) {
        var h = model.companion.handoff ?? ProjectHandoff()
        h.mediaSource = path
        h.transferJobIDs = model.jobs.filter { $0.outputPath == path }.map(\.id)
        if h.projectName.isEmpty { h.projectName = URL(fileURLWithPath: path).lastPathComponent }
        model.companion.handoff = h
    }

    /// Already-made projects: open one again without rebuilding it.
    var recentProjects: some View {
        DisclosureGroup(isExpanded: $showProjects) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.sessions.prefix(6)) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.state == .ready ? "checkmark.circle.fill" : "film")
                            .foregroundStyle(s.state == .ready ? Theme.verified : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).lineLimit(1)
                            Text("\(s.templateName) · \(s.created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open in Resolve") { model.openInResolve(s) }.controlSize(.small)
                    }
                    .padding(.vertical, 3)
                    .help(s.projectFolder)
                }
            }.padding(.top, 4)
        } label: { Label("Recent projects", systemImage: "clock.arrow.circlepath").font(.callout) }
    }

    /// Footage dropped on the menu bar icon wins over the last checked copy.
    var footage: String? { model.companion.handoff?.mediaSource ?? model.companion.lastVerifiedDestination }

    func start(_ t: Template) {
        let src = footage
        model.companion.handoff = ProjectHandoff(transferJobIDs: model.companion.handoff?.transferJobIDs ?? [], mediaSource: src, templateID: t.id,
                                                 projectName: model.companion.handoff?.projectName.isEmpty == false ? model.companion.handoff!.projectName : (src.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""))
    }

    func list(_ l: [Template]) -> [Template] {
        let f = l.filter { $0.matches(search) }
        return recentFirst ? f.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) } : f
    }
}

/// Compact project setup (spec p.12): name, media source, project library, saved rules, advanced collapsed.
struct ProjectSetupView: View {
    @EnvironmentObject var model: AppModel
    @Local private var showAdvanced = false
    @Local private var choosingSource = false
    @Local private var working = false

    var h: ProjectHandoff { model.companion.handoff ?? ProjectHandoff() }
    var template: Template? { h.templateID.flatMap { id in model.templateList.first { $0.id == id } } }
    var session: ProjectSession? { h.resultSessionID.flatMap { id in model.sessions.first { $0.id == id } } }
    var binding: Binding<ProjectHandoff> { Binding(get: { model.companion.handoff ?? ProjectHandoff() }, set: { model.companion.handoff = $0 }) }

    /// Checked copies the app made, newest first, so the project can use any of them.
    var copiedFolders: [String] {
        var seen = Set<String>(), out: [String] = []
        for j in model.jobs.sorted(by: { $0.created > $1.created }) where j.status == .verified {
            if seen.insert(j.outputPath).inserted { out.append(j.outputPath) }
        }
        if let last = model.companion.lastVerifiedDestination, seen.insert(last).inserted { out.append(last) }
        return Array(out.prefix(8))
    }

    func useFootage(_ path: String) {
        model.companion.handoff?.mediaSource = path
        model.companion.handoff?.transferJobIDs = model.jobs.filter { $0.outputPath == path }.map(\.id)
        model.companion.handoff?.mappings = []
        suggestBins()
    }

    var body: some View {
        VStack { // content-sized; shortcut: very long template lists grow the panel, add scrolling past ~12 favorites
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { model.companion.handoff = nil } label: { Label("Favorites", systemImage: "chevron.left") }.buttonStyle(.borderless)
                    Spacer()
                    if let t = template { TemplateIcon(template: t); Text(t.name).bold() }
                }
                if let s = session { result(s) } else if choosingSource { sourceChooser } else { form }
            }
        }
        .onAppear(perform: suggestBins)
        .onChange(of: h.mediaSource) { _, _ in model.companion.handoff?.mappings = []; suggestBins() }
    }

    /// Every footage folder (and folder inside it): include it or not, and pick or type the bin it goes in.
    var binsEditor: some View {
        let included = h.mappings.filter { $0.action != .omit }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bins in Resolve").font(.headline)
                Spacer()
                Text("\(included) of \(h.mappings.count) folders").font(.caption).foregroundStyle(.secondary)
            }
            Text("Pick where each folder goes, or type a new bin name. Folders left empty go in the Master bin.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(h.mappings.enumerated()), id: \.element.id) { i, m in binRow(i, m) }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    func binRow(_ i: Int, _ m: BinMapping) -> some View {
        let root = h.mediaSource ?? ""
        let rel = m.sourcePath == root ? URL(fileURLWithPath: root).lastPathComponent
            : (URL(fileURLWithPath: root).lastPathComponent + String(m.sourcePath.dropFirst(root.count)))
        let depth = max(0, rel.split(separator: "/").count - 1)
        let skipped = m.action == .omit
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { !skipped }, set: { on in
                guard i < (model.companion.handoff?.mappings.count ?? 0) else { return }
                let bin = model.companion.handoff!.mappings[i].targetBin
                model.companion.handoff?.mappings[i].action = on ? (bin.isEmpty ? .importMedia : .createBinAndImport) : .omit
            }))
            .toggleStyle(.checkbox).labelsHidden().help(skipped ? "Not imported" : "Imported").accessibilityLabel("Import \(rel)")
            Label(URL(fileURLWithPath: m.sourcePath).lastPathComponent, systemImage: "folder")
                .lineLimit(1).padding(.leading, CGFloat(depth) * 14)
                .frame(width: 230, alignment: .leading).help(rel)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            TextField("Master bin", text: Binding(get: { i < h.mappings.count ? h.mappings[i].targetBin : "" }, set: { setBin(i, $0) }))
                .textFieldStyle(.roundedBorder)
            Menu {
                Button("Master bin (top level)") { setBin(i, "") }
                Divider()
                ForEach(binChoices, id: \.self) { b in Button(b) { setBin(i, b) } }
                Divider()
                Menu("New bin inside") {
                    Button("Master bin") { setBin(i, "New Bin") }
                    ForEach(binChoices, id: \.self) { b in Button(b) { setBin(i, b + "/New Bin") } }
                }
            } label: { Text("Choose") }
                .menuStyle(.borderlessButton).fixedSize().help("Pick a bin from the template, or make a new one")
        }
        .opacity(skipped ? 0.45 : 1)
    }

    /// The template's bins plus any typed so far, for the Choose menu.
    var binChoices: [String] {
        let fromTemplate = template?.current.bins.map(\.binPath) ?? []
        return Array(Set(fromTemplate + h.mappings.map(\.targetBin)).filter { !$0.isEmpty }).sorted()
    }

    func setBin(_ i: Int, _ v: String) {
        guard i < (model.companion.handoff?.mappings.count ?? 0) else { return }
        model.companion.handoff?.mappings[i].targetBin = v
        if model.companion.handoff?.mappings[i].action != .omit {
            let exists = template?.current.bins.contains { $0.binPath == v } ?? false
            model.companion.handoff?.mappings[i].action = v.isEmpty || exists ? .importMedia : .createBinAndImport
        }
    }

    /// One bin per footage folder (nested like on disk), ready to rename before the project is made.
    func suggestBins() {
        guard h.mappings.isEmpty, let t = template, let src = h.mediaSource else { return }
        let source = MediaSource(path: src, label: URL(fileURLWithPath: src).lastPathComponent, volume: nil, transferJobID: nil)
        var rows = model.projects.suggestMappings(sources: [source], bins: t.current.bins, templateID: t.id)
        // A project folder made inside the footage folder must never become a bin source itself.
        if destinationInsideSource {
            let dest = projectFolderPath
            rows.removeAll { $0.sourcePath == dest || $0.sourcePath.hasPrefix(dest + "/") }
        }
        model.companion.handoff?.mappings = rows
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Project name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    // The name is the one field every project needs: a filled, amber-edged box makes it findable.
                    TextField("Project name, e.g. Mohan & Anbika - Mehndi", text: binding.projectName)
                        .textFieldStyle(.plain).font(.title3.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
                        .accessibilityLabel("Project name")
                }
                GridRow {
                    Text("Footage folder").foregroundStyle(.secondary)
                    if let src = h.mediaSource {
                        HStack {
                            Image(systemName: h.transferJobIDs.isEmpty ? "folder" : "checkmark.circle.fill").foregroundStyle(h.transferJobIDs.isEmpty ? .secondary : Theme.verified)
                            // Every checked copy is one click away: the project can be built from any of them.
                            Menu {
                                ForEach(copiedFolders, id: \.self) { path in
                                    Button { useFootage(path) } label: {
                                        if path == src { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark") }
                                        else { Text(URL(fileURLWithPath: path).lastPathComponent) }
                                    }
                                }
                                if !copiedFolders.isEmpty { Divider() }
                                Button("Choose Folder…") { choosingSource = true }
                            } label: {
                                Text(URL(fileURLWithPath: src).lastPathComponent).lineLimit(1)
                            }
                            .menuStyle(.borderlessButton).fixedSize().help(src)
                            Spacer()
                            Button("Change…") { choosingSource = true }.controlSize(.small)
                        }
                    } else {
                        HStack {
                            Button("Choose Footage…") { choosingSource = true }
                            Button("Copy a Card First") { copyFirst() }
                                .help("Copy and check the card in the Copy tab; then come back here.")
                        }
                    }
                }
                GridRow {
                    Text("Project folder").foregroundStyle(.secondary)
                    HStack {
                        Text(library.isEmpty ? "Not set" : URL(fileURLWithPath: library).lastPathComponent).lineLimit(1).help(libraryText)
                        Spacer()
                        Button("Change…") {
                            if let u = AppModel.chooseFolder(prompt: "Use", start: library.isEmpty ? nil : library) {
                                model.companion.handoff?.projectLibrary = u.path
                                model.companion.handoff?.mappings = []
                                suggestBins()
                            }
                        }.controlSize(.small)
                    }
                }
                GridRow {
                    Text("Input color space").foregroundStyle(.secondary)
                    Picker("Input color space", selection: Binding(
                        get: { h.settings?.inputColorSpace ?? template?.current.settings.inputColorSpace ?? "" },
                        set: { v in
                            var s = h.settings ?? template?.current.settings ?? SettingsProfile()
                            // "" is an explicit Auto: it overrides a template default instead of inheriting it.
                            s.inputColorSpace = v
                            model.companion.handoff?.settings = s
                        })) {
                        ForEach(SettingsProfile.inputColorSpaces, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden().frame(maxWidth: 320)
                    .help("Resolve Color Management reads every imported clip in this space and shows the timeline in Rec.709, so S-Log3 or HLG looks right as soon as it is dragged in.")
                }
            }
            if let src = h.mediaSource {
                if Self.tooBroad(src) {
                    Label("That is a whole system folder. Choose the folder with the footage.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Theme.attention)
                }
                if destinationInsideSource {
                    Label("The project folder is inside the footage folder. Pick another project folder, or every copy would nest inside the footage.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Theme.attention)
                }
            }
            if !h.mappings.isEmpty { binsEditor }
            if let t = template {
                DisclosureGroup("Resolution and frame rate", isExpanded: $showAdvanced) {
                    SettingsProfileEditor(settings: Binding(get: { h.settings ?? t.current.settings }, set: { model.companion.handoff?.settings = $0 }))
                }.font(.callout)
            }
            HStack(spacing: 10) {
                if h.mediaSource != nil {
                    Button { copyFirst() } label: { Label("Copy Footage…", systemImage: "arrow.left.arrow.right") }
                        .controlSize(.small)
                        .help("Copying and checksum checks happen in the Copy tab. This page only opens the project in Resolve.")
                }
                Spacer()
                Button { create() } label: { Label(working ? "Creating…" : "Open in Resolve", systemImage: "play.rectangle.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(working || h.projectName.trimmingCharacters(in: .whitespaces).isEmpty || h.mediaSource == nil || library.isEmpty || template == nil
                              || h.mediaSource.map(Self.tooBroad) == true || destinationInsideSource)
            }
        }
    }

    /// Home, Desktop, a whole drive's system root: never footage to copy into a project.
    static func tooBroad(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return ["/", "/Volumes", "/Users", home, home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Movies"].contains(path)
    }

    /// Saved project library, else the footage's parent. A card root supplies `/Volumes`, which is never
    /// a project library, so fall back to the user's Movies folder instead.
    var library: String {
        if !h.projectLibrary.isEmpty { return h.projectLibrary }
        if !model.settings.defaultProjectsFolder.isEmpty { return model.settings.defaultProjectsFolder }
        guard let src = h.mediaSource else { return "" }
        let parent = URL(fileURLWithPath: src).deletingLastPathComponent().path
        if parent == "/" || parent == "/Volumes" { return NSHomeDirectory() + "/Movies/Editor Workflow" }
        return parent
    }

    /// The folder name that will be made: the typed name, made unique against the project folder.
    /// Uses existence checks instead of listing the whole library on every keystroke.
    var plannedName: String {
        let raw = h.projectName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !raw.isEmpty, !library.isEmpty else { return raw }
        let base = URL(fileURLWithPath: library)
        var candidate = raw
        var n = 2
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            candidate = "\(raw) (\(n))"
            n += 1
        }
        return candidate
    }

    /// What the "Project folder" row shows: the chosen library plus the folder name that will be made.
    var libraryText: String {
        plannedName.isEmpty ? library : URL(fileURLWithPath: library).appendingPathComponent(plannedName).path
    }

    /// The folder that will actually be created. Empty until a library and name exist.
    var projectFolderPath: String {
        guard !library.isEmpty else { return "" }
        return (plannedName.isEmpty ? library : URL(fileURLWithPath: library).appendingPathComponent(plannedName).path)
            .replacingOccurrences(of: "//", with: "/")
    }

    /// A project folder inside the footage folder copies the project into its own source (recursive bins).
    var destinationInsideSource: Bool {
        guard let src = h.mediaSource, !projectFolderPath.isEmpty else { return false }
        let source = URL(fileURLWithPath: src).standardizedFileURL.path
        let dest = projectFolderPath
        return dest == source || dest.hasPrefix(source + "/")
    }

    /// Sends this footage to the Copy tab. This page never copies.
    func copyFirst() {
        guard let src = h.mediaSource else { model.companion.tab = .transfer; return }
        var d = TransferDraft()
        d.sources = [src]
        d.stage = .destination
        d.policy = model.settings.conflictPolicy
        d.destinationParent = model.recentPairs.first?.destination
            ?? (model.settings.defaultDestination.isEmpty ? nil : model.settings.defaultDestination)
            ?? (NSHomeDirectory() + "/Movies")
        d.outputName = (h.projectName.isEmpty ? URL(fileURLWithPath: src).lastPathComponent : h.projectName) + " Footage"
        model.companion.draft = d
        model.companion.handoff?.resultSessionID = nil
        model.companion.tab = .transfer
    }

    var sourceChooser: some View {
        VStack(alignment: .leading) {
            Text("Choose existing footage").font(.headline)
            BrowserView(browser: model.sourceBrowser, title: "Media", compact: true) { urls in
                model.companion.handoff?.mediaSource = urls.first?.path
                model.companion.handoff?.transferJobIDs = []
                if h.projectName.isEmpty { model.companion.handoff?.projectName = urls.first?.lastPathComponent ?? "" }
                choosingSource = false
            }
            Button("Cancel") { choosingSource = false }
        }
    }

    func create() {
        guard let t = template, let src = h.mediaSource, !library.isEmpty else { return }
        guard library != "/" && library != "/Volumes" else {
            model.errorMessage = "Choose a real project folder. A whole volume root cannot hold the project."
            return
        }
        guard !destinationInsideSource else {
            model.errorMessage = "Choose a project folder outside the footage folder. A project created inside its own footage would map itself."
            return
        }
        working = true
        let sources = [MediaSource(path: src, label: URL(fileURLWithPath: src).lastPathComponent, volume: Volumes.identity(of: URL(fileURLWithPath: src)), transferJobID: h.transferJobIDs.first)]
        let mappings = h.mappings.isEmpty ? model.projects.suggestMappings(sources: sources, bins: t.current.bins, templateID: t.id) : h.mappings
        do {
            let s = try model.projects.create(name: h.projectName, template: t, destinationRoot: URL(fileURLWithPath: library), createFolders: true,
                                              sources: sources, mappings: mappings, settings: h.settings ?? t.current.settings)
            model.companion.handoff?.resultSessionID = s.id
            model.reload()
            // One action: make the project and open it. Studio imports the clips; otherwise Resolve opens
            // the project copy and the Import Steps show what is left.
            model.runResolveAutomation(for: s)
        } catch { model.report(error) }
        working = false
    }

    func result(_ s: ProjectSession) -> some View {
        let busy = model.automating.contains(s.id)
        // Only a saved Resolve project counts as done. Manual and partial states need the editor.
        let ok = !busy && s.state == .ready
        let title = s.state == .failed ? "Project could not be created"
            : (s.state == .manualStepRequired || s.state == .partiallyCompleted) ? "Project folder created: \(s.name)"
            : "Project created: \(s.name)"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: busy ? "arrow.triangle.2.circlepath" : (ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")).font(.system(size: 26))
                    .foregroundStyle(busy ? Theme.accent : (ok ? Theme.verified : Theme.attention))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if model.automating.contains(s.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Opening in DaVinci Resolve and importing the clips…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(nextStep(s)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: s.projectFolder)) } label: { Label("Open Folder", systemImage: "folder") }
                if FileManager.default.fileExists(atPath: ResolveAdapter.appPath) {
                    Button { model.openInResolve(s) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: ResolveAdapter.appPath)).resizable().frame(width: 18, height: 18)
                            Text("Open in DaVinci Resolve")
                        }
                    }
                    .disabled(model.automating.contains(s.id))
                    Button { model.selection = .projects; model.openMainWindow() } label: { Label("Edit", systemImage: "pencil") }
                        .help("See and change this project in the full app")
                }
                if s.state != .ready, let c = s.checklistPath {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: c)) } label: { Label("Import Steps", systemImage: "list.number") }
                        .help("How to bring this project into Resolve")
                }
                Spacer()
                Button("Done") { model.companion.handoff = nil }.buttonStyle(.borderedProminent)
            }
        }
    }

    func nextStep(_ s: ProjectSession) -> String {
        switch s.state {
        case .ready: return "It is open in Resolve."
        case .manualStepRequired: return "The folder is ready. Resolve is not connected, so import it from Import Steps."
        case .partiallyCompleted: return "Some steps need you in Resolve."
        case .failed: return s.receipts.last(where: { $0.status == "failed" })?.detail ?? "See Projects for details."
        case .draft: return "Working…"
        }
    }
}

// MARK: - Create Template page: drop a .drp (spec p.14)

struct CreateTemplatePage: View {
    @EnvironmentObject var model: AppModel
    @Local private var targeted = false
    @Local private var created: UUID?
    @Local private var pendingURL: URL?
    @Local private var duplicateOf: Template?
    @Local private var newName = ""
    @Local private var failure: String?
    @Local private var scanning = false
    /// Edits are kept here and saved after a short pause: saving on every keystroke made typing slow.
    @Local private var edit: Template?
    @Local private var tagsText = ""

    var template: Template? { created.flatMap { id in model.templateList.first { $0.id == id } } }

    var body: some View {
        VStack { // content-sized; shortcut: very long template lists grow the panel, add scrolling past ~12 favorites
            VStack(alignment: .leading, spacing: 10) {
                if let t = template { form(t) }
                else if let dup = duplicateOf, let url = pendingURL { duplicateChoice(dup, url) }
                else { drop }
                if let failure { Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption) }
            }
        }
        .onReceive(model.$pendingTemplateDrop) { u in
            guard let u else { return }
            model.pendingTemplateDrop = nil
            begin(u)
        }
        .task(id: "\(edit?.hashValue ?? 0)|\(tagsText)") {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { saveEdit() }
        }
    }

    func open(_ id: UUID?) {
        saveEdit()
        created = id
        edit = id.flatMap { model.templates.get($0) }
        tagsText = edit?.tags.joined(separator: ", ") ?? ""
    }

    func saveEdit() {
        guard var e = edit, let stored = model.templates.get(e.id) else { return }
        e.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        e.cover = stored.cover          // the cover box saves itself
        e.versions = stored.versions    // resource rules save themselves
        guard e != stored else { return }
        try? model.templates.updateMetadata(e)
        model.reloadTemplates()
    }

    var drop: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                .frame(height: 200)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop a DaVinci Resolve .drp file here").font(.headline)
                        Text("Your original file is never changed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in begin(url) } } }
                    return true
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Drop zone for a DaVinci Resolve .drp file")
            Button("Browse…") {
                let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "drp") ?? .data]
                if p.runModal() == .OK, let u = p.url { begin(u) }
            }
            if model.resolveStatus?.canAutomate == true {
                Button("Use the Project Open in Resolve") { model.templateFromOpenResolveProject { open($0.id) } }.buttonStyle(.link)
            }
        }
    }

    func begin(_ url: URL) {
        failure = nil
        guard url.pathExtension.lowercased() == "drp" else { failure = "\(url.lastPathComponent) is not a .drp file. Nothing was changed."; return }
        do { try TemplateStore.validate(url) } catch { failure = "\(error) The original file is unchanged."; return }
        let name = url.deletingPathExtension().lastPathComponent
        if let dup = model.templateList.first(where: { $0.name.collisionKey == name.collisionKey }) {
            pendingURL = url; duplicateOf = dup; newName = ProjectStore.uniqueName(name, taken: model.templateList.map(\.name)); return
        }
        importAs(url, name: name)
    }

    func importAs(_ url: URL, name: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { let t = try model.templates.importTemplate(from: url, name: name); model.reloadTemplates(); model.autoCover(t.id); open(t.id); duplicateOf = nil; pendingURL = nil }
        catch { failure = "\(error) The original file is unchanged." }
    }

    func duplicateChoice(_ dup: Template, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("A template named \"\(dup.name)\" already exists.", systemImage: "doc.on.doc").font(.headline)
            HStack { Text("Import as"); TextField("Name", text: $newName).textFieldStyle(.roundedBorder); Button("Rename & Import") { importAs(url, name: newName) }.disabled(newName.isEmpty) }
            Button("Save as a new version of \"\(dup.name)\"") {
                do { _ = try model.templates.replaceMaster(of: dup.id, with: url, note: "New master from \(url.lastPathComponent)"); model.reloadTemplates(); open(dup.id); duplicateOf = nil }
                catch { failure = "\(error)" }
            }
            Button("Cancel") { duplicateOf = nil; pendingURL = nil }
        }
    }

    func form(_ t: Template) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CoverBox(template: t, height: 100).frame(width: 170)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("Template name", text: field(\.name)).textFieldStyle(.roundedBorder).font(.headline)
                        Button { edit?.favorite.toggle() } label: {
                            Image(systemName: edit?.favorite == true ? "heart.fill" : "heart").font(.title3)
                                .foregroundStyle(edit?.favorite == true ? Theme.favorite : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(edit?.favorite == true ? "Remove from favorites" : "Add to favorites")
                        .accessibilityLabel(edit?.favorite == true ? "Remove from favorites" : "Add to favorites")
                    }
                    TextField("Category", text: field(\.category)).textFieldStyle(.roundedBorder)
                    TextField("Tags", text: $tagsText).textFieldStyle(.roundedBorder).help("Comma separated, e.g. wedding, outdoor")
                }
            }
            TextField("Short description", text: field(\.summary)).textFieldStyle(.roundedBorder)
            let diags = t.current.diagnostics ?? []
            if !diags.isEmpty {
                let warn = diags.contains { $0.contains("newer") }
                StatusPill(diags.count == 1 ? "1 note" : "\(diags.count) notes", warn ? "exclamationmark.triangle.fill" : "info.circle",
                           warn ? Theme.attention : .secondary, help: diags.joined(separator: "\n"))
            }
            Divider()
            let missing = t.current.assets.filter { $0.status == .knownMissing }
            HStack {
                Text("Resources").font(.subheadline.bold())
                if !missing.isEmpty {
                    StatusPill("\(missing.count) missing", "exclamationmark.triangle.fill", Theme.attention, help: "Locate them or mark them Optional in the full app.")
                }
                Spacer()
                if model.resolveStatus?.canAutomate == true {
                    Button {
                        scanning = true
                        model.scanDependencies(t.current) { found in
                            _ = try? model.templates.newVersion(of: t.id, note: "Resources scanned") { $0.assets = TemplateStore.merge(found, into: $0.assets) }
                            model.reloadTemplates(); scanning = false
                        }
                    } label: { Label(scanning ? "Scanning…" : "Scan in Resolve", systemImage: "wand.and.stars") }
                        .controlSize(.small).disabled(scanning)
                }
            }
            if t.current.assets.isEmpty {
                Text("None listed yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(t.current.assets.prefix(8)) { a in
                    HStack {
                        Text(a.name).font(.caption).lineLimit(1)
                        if a.status == .knownMissing { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.attention).help(a.status.label) }
                        Spacer()
                        Picker("", selection: Binding(get: { a.rule }, set: { r in setRule(t, a, r) })) { ForEach(AssetRule.allCases, id: \.self) { Text($0.rawValue.capitalized) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Open in App") { saveEdit(); model.openTemplateDetail = t.id; model.selection = .templates; model.openMainWindow() }
                Button("Done") { open(nil) }.buttonStyle(.borderedProminent)
            }
        }
    }

    func field(_ kp: WritableKeyPath<Template, String>) -> Binding<String> {
        Binding(get: { edit?[keyPath: kp] ?? "" }, set: { edit?[keyPath: kp] = $0 })
    }

    func setRule(_ t: Template, _ a: AssetRuleEntry, _ r: AssetRule) {
        _ = try? model.templates.newVersion(of: t.id, note: "Asset rule changed") { v in
            if let i = v.assets.firstIndex(where: { $0.id == a.id }) { v.assets[i].rule = r }
        }
        model.reloadTemplates()
    }
}


/// Shown while a file is dragged toward the menu bar: two big targets, one per thing the app can do with it.
struct DropScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var panel: PanelState
    @Local private var over = false

    // One target: photos go to the Shelf, a .drp makes a template, footage starts a project.
    var body: some View {
        zone("arrow.down.doc", "Drop it here", "Photos go to the Shelf. A .drp becomes a template. Footage starts a project.", $over)
            .frame(height: 240)
            .padding(.top, 6)
    }

    func zone(_ icon: String, _ title: String, _ subtitle: String, _ over: Binding<Bool>) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(over.wrappedValue ? Theme.accent : Color.secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 16).fill(over.wrappedValue ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.06)))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(over.wrappedValue ? Theme.accent : .secondary)
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            .scaleEffect(over.wrappedValue && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: over.wrappedValue)
            .onDrop(of: [.fileURL, .image], isTargeted: over) { providers in
                // File drops give URLs directly; image data (Photos, browser, screenshots) is
                // written into the shelf folder first, so both kinds land somewhere real.
                ShelfIngest.run(providers) { urls in
                    panel.dropMode = false
                    model.handleDropped(urls)
                }
                return true
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(subtitle)")
    }
}
