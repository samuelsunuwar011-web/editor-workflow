import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// Pause flags read from the copy thread on every chunk.
final class Flags: @unchecked Sendable {
    private var d: [UUID: Bool] = [:]
    private let l = NSLock()
    subscript(id: UUID) -> Bool {
        get { l.lock(); defer { l.unlock() }; return d[id] ?? false }
        set { l.lock(); d[id] = newValue; l.unlock() }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home", templates = "Templates", transfers = "Transfers", projects = "Projects", history = "History", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .templates: return "square.grid.2x2"
        case .transfers: return "arrow.left.arrow.right"
        case .projects: return "film.stack"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// A folder the user authorized, stored as a bookmark so it survives renames/remounts.
struct SavedLocation: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data?
    var favorite = true
}

struct AppSettings: Codable, Equatable {
    var defaultDestination = ""
    var defaultProjectsFolder = ""
    var conflictPolicy: ConflictPolicy = .skipIdenticalElseKeepBoth
    var notifyOnFinish = true
    /// Project naming preset, e.g. "{date} {template}". Tokens: {template} {category} {date} {year}.
    var namePattern: String?
    // Menu bar companion. Optional so settings saved by older versions still load.
    var autoOpen: AutoOpenMode?
    var trustedOnly: Bool?
    var trustedDrives: [String]?
    /// Jobs allowed at once (default 4). 1 = strictly one at a time.
    var maxConcurrent: Int?
    var resolveAppPath: String?
    /// Unsplash API access key for automatic template covers (Openverse is used without one).
    var unsplashKey: String?
    var openAtLogin: Bool?
    /// The first-run welcome (permissions) was finished.
    var onboarded: Bool?
}

/// Live state of a running job for progress displays (not persisted).
struct LiveProgress: Equatable {
    var phase = "Preparing"
    var currentFile = ""
    var samples: [(Date, Int64)] = []
    /// Files that started within the last moment: when several streams run at once the row
    /// shows a count ("4 files at once") instead of flickering between file names.
    var recentFiles: [(Date, String)] = []
    static func == (a: LiveProgress, b: LiveProgress) -> Bool { a.phase == b.phase && a.currentFile == b.currentFile && a.samples.count == b.samples.count }
    /// Rolling speed over the last ~5 seconds.
    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) > 0.5 else { return nil }
        return Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
    }
}

struct RecentPair: Codable, Hashable { var source: String; var destination: String; var used = Date() }

@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths
    let db: Database
    let templates: TemplateStore
    let projects: ProjectStore
    let runner: TransferRunner
    let resolve: ResolveAdapter

    @Published var selection: SidebarItem? = .home
    @Published var templateList: [Template] = []
    @Published var sessions: [ProjectSession] = []
    @Published var jobs: [TransferJob] = []
    @Published var volumes: [VolumeIdentity] = []
    @Published var locations: [SavedLocation] = []
    @Published var settings = AppSettings()
    @Published var resolveStatus: ResolveStatus?
    @Published var showWizard = false
    @Published var wizardTemplateID: UUID?
    @Published var showImporter = false
    @Published var transferPreset: (source: String?, destination: String?)?
    @Published var errorMessage: String?
    /// Template the main window should open in its detail sheet (set from the menu bar).
    @Published var openTemplateDetail: UUID?
    private var mainWindow: NSWindow?

    static let shared = AppModel()
    @Published private(set) var queue: [UUID] = []
    @Published private(set) var running: Set<UUID> = []
    /// True while a window opened from the panel (photo picker, Pinterest) is up, so the panel stays open behind it.
    @Published var keepPanelOpen = false
    /// A .drp dropped on the menu bar icon, waiting for the Add Template page to take it.
    @Published var pendingTemplateDrop: URL?

    /// Photos → Shelf. .drp → Add Template. Folder or footage → New Project with that media.
    /// Anything else is refused with a reason — never silently turned into a "project".
    func handleDropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Photos are the shelf's job — route them there no matter where they were dropped.
        let isShelf: (URL) -> Bool = {
            AppModel.imageExts.contains($0.pathExtension.lowercased()) || MediaCategory.of($0) == .photo
        }
        let images = urls.filter(isShelf)
        let rest = urls.filter { !isShelf($0) }
        if !images.isEmpty {
            ScratchpadStore.shared.addShelf(urls: images)
            companion.tab = .shelf
        }
        guard let u = rest.first else { return }
        if rest.count > 1 {
            errorMessage = "Drop one .drp or one footage folder at a time. Photos all go to the Shelf; add extra media folders in the project wizard."
            return
        }
        if u.pathExtension.lowercased() == "drp" {
            pendingTemplateDrop = u
            companion.tab = .create
            return
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        let cat = MediaCategory.of(u)
        if isDir.boolValue || cat == .video || cat == .raw || cat == .audio {
            companion.handoff = ProjectHandoff(mediaSource: u.path, projectName: u.deletingPathExtension().lastPathComponent)
            companion.tab = .favorites
        } else {
            errorMessage = "\"\(u.lastPathComponent)\" isn't footage. Photos go on the Shelf, a .drp on Add Template; a folder, video, audio or RAW file starts a project."
        }
    }
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "ico", "avif"]
    /// Copies being checked again right now.
    @Published private(set) var rechecking: Set<UUID> = []
    /// Projects whose Resolve import is running right now.
    @Published private(set) var automating: Set<UUID> = []
    @Published var live: [UUID: LiveProgress] = [:]
    @Published var companion = CompanionState() { didSet { if companion != oldValue { saveCompanionSoon() } } }
    @Published var pendingTrust: VolumeIdentity?
    @Published var lastMountedVolume: VolumeIdentity?
    let sourceBrowser = BrowserModel(allowFiles: true)
    let destBrowser = BrowserModel(allowFiles: false)
    /// Set by the app delegate: shows the menu bar panel on a given tab.
    var showPanel: (CompanionTab) -> Void = { _ in }
    var showPanelWindow: () -> Void = {}
    private var saveTask: Task<Void, Never>?
    private let cancelFlags = Flags()
    private var stopReasons: [UUID: String] = [:]
    @Published var recentPairs: [RecentPair] = []
    private let work = DispatchQueue(label: "transfers", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    init() {
        paths = AppPaths.standard
        do {
            try paths.create()
            db = try Database(path: paths.database.path)
        } catch {
            fatalError("Cannot open app storage at \(paths.root.path): \(error)")
        }
        templates = TemplateStore(db: db, paths: paths)
        projects = ProjectStore(db: db, templates: templates)
        runner = TransferRunner(db: db, paths: paths)
        let bridge = Bundle.main.url(forResource: "resolve_bridge", withExtension: "py")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../Resources/resolve_bridge.py").standardizedFileURL
        resolve = ResolveAdapter(bridge: bridge)
        Log.directory = paths.logs
        let capDB = db
        resolve.storedCapabilities = { key in capDB.get("capabilities", id: key) }
        Log.info("app started", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"])
        settings = db.get("settings", id: "app") ?? AppSettings()
        if let p = settings.resolveAppPath { ResolveAdapter.appPath = p }
        companion = db.get("ui", id: "companion") ?? CompanionState()
        queue = db.get("queue", id: "order") ?? []
        reload()
        importSeededTemplates()
        // Restore where the browsers were.
        if let p = companion.sourceBrowserPath { sourceBrowser.open(URL(fileURLWithPath: p), record: false) }
        if let p = companion.destinationBrowserPath { destBrowser.open(URL(fileURLWithPath: p), record: false) }
        let locs = { [weak self] in (self?.locations ?? []).map { URL(fileURLWithPath: $0.path) } }
        sourceBrowser.extraSearchRoots = locs; destBrowser.extraSearchRoots = locs
        markStaleRunningJobs()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let mounted = note.name == NSWorkspace.didMountNotification
                Task { @MainActor in self?.volumesChanged(); if mounted, let url { self?.driveMounted(url) } }
            })
        }
        refreshResolve()
    }

    func reload() {
        templateList = templates.all.sorted { ($0.favorite ? 0 : 1, $0.name.lowercased()) < ($1.favorite ? 0 : 1, $1.name.lowercased()) }
        sessions = projects.all.sorted { $0.created > $1.created }
        jobs = db.all("job", as: TransferJob.self).sorted { $0.created > $1.created }
        volumes = Volumes.mounted()
        locations = db.all("location", as: SavedLocation.self).sorted { $0.name < $1.name }
        recentPairs = db.get("recents", id: "pairs") ?? []
    }

    /// Template edits only: skips jobs, volumes and the rest, so typing and cover changes stay instant.
    func reloadTemplates() {
        templateList = templates.all.sorted { ($0.favorite ? 0 : 1, $0.name.lowercased()) < ($1.favorite ? 0 : 1, $1.name.lowercased()) }
    }

    private static let seedsDoneKey = "templates.seeds.imported"

    /// Templates bundled with this build are copied into the library on first run, once each.
    /// The remembered keys live in UserDefaults, so a template the user deletes stays deleted.
    func importSeededTemplates() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("templates", isDirectory: true) else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.seedsDoneKey) ?? [])
        let added = templates.importSeeds(from: dir, done: done)
        guard !added.isEmpty else { return }
        done.formUnion(added)
        UserDefaults.standard.set(Array(done).sorted(), forKey: Self.seedsDoneKey)
        reloadTemplates()
    }

    /// A drive used by the running job disappeared: stop it now and record why, instead of failing file by file.
    private func volumesChanged() {
        volumes = Volumes.mounted()
        for id in running {
            guard let j = jobs.first(where: { $0.id == id }) else { continue }
            for (label, v) in [("Source", j.sourceVolume), ("Destination", j.destinationVolume)] {
                if let v, Volumes.find(v) == nil {
                    stopReasons[id] = "\(label) drive \(v.name) [\(v.shortID)] was disconnected. Reconnect the same drive to resume; a different drive with the same name is refused."
                    cancelFlags[id] = true
                }
            }
        }
    }

    // MARK: Drive connection (menu bar spec p.4): suggest, never copy automatically

    private func driveMounted(_ url: URL) {
        // An installer .dmg opening is not a card being inserted: no panel, no notification.
        guard let v = Volumes.identity(of: url), !Volumes.isDiskImage(v.mountPath) else { return }
        let editorFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains("davinci") == true
        let busy = !running.isEmpty || !draftIsIdle
        let decision = DrivePolicy.decide(v, mode: settings.autoOpen ?? .open, trustedOnly: settings.trustedOnly ?? false,
                                          trusted: Set(settings.trustedDrives ?? []), editorInFront: editorFront, busy: busy)
        Log.info("drive mounted", ["name": v.name, "uuid": v.uuid ?? "none", "decision": "\(decision)"])
        switch decision {
        case .ignore: return
        case .askTrust:
            pendingTrust = v
            postNotification(id: "mount-\(v.uuid ?? v.name)", title: "\(v.name) connected", body: "Trust this drive to open Editor Workflow when it connects?", category: "drive")
        case .notify:
            lastMountedVolume = v
            postNotification(id: "mount-\(v.uuid ?? v.name)", title: "\(v.name) connected", body: "Open the menu bar panel to copy from it.", category: "drive")
        case .openPanel:
            lastMountedVolume = v
            // Never replace a copy that is running or a route the user is still choosing; just show the panel.
            if !busy { suggestSource(v) }
            showPanel(.transfer)
        }
    }

    /// Camera brand per mounted card, for the source tile ("GoPro card").
    @Published var cardBrands: [String: String] = [:]

    /// True when nothing is being set up: no chosen source, or the last copy already finished.
    var draftIsIdle: Bool {
        let d = companion.draft
        if !d.jobIDs.isEmpty { return d.jobIDs.allSatisfy { id in !running.contains(id) && !queue.contains(id) } }
        // A whole drive picked as source (e.g. an earlier card suggestion) is replaced by a newly inserted card.
        let mounts = Set(volumes.map(\.mountPath))
        return d.sources.isEmpty || (d.sources.count == 1 && mounts.contains(d.sources[0]))
    }

    /// A new card fills the whole route: the card as source, the last-used drive as destination, a dated folder name.
    /// Never starts copying. Work already being set up is not overwritten.
    func suggestSource(_ v: VolumeIdentity) {
        lastMountedVolume = v
        let root = URL(fileURLWithPath: v.mountPath)
        let brand = CameraCard.detect(root)
        cardBrands[v.mountPath] = brand
        guard draftIsIdle else { return }
        var d = TransferDraft(mode: brand != nil ? .cameraCardBackup : companion.draft.mode)
        d.sources = [root.path]
        d.outputName = CameraCard.folderName(volumeName: v.name, brand: brand)
        d.destinationParent = companion.draft.destinationParent ?? recentPairs.first?.destination
            ?? (settings.defaultDestination.isEmpty ? nil : settings.defaultDestination)
        d.stage = .review
        d.policy = settings.conflictPolicy
        companion.draft = d
        companion.handoff = nil
        companion.tab = .transfer
        sourceBrowser.open(root)
        Log.info("card suggested", ["name": v.name, "brand": brand ?? "none"])
    }

    /// At launch: a camera card that is already inserted is treated like a fresh insert.
    func checkCardsAtLaunch() -> Bool {
        // Prefer a recognised camera brand over a generic DCIM match, then the smallest volume (cards are small, backup drives big).
        let candidates = volumes.filter { !$0.isInternal }.compactMap { v -> (VolumeIdentity, String)? in
            CameraCard.detect(URL(fileURLWithPath: v.mountPath)).map { (v, $0) }
        }
        guard let v = candidates.sorted(by: { a, b in
            let ga = a.1 == "Camera", gb = b.1 == "Camera"
            return ga != gb ? !ga : a.0.capacity < b.0.capacity
        }).first?.0 else { return false }
        let decision = DrivePolicy.decide(v, mode: settings.autoOpen ?? .open, trustedOnly: settings.trustedOnly ?? false,
                                          trusted: Set(settings.trustedDrives ?? []), editorInFront: false, busy: !running.isEmpty)
        if decision == .openPanel { suggestSource(v); return true }
        if decision == .askTrust { pendingTrust = v }
        return false
    }

    func trust(_ v: VolumeIdentity, _ yes: Bool) {
        if yes, let u = v.uuid { settings.trustedDrives = Array(Set((settings.trustedDrives ?? []) + [u])); saveSettings(); suggestSource(v) }
        pendingTrust = nil
    }

    private func saveCompanionSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            var c = self.companion
            c.sourceBrowserPath = self.sourceBrowser.current?.path
            c.destinationBrowserPath = self.destBrowser.current?.path
            try? self.db.save("ui", id: "companion", c)
        }
    }
    func saveCompanionNow() {
        var c = companion
        c.sourceBrowserPath = sourceBrowser.current?.path
        c.destinationBrowserPath = destBrowser.current?.path
        try? db.save("ui", id: "companion", c)
    }

    private func rememberPair(_ job: TransferJob) {
        var r = recentPairs.filter { !($0.source == job.sourcePath && $0.destination == job.destinationRoot) }
        r.insert(RecentPair(source: job.sourcePath, destination: job.destinationRoot), at: 0)
        recentPairs = Array(r.prefix(8))
        try? db.save("recents", id: "pairs", recentPairs)
    }

    /// Re-plans the files a job did not finish onto another destination (e.g. after "destination full").
    func continueElsewhere(_ job: TransferJob) {
        guard let dir = AppModel.chooseFolder(prompt: "Continue Here") else { return }
        let remaining = runner.items(job.id).filter { !$0.state.isDone }
        guard !remaining.isEmpty else { errorMessage = "Nothing left to copy."; return }
        let runner = self.runner
        Task.detached {
            let plan = TransferPlanner.continuation(of: job, remaining: remaining, to: dir)
            await MainActor.run {
                if !plan.canStart { self.errorMessage = plan.issues.filter { $0.level == .block }.map(\.message).joined(separator: "\n"); return }
                var old = job
                old.status = .cancelled
                old.warnings.append("Continued on \(dir.path) as \"\(plan.job.name)\".")
                try? runner.db.save("job", id: old.id.uuidString, old)
                self.enqueue(plan)
            }
        }
    }

    /// Studio: new template from the project open in Resolve.
    func templateFromOpenResolveProject(then: @escaping (Template) -> Void) {
        let adapter = resolve, store = templates, tmp = paths.root
        Task.detached {
            let r = adapter.exportCurrent(to: tmp)
            await MainActor.run {
                switch r {
                case .failure(let e): self.errorMessage = e.description
                case .success(let c):
                    do {
                        let t = try store.importCurrent(c); self.reload(); self.autoCover(t.id); then(t)
                        // List the project's pictures, video and music as the template's assets right away.
                        self.scanDependencies(t.current) { found in
                            guard !found.isEmpty else { return }
                            _ = try? store.newVersion(of: t.id, note: "Media found in the Resolve project") { $0.assets = TemplateStore.merge(found, into: $0.assets) }
                            self.reloadTemplates()
                        }
                    } catch { self.report(error) }
                }
            }
        }
    }

    /// Studio: scan the master's media references through a temporary copy in Resolve.
    func scanDependencies(_ v: TemplateVersion, then: @escaping ([AssetRuleEntry]) -> Void) {
        let adapter = resolve
        Task.detached {
            let r = adapter.scanDependencies(v.masterPath)
            await MainActor.run {
                switch r {
                case .failure(let e): self.errorMessage = e.description
                case .success(let a): then(a)
                }
            }
        }
    }

    /// A job left "running" means the app quit or crashed mid-copy: record that honestly.
    private func markStaleRunningJobs() {
        for var j in jobs where j.status == .running {
            j.status = .interrupted
            j.warnings.append("The app closed while copying. Resume to continue; finished files are kept.")
            try? db.save("job", id: j.id.uuidString, j)
        }
        jobs = db.all("job", as: TransferJob.self).sorted { $0.created > $1.created }
    }

    func saveSettings() { try? db.save("settings", id: "app", settings) }

    func refreshResolve() {
        let adapter = resolve
        Task.detached { let s = adapter.status(); await MainActor.run { self.resolveStatus = s } }
    }

    func report(_ error: Error) {
        let id = Log.error(String(describing: error))
        errorMessage = "\(error) (Error ID \(id))"
    }

    /// Proves each automated capability on throwaway projects for the running Resolve version and stores the result.
    func runCapabilitySelfTest(done: @escaping (String) -> Void) {
        let adapter = resolve, db = self.db, tmp = paths.root
        let clip = Bundle.main.url(forResource: "probe_clip", withExtension: "mp4")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../Resources/probe_clip.mp4").standardizedFileURL
        Task.detached {
            let st = adapter.status()
            guard st.reachable, st.edition == .studio else { await MainActor.run { done("Needs Resolve Studio running with external scripting.") }; return }
            let r = adapter.selfTest(clip: clip, tmp: tmp)
            await MainActor.run {
                switch r {
                case .failure(let e): done("Self-test failed: \(e.description) (Error ID \(Log.error("selftest", ["detail": e.description])))")
                case .success(let caps):
                    let key = Capabilities.key(st.liveVersion)
                    try? db.save("capabilities", id: key, caps)
                    Log.info("capability self-test", ["version": key, "results": caps.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")])
                    done("Resolve \(key): \(caps.filter(\.value).count) of \(caps.count) capabilities proven.")
                    self.refreshResolve()
                }
            }
        }
    }

    func retryFailed(_ job: TransferJob) {
        do { let n = try runner.resetFailed(job); Log.info("retry failed files", ["job": job.id.uuidString, "count": String(n)]); reload(); resume(db.get("job", id: job.id.uuidString) ?? job) }
        catch { report(error) }
    }

    /// Copies logs, the app's own record counts and Resolve status into a folder the user chooses. No footage.
    func exportDiagnostics() {
        guard let dir = AppModel.chooseFolder(prompt: "Export Here") else { return }
        let out = dir.appendingPathComponent("Editor Workflow Diagnostics \(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for f in ["app.log", "app.1.log"] {
                let src = paths.logs.appendingPathComponent(f)
                if FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: out.appendingPathComponent(f)) }
            }
            let summary = [
                "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "resolve": "\(resolveStatus?.product ?? "?") \(resolveStatus?.liveVersion ?? resolveStatus?.installedVersion ?? "?")",
                "capabilities": resolveStatus?.capabilities.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ") ?? "",
                "templates": String(templateList.count), "projects": String(sessions.count), "transfers": String(jobs.count),
            ]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("summary.json"))
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch { report(error) }
    }

    // MARK: Locations

    func addLocation(_ url: URL) {
        let bm = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let loc = SavedLocation(name: url.lastPathComponent, path: url.path, bookmark: bm)
        try? db.save("location", id: loc.id.uuidString, loc)
        reload()
    }

    func removeLocation(_ loc: SavedLocation) { try? db.delete("location", id: loc.id.uuidString); reload() }

    /// Resolves a saved bookmark to the folder's current path (it may have moved or remounted elsewhere).
    func resolvedPath(_ loc: SavedLocation) -> String {
        guard let bm = loc.bookmark else { return loc.path }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bm, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            return url.path
        }
        return loc.path
    }

    static func chooseFolder(prompt: String, start: String? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.allowsMultipleSelection = false; p.prompt = prompt
        if let start { p.directoryURL = URL(fileURLWithPath: start) }
        return p.runModal() == .OK ? p.url : nil
    }

    // MARK: Transfers

    var activeJob: TransferJob? { jobs.first { running.contains($0.id) } }
    var activeJobs: [TransferJob] { jobs.filter { running.contains($0.id) } }
    var waitingJobs: [TransferJob] { queue.compactMap { id in jobs.first { $0.id == id } } }

    /// Queues a planned job. Refuses jobs that would write into, or alongside, another queued or running job.
    @discardableResult
    func enqueue(_ plan: TransferPlan) -> Bool {
        let others = jobs.filter { running.contains($0.id) || queue.contains($0.id) }
        if let clash = others.first(where: { TransferPlanner.overlaps($0, plan.job) }) {
            errorMessage = "This copy overlaps \"\(clash.name)\", which is queued or running (same destination folder or a path inside its source). Wait for it to finish or choose another destination."
            return false
        }
        do { try runner.saveNew(plan) } catch { report(error); return false }
        rememberPair(plan.job)
        queue.append(plan.job.id); persistQueue()
        reload()
        pump()
        return true
    }

    func resume(_ job: TransferJob) {
        if case .failure(let r) = runner.revalidate(job) { errorMessage = r.description; return }
        if !queue.contains(job.id) && !running.contains(job.id) { queue.append(job.id); persistQueue() }
        pump()
    }

    func pause(_ job: TransferJob) {
        cancelFlags[job.id] = true
        queue.removeAll { $0 == job.id }; persistQueue()
    }

    func cancel(_ job: TransferJob) {
        pause(job)
        if !running.contains(job.id), var j = jobs.first(where: { $0.id == job.id }) {
            j.status = .cancelled
            try? db.save("job", id: j.id.uuidString, j); reload()
        }
    }

    func moveInQueue(_ job: TransferJob, by delta: Int) {
        guard let i = queue.firstIndex(of: job.id) else { return }
        let j = max(0, min(queue.count - 1, i + delta))
        queue.remove(at: i); queue.insert(job.id, at: j); persistQueue()
    }
    func startNext(_ job: TransferJob) { guard let i = queue.firstIndex(of: job.id) else { return }; queue.remove(at: i); queue.insert(job.id, at: 0); persistQueue(); pump() }

    /// Opens the project's saved Resolve project when its name is known, so no second copy is imported.
    /// Falls back to the project's own `.drp` only when no Resolve project name was recorded.
    func openInResolve(_ s: ProjectSession) {
        if let name = s.resolveProjectName, !name.isEmpty {
            openNamedResolveProject(s, name: name)
            return
        }
        openProjectFile(s)
    }

    private func openNamedResolveProject(_ s: ProjectSession, name: String) {
        let adapter = resolve
        Task.detached {
            let first = adapter.openProject(named: name)
            if first.opened { return }
            if first.reachable {
                await MainActor.run { self.errorMessage = "Resolve does not have a project named \(name). Its folder copy is at \(s.instanceDrpPath ?? s.projectFolder)." }
                return
            }
            // Resolve is closed or still starting: launch it, then try the project name again.
            await MainActor.run { self.launchResolve() }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if adapter.openProject(named: name).opened { return }
            }
            await MainActor.run { self.errorMessage = "Resolve did not open \(name). Start Resolve, then open the project from its Project Manager." }
        }
    }

    /// Opens the project's own `.drp` copy. Used for guided/manual sessions, where no Resolve name exists.
    private func openProjectFile(_ s: ProjectSession) {
        let app = URL(fileURLWithPath: ResolveAdapter.appPath)
        guard FileManager.default.fileExists(atPath: app.path) else {
            errorMessage = "DaVinci Resolve was not found at \(app.path). Choose its location in Settings."
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let p = s.instanceDrpPath, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: app, configuration: cfg) { _, error in
                if let error { Task { @MainActor in self.errorMessage = "Resolve could not open \(URL(fileURLWithPath: p).lastPathComponent): \(error.localizedDescription)" } }
            }
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, error in
                if let error { Task { @MainActor in self.errorMessage = "Resolve could not start: \(error.localizedDescription)" } }
            }
        }
    }

    /// Re-reads the copies in the background and says plainly whether they still match the card.
    func recheck(_ ids: [UUID]) {
        let jobs = ids.compactMap { id in self.jobs.first { $0.id == id } }.filter { !rechecking.contains($0.id) }
        guard !jobs.isEmpty else { return }
        jobs.forEach { rechecking.insert($0.id) }
        let runner = self.runner
        Task.detached {
            var ok = 0, bad: [String] = []
            for j in jobs { let r = runner.recheck(j); ok += r.ok; bad += r.changed.map { "Changed: \($0)" } + r.missing.map { "Missing: \($0)" } }
            let okCount = ok, problems = bad
            await MainActor.run {
                jobs.forEach { self.rechecking.remove($0.id) }
                let a = NSAlert()
                if problems.isEmpty {
                    a.messageText = "All \(okCount) files match"
                    a.informativeText = "Every copy is still identical to the original."
                } else {
                    a.alertStyle = .warning
                    a.messageText = "\(problems.count) files don't match"
                    a.informativeText = problems.prefix(8).joined(separator: "\n") + (problems.count > 8 ? "\n…" : "") + "\n\nCopy them again from the original while you still have it."
                }
                a.runModal()
            }
        }
    }

    func removeHistory(_ job: TransferJob) {
        guard !running.contains(job.id) else { return }
        queue.removeAll { $0 == job.id }; persistQueue()
        do { try runner.deleteRecord(job); reload() } catch { report(error) }
    }

    private func persistQueue() { try? db.save("queue", id: "order", queue) }

    /// Starts queued jobs: at most `maxConcurrent` (default 4). Jobs may share a destination
    /// drive — `enqueue` already refuses jobs whose output folders overlap.
    func pump() {
        let limit = max(1, settings.maxConcurrent ?? 4)
        while running.count < limit, !queue.isEmpty {
            let id = queue.removeFirst(); persistQueue()
            guard let job = db.get("job", id: id.uuidString, as: TransferJob.self) else { continue }
            start(job)
        }
    }

    private func start(_ job: TransferJob) {
        let id = job.id
        running.insert(id)
        live[id] = LiveProgress()
        cancelFlags[id] = false
        let runner = self.runner, flags = cancelFlags
        work.async { [weak self] in
            var lastUI = Date.distantPast, lastAct = Date.distantPast
            let result = runner.run(job, progress: { j in
                guard Date().timeIntervalSince(lastUI) > 0.25 || j.status != .running else { return }
                lastUI = Date()
                Task { @MainActor in
                    self?.update(j)
                    if var l = self?.live[id] {
                        l.samples.append((Date(), j.copiedBytes)); l.samples.removeAll { Date().timeIntervalSince($0.0) > 5 }
                        self?.live[id] = l
                    }
                }
            }, isCancelled: { flags[id] }, activity: { file, phase in
                guard Date().timeIntervalSince(lastAct) > 0.1 || phase == "Verifying" else { return }
                lastAct = Date()
                Task { @MainActor in
                    guard let self, var l = self.live[id] else { return }
                    let now = Date()
                    l.recentFiles.append((now, file))
                    l.recentFiles.removeAll { now.timeIntervalSince($0.0) > 0.8 }
                    let active = Set(l.recentFiles.map(\.1))
                    l.phase = phase
                    l.currentFile = active.count > 1 ? "\(active.count) files at once" : file
                    self.live[id] = l
                }
            })
            Task { @MainActor in
                guard let self else { return }
                self.running.remove(id)
                self.live[id] = nil
                var result = result
                if result.status == .paused, let reason = self.stopReasons.removeValue(forKey: id) {
                    result.status = .interrupted
                    result.warnings.append(reason)
                    try? self.db.save("job", id: id.uuidString, result)
                }
                self.update(result)
                Log.event(result.status == .verified ? "info" : "warning", "transfer \(result.status.rawValue)", ["job": id.uuidString, "name": result.name, "bytes": String(result.copiedBytes)])
                self.jobFinished(result)
                self.pump()
            }
        }
    }

    /// After a draft's jobs end: remember the verified destination for the template handoff, then notify.
    private func jobFinished(_ j: TransferJob) {
        let draftJobs = companion.draft.jobIDs
        if draftJobs.contains(j.id) {
            let all = jobs.filter { draftJobs.contains($0.id) }
            if all.allSatisfy({ ![.planned, .running].contains($0.status) && !running.contains($0.id) }), all.allSatisfy({ $0.status == .verified }) {
                companion.lastVerifiedDestination = draftDestination?.path
            }
        }
        // A verified copy of the footage a New Project handoff points at becomes the source,
        // so the project uses the checked copy instead of the card.
        if var h = companion.handoff, h.resultSessionID == nil, h.mediaSource == j.sourcePath,
           j.status == .verified, !running.contains(j.id) {
            h.mediaSource = j.outputPath
            h.mappings = []
            companion.handoff = h
            saveCompanionSoon()
        }
        notify(j)
    }

    func openMainWindow() {
        // The app lives in the menu bar; it gets a Dock icon only while its main window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if mainWindow == nil {
            let host = NSHostingController(rootView: ContentView().environmentObject(self).frame(minWidth: 940, minHeight: 600))
            host.sizingOptions = []   // no content-driven window resizing (layout loop)
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 1040, height: 680))
            w.minSize = NSSize(width: 940, height: 600)
            w.title = "Editor Workflow"
            w.identifier = NSUserInterfaceItemIdentifier("main")
            w.styleMask.formUnion([.resizable, .miniaturizable, .closable, .titled])
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("EditorWorkflowMain")
            w.center()
            mainWindow = w
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Favorites in the user's manual order (new favorites go last).
    var orderedFavorites: [Template] {
        let favs = templateList.filter(\.favorite)
        let order = companion.favoritesOrder
        return favs.sorted { (order.firstIndex(of: $0.id) ?? Int.max, $0.name) < (order.firstIndex(of: $1.id) ?? Int.max, $1.name) }
    }
    func moveFavorite(_ t: Template, by delta: Int) {
        var ids = orderedFavorites.map(\.id)
        guard let i = ids.firstIndex(of: t.id) else { return }
        let j = max(0, min(ids.count - 1, i + delta))
        ids.remove(at: i); ids.insert(t.id, at: j)
        companion.favoritesOrder = ids
    }

    func chooseResolveApp() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let u = p.url else { return }
        settings.resolveAppPath = u.path; ResolveAdapter.appPath = u.path; saveSettings(); refreshResolve()
    }

    /// Where the draft copies to: <chosen folder>/<proposed folder name>. One folder per transfer, sources inside it.
    var draftDestination: URL? {
        guard let p = companion.draft.destinationParent else { return nil }
        let name = companion.draft.outputName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? URL(fileURLWithPath: p) : URL(fileURLWithPath: p).appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
    }

    /// Plans one job per selected source. A single folder becomes the destination folder itself (renamed to the proposed name);
    /// several sources or files are placed inside the proposed folder.
    func planDraft() -> [TransferPlan] { Self.plan(companion.draft, destination: draftDestination) }

    /// Off-main planning: scanning a big card must not freeze the panel.
    nonisolated static func plan(_ d: TransferDraft, destination: URL?) -> [TransferPlan] {
        guard let parent = d.destinationParent, let dest = destination else { return [] }
        let sources = TransferPlanner.normalizeSources(d.sources.map { URL(fileURLWithPath: $0) })
        var isDir: ObjCBool = false
        let singleFolder = sources.count == 1 && FileManager.default.fileExists(atPath: sources[0].path, isDirectory: &isDir) && isDir.boolValue
        return sources.map { src in
            let name = "\(src.lastPathComponent) → \(dest.lastPathComponent)"
            if singleFolder {
                return TransferPlanner.plan(name: name, source: src, destinationRoot: URL(fileURLWithPath: parent), mode: d.mode, filter: d.filter,
                                            policy: d.policy, verification: d.verification, outputName: dest.lastPathComponent, scope: d.scope ?? .all)
            }
            // Planned against the proposed folder; it is created only when the copy starts.
            return TransferPlanner.plan(name: name, source: src, destinationRoot: dest, mode: d.mode, filter: d.filter,
                                        policy: d.policy, verification: d.verification, allowMissingDestination: true, scope: d.scope ?? .all)
        }
    }

    /// Creates the proposed folder (if several sources), queues every plan, and remembers the job IDs for the completion card.
    func startDraft(_ plans: [TransferPlan]) {
        var ids: [UUID] = []
        for p in plans where enqueue(p) { ids.append(p.job.id) }
        companion.draft.jobIDs = ids
        if !ids.isEmpty { companion.handoff = nil }
    }

    /// Completion report for a set of jobs (spec p.10).
    func report(for ids: [UUID]) -> TransferReport {
        TransferReport.make(ids.compactMap { id in jobs.first { $0.id == id }.map { ($0, runner.items(id)) } })
    }

    func exportReport(_ ids: [UUID]) {
        guard let dir = AppModel.chooseFolder(prompt: "Save Report Here") else { return }
        let r = report(for: ids)
        let base = dir.appendingPathComponent("Transfer report \(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try r.text.write(to: base.appendingPathComponent("report.txt"), atomically: false, encoding: .utf8)
            for id in ids { for ext in ["json", "csv"] {
                let src = paths.manifests.appendingPathComponent("\(id.uuidString).\(ext)")
                if FileManager.default.fileExists(atPath: src.path) { try? FileManager.default.copyItem(at: src, to: base.appendingPathComponent("manifest-\(id.uuidString.prefix(8)).\(ext)")) }
            } }
            NSWorkspace.shared.activateFileViewerSelecting([base])
        } catch { report(error) }
    }

    private func update(_ j: TransferJob) {
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) }
    }

    private func notify(_ j: TransferJob) {
        guard settings.notifyOnFinish, j.status != .running else { return }
        postNotification(id: j.id.uuidString, title: "Transfer \(j.status.label)", body: "\(j.name): \(j.copiedBytes.bytesText) of \(j.totalBytes.bytesText)",
                         category: j.status == .verified ? "transferDone" : nil, info: ["destination": j.outputPath])
    }

    func postNotification(id: String, title: String, body: String, category: String?, info: [String: String] = [:]) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.userInfo = info
        if let category { c.categoryIdentifier = category }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) }
        }
    }

    // MARK: Projects

    func runResolveAutomation(for session: ProjectSession) {
        guard let t = templates.get(session.templateID), let v = t.version(session.templateVersion) else {
            var s = session
            s.receipts.append(ResolveReceipt(step: "Resolve automation", capability: "template", status: "failed",
                                             errorCode: "template_missing",
                                             detail: "The template or the version used by this project was removed. Import the project copy manually."))
            s.state = .manualStepRequired
            try? projects.save(s)
            errorMessage = "The template for \(session.name) was removed. The project folder still has its .drp copy; import it into Resolve manually."
            reload()
            return
        }
        let adapter = resolve, store = projects
        automating.insert(session.id)
        Task.detached {
            var status = adapter.status()
            var s = session
            s.resolveEdition = status.edition.rawValue
            if !status.installed {
                s.receipts.append(ResolveReceipt(step: "Resolve automation", capability: "edition", status: "manual",
                                                 detail: "DaVinci Resolve was not found. Install it, or choose its location in Settings, then use the import checklist."))
                s.state = .manualStepRequired
                try? store.save(s)
            } else {
                // Resolve closed: start it, then retry the bridge. Opening the .drp first would import a
                // second copy and leave the clips unlinked, so only the bridge opens the project.
                if !status.reachable {
                    await MainActor.run { self.launchResolve() }
                    for _ in 0..<90 {
                        if status.reachable { break }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        status = adapter.status()
                    }
                }
                s.resolveEdition = status.edition.rawValue
                if status.canAutomate {
                    let r = adapter.automate(s, version: v, allowed: status.capabilities.filter(\.value).map(\.key))
                    s.receipts += r.receipts
                    s.resolveProjectName = r.projectName ?? s.resolveProjectName
                    s.state = ProjectStore.state(from: s.receipts)
                    try? store.save(s)
                    Log.info("resolve automation", ["project": s.name, "state": s.state.rawValue])
                    let done = s
                    // A bridge timeout may mean Resolve is still importing. Opening the .drp now would
                    // make a second project, so leave it for an explicit retry.
                    let timedOut = r.receipts.contains { $0.capability == "bridge" && $0.errorCode == "timeout" }
                    if r.projectName == nil, !timedOut { await MainActor.run { self.openInResolve(done) } }
                } else {
                    s.receipts.append(ResolveReceipt(step: "Resolve automation", capability: "edition", status: "manual",
                                                     detail: "\(status.edition.label): \(status.message) Follow the import checklist."))
                    s.state = .manualStepRequired
                    try? store.save(s)
                    let done = s
                    await MainActor.run { self.openInResolve(done) }
                }
            }
            let finalStatus = status
            await MainActor.run { self.automating.remove(session.id); self.resolveStatus = finalStatus; self.reload() }
        }
    }

    /// Starts Resolve without a project file, so the bridge can import and link the clips itself.
    private func launchResolve() {
        let app = URL(fileURLWithPath: ResolveAdapter.appPath)
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, error in
            if let error { Log.error("Resolve launch failed", ["detail": error.localizedDescription]) }
        }
    }

    func markImportedManually(_ session: ProjectSession) {
        var s = session
        s.receipts.append(ResolveReceipt(step: "Manual import confirmed by editor", capability: "manual", status: "ok", detail: "Confirmed in app"))
        s.state = .ready
        try? projects.save(s); reload()
    }
}

extension Template {
    var thumbnail: NSImage? { thumbnailPath.flatMap { NSImage(contentsOfFile: $0) } }
}
