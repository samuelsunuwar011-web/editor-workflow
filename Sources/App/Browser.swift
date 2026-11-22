import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

/// Built-in Finder-like browser state, shared by the menu bar panel and the main window
/// (one instance for "Copy From", one for "Copy To").
@MainActor
final class BrowserModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable { case folder = "This folder", drive = "This drive", all = "All locations"; var id: String { rawValue } }

    struct Entry: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let isFolder: Bool
        let bytes: Int64?
        var name: String { url.lastPathComponent }
    }

    struct Summary: Equatable { var items = 0, files = 0, media = 0; var bytes: Int64 = 0; var complete = false }

    let allowFiles: Bool
    @Published private(set) var current: URL?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = false
    @Published var selection = Set<String>() { didSet { if selection != oldValue { summarize() } } }
    @Published var search = "" { didSet { if search != oldValue { scheduleSearch() } } }
    @Published var scope: Scope = .folder { didSet { if scope != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [FolderHit] = []
    @Published private(set) var searching = false
    @Published private(set) var summary: Summary?
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []
    /// Folders created in this session; only these can be renamed from the panel.
    @Published private(set) var createdHere: Set<String> = []

    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    var extraSearchRoots: () -> [URL] = { [] }

    init(allowFiles: Bool) { self.allowFiles = allowFiles }

    var canGoUp: Bool { current.map { $0.path != "/" && $0.path != Volumes.identity(of: $0)?.mountPath } ?? false }
    var volume: VolumeIdentity? { current.flatMap(Volumes.identity(of:)) }
    var isWritable: Bool { current.map { FileManager.default.isWritableFile(atPath: $0.path) && !(volume?.isReadOnly ?? false) } ?? false }
    var selectedURLs: [URL] { selection.sorted().map { URL(fileURLWithPath: $0) } }

    func open(_ url: URL, record: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        if record, let c = current, c != url { backStack.append(c); forwardStack.removeAll() }
        current = url
        search = ""
        selection = []
        load()
    }
    func goBack() {
        guard let u = backStack.popLast() else { return }
        if let c = current { forwardStack.append(c) }
        current = u; selection = []; load()
        // Back from a folder opened in search results returns to those results.
        if let o = searchOrigin, o.url == u { search = o.query; searchOrigin = nil }
    }
    /// Remembers where the search started so Back can return to the results.
    private var searchOrigin: (url: URL, query: String)?
    func openFromSearch(_ hit: FolderHit) {
        let origin = current.map { ($0, search) }
        if hit.isFolder { open(URL(fileURLWithPath: hit.path)) }
        else { open(URL(fileURLWithPath: hit.parentPath)); selection = [hit.path] }
        searchOrigin = origin.map { (url: $0.0, query: $0.1) }
    }
    /// Instant suggestions: names in the open folder, before the deeper search returns.
    var localMatches: [FolderHit] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let v = volume
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(50).map {
            FolderHit(path: $0.url.path, name: $0.name, volumeName: v?.name ?? "", volumeShortID: v?.shortID ?? "", isFolder: $0.isFolder)
        }
    }
    /// Local matches first, then deeper results, without duplicates.
    var suggestions: [FolderHit] {
        let local = localMatches
        let seen = Set(local.map(\.path))
        return local + results.filter { !seen.contains($0.path) }
    }
    func goForward() { guard let u = forwardStack.popLast() else { return }; if let c = current { backStack.append(c) }; current = u; selection = []; load() }
    func goUp() { guard canGoUp, let c = current else { return }; open(c.deletingLastPathComponent()) }
    /// "Select This Folder": the folder being viewed becomes the selection without leaving it.
    func selectCurrent() { if let c = current { selection = [c.path] } }

    func reload() { load() }

    /// Lists the folder in the background, appending in batches so huge folders never freeze the panel.
    private func load() {
        loadTask?.cancel()
        guard let dir = current else { entries = []; return }
        entries = []; loading = true
        let files = allowFiles
        loadTask = Task { [weak self] in
            let batches = AsyncStream<[Entry]> { cont in
                Task.detached { BrowserModel.list(dir, files: files) { cont.yield($0) }; cont.finish() }
            }
            for await b in batches {
                guard let self, !Task.isCancelled else { return }
                self.entries = (self.entries + b).sorted { a, b in
                    a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            self?.loading = false
        }
    }

    /// Directory listing in batches of 300 (synchronous; called off the main thread).
    nonisolated static func list(_ dir: URL, files: Bool, yield: ([Entry]) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        var batch: [Entry] = []
        while let u = e.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let folder = v?.isDirectory == true && v?.isPackage != true
            if !folder && !files { continue }
            batch.append(Entry(url: u, isFolder: folder, bytes: folder ? nil : Int64(v?.fileSize ?? 0)))
            if batch.count >= 300 { yield(batch); batch = [] }
        }
        yield(batch)
    }

    /// Debounced, cancellable search; each result keeps its parent path for context.
    private func scheduleSearch() {
        searchTask?.cancel()
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; searching = false; return }
        let roots: [URL]
        switch scope {
        case .folder: roots = current.map { [$0] } ?? []
        case .drive: roots = volume.map { [URL(fileURLWithPath: $0.mountPath)] } ?? []
        case .all: roots = Volumes.mounted().map { URL(fileURLWithPath: $0.mountPath) } + extraSearchRoots()
        }
        let files = allowFiles, depth = scope == .folder ? 6 : 5
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let hits = await Task.detached { FolderSearch.search(q, in: roots, limit: 200, maxDepth: depth, includeFiles: files, isCancelled: { Task.isCancelled }) }.value
            guard let self, !Task.isCancelled else { return }
            self.results = hits; self.searching = false
        }
    }
    func cancelSearch() { searchTask?.cancel(); searching = false }

    /// Size, file and media counts of the selection, computed in the background; marked incomplete until done.
    private func summarize() {
        summaryTask?.cancel()
        let urls = selectedURLs
        guard !urls.isEmpty else { summary = nil; return }
        summary = Summary(items: urls.count)
        summaryTask = Task { [weak self] in
            let stream = AsyncStream<Summary> { cont in
                Task.detached {
                    var s = Summary(items: urls.count)
                    var n = 0
                    for u in TransferPlanner.normalizeSources(urls) {
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                        let list: [URL] = isDir.boolValue ? ((FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])?.allObjects as? [URL]) ?? []) : [u]
                        for f in list {
                            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                            s.files += 1; s.bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                            if [.video, .raw, .audio, .photo].contains(MediaCategory.of(f)) { s.media += 1 }
                            n += 1; if n % 2000 == 0 { cont.yield(s) }
                        }
                    }
                    s.complete = true; cont.yield(s); cont.finish()
                }
            }
            for await s in stream { guard let self, !Task.isCancelled else { return }; self.summary = s }
        }
    }
    func cancelSummary() { summaryTask?.cancel(); if var s = summary { s.complete = false; summary = s } }

    @discardableResult
    func createFolder(_ name: String) -> URL? {
        guard let c = current, isWritable else { return nil }
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return nil }
        let u = TransferRunner.uniqueNameIfNeeded(c.appendingPathComponent(clean))
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false) } catch { return nil }
        createdHere.insert(u.path)
        load(); selection = [u.path]
        return u
    }

    /// Renames any file or folder the user picked. Never replaces an existing item.
    @discardableResult
    func renameItem(_ url: URL, to name: String) -> URL? {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != url.lastPathComponent else { return nil }
        let dst = url.deletingLastPathComponent().appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: dst.path) else { return nil }
        do { try FileManager.default.moveItem(at: url, to: dst) } catch { return nil }
        load(); selection = [dst.path]
        return dst
    }

    /// Moves items to the Trash (recoverable). Returns how many could not be moved.
    func trash(_ urls: [URL]) -> Int {
        var failed = 0
        for u in urls { do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) } catch { failed += 1 } }
        selection = []; load()
        return failed
    }

    /// Renames a folder this panel created (the proposed new folder), never existing user folders.
    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        guard createdHere.contains(url.path) else { return nil }
        let dst = TransferRunner.uniqueNameIfNeeded(url.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "/", with: "-")))
        do { try FileManager.default.moveItem(at: url, to: dst) } catch { return nil }
        createdHere.remove(url.path); createdHere.insert(dst.path)
        load(); selection = [dst.path]
        return dst
    }
}

/// The browser UI. `compact` is the menu bar layout; the main window uses the roomy one.
struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: BrowserModel
    let title: String
    var compact = false
    var forDestination = false
    var recent: [String] = []
    var onChoose: (([URL]) -> Void)? = nil
    @Local private var newFolderName = ""
    @Local private var showNewFolder = false
    @Local private var renaming: String?
    /// Path being previewed inline (video plays, photos and audio too); nil = no preview pane.
    @Local private var previewPath: String?

    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "mkv", "insv", "lrv"]
    static let photoExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "psd"]
    static let audioExts: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "bwf"]
    /// One selected file the preview pane can show.
    static func previewable(_ path: String) -> Bool {
        let e = URL(fileURLWithPath: path).pathExtension.lowercased()
        return videoExts.contains(e) || photoExts.contains(e) || audioExts.contains(e)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            locations
            navBar
            searchBar
            if !browser.search.isEmpty { searchResults } else { list }
            if let p = previewPath, FileManager.default.fileExists(atPath: p) {
                MediaPreview(url: URL(fileURLWithPath: p)) { previewPath = nil }
            }
            tray
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    if isDir.boolValue { browser.open(url) } else { browser.open(url.deletingLastPathComponent()) }
                    browser.selection = [url.path]
                }
            }
            return true
        }
    }

    // Drives, favorites and recent places with status.
    var locations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.volumes, id: \.mountPath) { v in
                    Button { browser.open(URL(fileURLWithPath: v.mountPath)) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Label(v.name, systemImage: v.isInternal ? "internaldrive" : (v.isLocal ? "externaldrive.fill" : "network")).lineLimit(1)
                            Text("\(v.available.bytesText) free\(v.isReadOnly ? " · read-only" : "")").font(.caption2).foregroundStyle(v.isReadOnly ? .orange : .secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(browser.volume?.mountPath == v.mountPath ? .accentColor : nil)
                    .accessibilityLabel("\(v.name), \(v.isInternal ? "internal" : "external") drive, \(v.available.bytesText) free\(v.isReadOnly ? ", read-only" : "")")
                }
                ForEach(model.locations) { l in
                    Button { browser.open(URL(fileURLWithPath: model.resolvedPath(l))) } label: { Label(l.name, systemImage: "heart") }.buttonStyle(.bordered)
                }
                if !recent.isEmpty {
                    Menu { ForEach(recent, id: \.self) { r in Button(r) { browser.open(URL(fileURLWithPath: r)) } } } label: { Label("Recent", systemImage: "clock") }
                        .fixedSize().accessibilityLabel("Recent locations")
                }
            }
        }
    }

    var navBar: some View {
        HStack(spacing: 4) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.left") }.disabled(browser.backStack.isEmpty).accessibilityLabel("Back")
            Button { browser.goForward() } label: { Image(systemName: "chevron.right") }.disabled(browser.forwardStack.isEmpty).accessibilityLabel("Forward")
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }.disabled(!browser.canGoUp).accessibilityLabel("Up one level")
            if let c = browser.current {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let comps = c.pathComponents
                        ForEach(comps.indices, id: \.self) { i in
                            Button(i == 0 ? (Volumes.identity(of: URL(fileURLWithPath: "/"))?.name ?? "/") : comps[i]) {
                                browser.open(URL(fileURLWithPath: NSString.path(withComponents: Array(comps[0...i]))))
                            }.buttonStyle(.link).lineLimit(1)
                            if i < comps.count - 1 { Image(systemName: "chevron.compact.right").foregroundStyle(.secondary).font(.caption2) }
                        }
                    }
                }
            } else {
                Text("Choose a drive above").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if browser.loading { ProgressView().controlSize(.mini) }
        }
        .buttonStyle(.borderless)
    }

    var searchBar: some View {
        HStack(spacing: 6) {
            TextField(browser.allowFiles ? "Search folders or files" : "Search folders", text: $browser.search)
                .textFieldStyle(.roundedBorder)
                .onExitCommand { browser.search = "" }
            if !browser.search.isEmpty {
                Picker("Scope", selection: $browser.scope) { ForEach(BrowserModel.Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize()
                if browser.searching { IconButton(symbol: "stop.circle", label: "Stop search", size: 12) { browser.cancelSearch() } }
            }
        }
    }

    var searchResults: some View {
        List {
            if browser.results.isEmpty && !browser.searching { Text("No matches").foregroundStyle(.secondary) }
            ForEach(browser.results) { h in
                Button {
                    if h.isFolder { browser.open(URL(fileURLWithPath: h.path)) } else { browser.open(URL(fileURLWithPath: h.parentPath)); browser.selection = [h.path] }
                } label: {
                    HStack {
                        Image(systemName: h.isFolder ? "folder" : "doc")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.name).lineLimit(1)
                            Text("\(h.volumeName) [\(h.volumeShortID)] · \(h.parentPath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: compact ? 150 : 220)
    }

    // Single click selects, double-click / Return opens; Cmd/Shift multi-select comes from the system list.
    var list: some View {
        List(selection: $browser.selection) {
            ForEach(browser.entries) { e in
                HStack {
                    Image(systemName: e.isFolder ? "folder.fill" : "doc").foregroundStyle(e.isFolder ? Color.accentColor : .secondary)
                    if renaming == e.id {
                        TextField("Name", text: $newFolderName, onCommit: { browser.rename(e.url, to: newFolderName); renaming = nil })
                    } else {
                        Text(e.name).lineLimit(1)
                    }
                    Spacer()
                    if let b = e.bytes { Text(b.bytesText).font(.caption).foregroundStyle(.secondary) }
                    if browser.createdHere.contains(e.id) && renaming != e.id {
                        IconButton(symbol: "pencil", label: "Rename new folder", size: 11) { newFolderName = e.name; renaming = e.id }
                    }
                }
                .tag(e.id)
                .accessibilityLabel("\(e.isFolder ? "Folder" : "File") \(e.name)")
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Open") { if let id = ids.first { browser.open(URL(fileURLWithPath: id)) } }.disabled(ids.count != 1)
            if ids.count == 1, let one = ids.first, Self.previewable(one) {
                Button("Preview") { previewPath = one }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) }) }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first {
                // Enter opens a folder, and plays a media file right here in the browser.
                if browser.entries.first(where: { $0.id == id })?.isFolder == true { browser.open(URL(fileURLWithPath: id)) }
                else if Self.previewable(id) { previewPath = id }
            }
        }
        .frame(minHeight: compact ? 150 : 220)
        .overlay { if browser.current == nil { Text("Pick a drive or favorite to start browsing.").foregroundStyle(.secondary) } }
    }

    // Selection tray: what will be used, its size, and the explicit choose actions.
    var tray: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !browser.selection.isEmpty {
                HStack {
                    Text(browser.selection.count == 1 ? URL(fileURLWithPath: browser.selection.first!).lastPathComponent : "\(browser.selection.count) items selected").bold().lineLimit(1)
                    if browser.selection.count == 1, let one = browser.selection.first, Self.previewable(one) {
                        IconButton(symbol: "play.circle", label: "Preview \(URL(fileURLWithPath: one).lastPathComponent)", size: 13) {
                            previewPath = one
                        }
                    }
                    if let s = browser.summary {
                        Text("\(s.bytes.bytesText) · \(s.files) files · \(s.media) media\(s.complete ? "" : " (counting…)")").font(.caption).foregroundStyle(.secondary)
                        if !s.complete { IconButton(symbol: "stop.circle", label: "Stop counting", size: 11) { browser.cancelSummary() } }
                    }
                    Spacer()
                    IconButton(symbol: "xmark.circle", label: "Clear selection", size: 12) { browser.selection = [] }
                }
                if browser.selection.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(browser.selection.sorted(), id: \.self) { p in
                            HStack(spacing: 2) { Text(URL(fileURLWithPath: p).lastPathComponent).lineLimit(1)
                                Button { browser.selection.remove(p) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel("Remove \(URL(fileURLWithPath: p).lastPathComponent)") }
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                        } }
                    }
                }
            }
            HStack {
                IconButton(symbol: "checkmark.circle", label: "Select this folder (the one you are in)") { browser.selectCurrent() }.disabled(browser.current == nil)
                if forDestination {
                    if showNewFolder {
                        TextField("New folder name", text: $newFolderName, onCommit: { browser.createFolder(newFolderName); showNewFolder = false; newFolderName = "" })
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        IconButton(symbol: "xmark", label: "Cancel new folder", size: 11) { showNewFolder = false }
                    } else {
                        IconButton(symbol: "folder.badge.plus", label: "New folder") { newFolderName = ""; showNewFolder = true }.disabled(!browser.isWritable)
                    }
                    if browser.current != nil {
                        Image(systemName: browser.isWritable ? "pencil.circle" : "lock.fill").font(.caption)
                            .foregroundStyle(browser.isWritable ? Theme.verified : Theme.attention)
                            .help(browser.isWritable ? "You can copy here" : "Read-only: cannot copy here")
                            .accessibilityLabel(browser.isWritable ? "Writable" : "Read-only")
                    }
                }
                Spacer()
                if let onChoose {
                    Button { onChoose(browser.selectedURLs) } label: { Label(forDestination ? "Copy here" : "Use", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .disabled(browser.selection.isEmpty || (forDestination && (browser.selection.count != 1 || !FileManager.default.isWritableFile(atPath: browser.selection.first ?? ""))))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// One end of the route (menu bar panel and Transfers page): drives, search, folder list, and what is chosen.
/// Double-click or Return enters a folder; a click selects it.
struct InlineBrowser: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: BrowserModel
    let label: String
    let symbol: String
    var forDestination = false
    var listHeight: CGFloat = 116
    /// What this end currently means for the copy, in words ("Copying: Video", "Into: clint / GoPro").
    var status: (icon: String, text: String, ok: Bool)? = nil
    /// Name being typed for a new folder; nil when not creating one. Inline, so the panel never closes for a dialog.
    @Local private var newName: String?
    /// Set while renaming: the item's path (the inline row then renames instead of creating).
    @Local private var renaming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title and search on one line: the search box is where you look first, and always ready to type in.
            HStack(spacing: 10) {
                Label(label, systemImage: symbol).font(.headline).fixedSize()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(forDestination ? "Search folders" : "Search", text: $browser.search).textFieldStyle(.plain)
                    if browser.searching || browser.loading { ProgressView().controlSize(.mini) }
                    if !browser.search.isEmpty {
                        Button { browser.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search").accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            // Drives only; saved folders sit in one menu so the row never overflows.
            HStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) { ForEach(orderedVolumes, id: \.mountPath) { v in chip(v) } }
                }
                if !model.locations.isEmpty || browser.current != nil {
                    Menu {
                        Button { if let c = browser.current { model.addLocation(c) } } label: { Label("Save This Folder", systemImage: "heart") }
                            .disabled(browser.current == nil || model.locations.contains { $0.name == browser.current?.lastPathComponent })
                        if !model.locations.isEmpty {
                            Divider()
                            ForEach(model.locations) { l in Button(l.name) { browser.open(URL(fileURLWithPath: model.resolvedPath(l))) } }
                            Divider()
                            Menu("Remove Saved Folder") { ForEach(model.locations) { l in Button(l.name) { model.removeLocation(l) } } }
                        }
                    } label: { Image(systemName: "heart") }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                        .help("Saved folders: save this one, or jump to a saved one")
                        .accessibilityLabel("Saved folders")
                }
            }
            HStack(spacing: 2) {
                IconButton(symbol: "chevron.left", label: "Back", size: 11) { browser.goBack() }.disabled(browser.backStack.isEmpty)
                IconButton(symbol: "chevron.right", label: "Forward", size: 11) { browser.goForward() }.disabled(browser.forwardStack.isEmpty)
                IconButton(symbol: "arrow.up", label: "Up one level", size: 11) { browser.goUp() }.disabled(!browser.canGoUp)
                crumbBar
                Spacer(minLength: 4)
                if forDestination {
                    Button { newName = "untitled folder" } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        .buttonStyle(.borderless).font(.caption).disabled(!browser.isWritable)
                        .help(browser.isWritable ? "Make a folder here" : "This place is read-only")
                }
            }
            if let name = newName {
                HStack(spacing: 6) {
                    Image(systemName: renaming == nil ? "folder.badge.plus" : "pencil").foregroundStyle(Color.accentColor)
                    TextField(renaming == nil ? "Folder name" : "New name", text: Binding(get: { name }, set: { newName = $0 }))
                        .textFieldStyle(.roundedBorder).onSubmit(createFolder)
                    Button(renaming == nil ? "Create" : "Rename", action: createFolder).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { newName = nil; renaming = nil }.keyboardShortcut(.cancelAction)
                }
            }
            Group {
                if !browser.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    let hits = browser.suggestions.filter { forDestination ? $0.isFolder : true }
                    List(hits) { h in
                        Button { browser.openFromSearch(h) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: h.isFolder ? "folder.fill" : Self.fileIcon(URL(fileURLWithPath: h.path)))
                                    .foregroundStyle(h.isFolder ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.name).lineLimit(1)
                                    Text(URL(fileURLWithPath: h.parentPath).lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(h.path)
                    }
                    .overlay {
                        if hits.isEmpty && !browser.searching { Text("No matches").foregroundStyle(.secondary) }
                    }
                } else {
                    List(selection: $browser.selection) {
                        ForEach(browser.entries) { e in
                            let on = browser.selection.contains(e.id)
                            HStack(spacing: 8) {
                                Image(systemName: e.isFolder ? "folder.fill" : Self.fileIcon(e.url))
                                    .foregroundStyle(e.isFolder ? Color.accentColor : .secondary).frame(width: 18)
                                Text(e.name).lineLimit(1)
                                Spacer()
                                if let b = e.bytes { Text(b.bytesText).font(.caption2).foregroundStyle(.secondary) }
                                if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).accessibilityHidden(true) }
                            }
                            .tag(e.id)
                            .help(e.isFolder ? "Click to choose · double-click to open" : "Click to choose")
                            .accessibilityLabel("\(e.isFolder ? "Folder" : "File") \(e.name)\(on ? ", selected" : "")")
                        }
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if !ids.isEmpty {
                            let urls = ids.sorted().map { URL(fileURLWithPath: $0) }
                            let one = urls.count == 1 ? urls[0] : nil
                            Button("Open") { if let u = one { openItem(u) } }.disabled(one == nil)
                            if let u = one, u.pathExtension.lowercased() == "drp" {
                                Button("Open in DaVinci Resolve") {
                                    NSWorkspace.shared.open([u], withApplicationAt: URL(fileURLWithPath: ResolveAdapter.appPath), configuration: .init())
                                }
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
                            Divider()
                            Button("Rename…") { if let u = one { renaming = u.path; newName = u.lastPathComponent } }.disabled(one == nil || !browser.isWritable)
                            Button("Move to Trash…", role: .destructive) { trash(urls) }.disabled(!browser.isWritable)
                            Divider()
                        }
                        Button("New Folder") { renaming = nil; newName = "untitled folder" }.disabled(!browser.isWritable)
                    } primaryAction: { ids in
                        if ids.count == 1, let id = ids.first, browser.entries.first(where: { $0.id == id })?.isFolder == true { browser.open(URL(fileURLWithPath: id)) }
                    }
                    .overlay { if browser.entries.isEmpty && !browser.loading { Text(browser.current == nil ? "Pick a drive above" : "Empty folder").foregroundStyle(.secondary) } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: listHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let st = status {
                Label(st.text, systemImage: st.icon)
                    .font(.callout.weight(st.ok ? .semibold : .regular))
                    .foregroundStyle(st.ok ? Theme.verified : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    browser.open(isDir.boolValue ? url : url.deletingLastPathComponent())
                    if !isDir.boolValue { browser.selection = [url.path] }
                }
            }
            return true
        }
    }

    /// Clickable path: the last three folders, "…" jumps one level above them.
    var crumbBar: some View {
        let all = crumbs, shown = Array(all.suffix(3))
        return HStack(spacing: 3) {
            if all.count > 3 {
                Button("…") { browser.open(all[all.count - 4].url) }.buttonStyle(.plain).foregroundStyle(.secondary).help(all[all.count - 4].url.path)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                if i > 0 || all.count > 3 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                Button(c.name) { browser.open(c.url) }
                    .buttonStyle(.plain).lineLimit(1)
                    .foregroundStyle(i == shown.count - 1 ? .primary : .secondary)
                    .help("Go to \(c.url.path)")
            }
        }
        .font(.caption)
    }

    var crumbs: [(name: String, url: URL)] {
        guard let c = browser.current else { return [] }
        let root = browser.volume.map { URL(fileURLWithPath: $0.mountPath) } ?? URL(fileURLWithPath: "/")
        var out: [(name: String, url: URL)] = []
        var u = c
        while true {
            let atRoot = u.path == root.path || u.path == "/"
            out.insert((atRoot ? (browser.volume?.name ?? "/") : u.lastPathComponent, u), at: 0)
            if atRoot || out.count > 40 { break }
            u = u.deletingLastPathComponent()
        }
        return out
    }

    static func fileIcon(_ u: URL) -> String {
        switch MediaCategory.of(u) {
        case .video, .raw: return "film"
        case .photo: return "photo"
        case .audio: return "waveform"
        default: return "doc"
        }
    }

    /// Creates the folder where you are and chooses it.
    func createFolder() {
        guard let name = newName, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let path = renaming {
            if browser.renameItem(URL(fileURLWithPath: path), to: name) == nil { model.errorMessage = "Could not rename: an item called \"\(name)\" may already be there." }
        } else if browser.createFolder(name) == nil { model.errorMessage = "The folder could not be created here." }
        newName = nil; renaming = nil
    }

    func openItem(_ u: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        if isDir.boolValue { browser.open(u) } else { NSWorkspace.shared.open(u) }
    }

    /// Asks first (the panel stays open behind the question), then moves to the Trash, which can be undone in Finder.
    func trash(_ urls: [URL]) {
        let busy = model.jobs.contains { j in model.running.contains(j.id) && urls.contains { u in j.sourcePath.hasPrefix(u.path) || u.path.hasPrefix(j.sourcePath) || j.outputPath.hasPrefix(u.path) } }
        guard !busy else { model.errorMessage = "That is being copied right now. Wait for the copy to finish."; return }
        let a = NSAlert()
        a.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
        a.informativeText = "You can put it back from the Trash in Finder."
        a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
        model.keepPanelOpen = true
        defer { model.keepPanelOpen = false }
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let failed = browser.trash(urls)
        if failed > 0 { model.errorMessage = "\(failed) item(s) could not be moved to the Trash (read-only or in use)." }
    }

    /// External drives first (cards are what editors copy from), then internal.
    var orderedVolumes: [VolumeIdentity] {
        model.volumes.sorted { a, b in a.isInternal != b.isInternal ? !a.isInternal : a.name < b.name }
    }

    var crumb: String {
        guard let c = browser.current else { return "" }
        let vol = browser.volume
        let rel = vol.map { c.path.hasPrefix($0.mountPath) ? String(c.path.dropFirst($0.mountPath.count)) : c.path } ?? c.path
        return ([vol?.name ?? ""] + rel.split(separator: "/").map(String.init)).filter { !$0.isEmpty }.joined(separator: " › ")
    }

    func chip(_ v: VolumeIdentity) -> some View {
        let on = browser.volume?.mountPath == v.mountPath
        let brand = model.cardBrands[v.mountPath]
        return Button { browser.open(URL(fileURLWithPath: v.mountPath)) } label: {
            HStack(spacing: 4) {
                Image(systemName: brand != nil ? "sdcard.fill" : (v.isInternal ? "internaldrive" : "externaldrive.fill")).font(.caption)
                Text(brand ?? v.name).font(.caption.weight(on ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 110)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(on ? Theme.accent.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(on ? Theme.accent : .primary)
        }
        .buttonStyle(.plain)
        .help("\(v.name) · \(v.available.bytesText) free\(v.isReadOnly ? " · read-only" : "")")
        .accessibilityLabel("\(brand.map { "\($0) card" } ?? v.name), \(v.available.bytesText) free")
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

/// Inline preview for one media file: video and audio play with the system controls, photos fit the pane.
/// The player is owned by the view: closing the pane stops playback.
struct MediaPreview: View {
    let url: URL
    let onClose: () -> Void

    private var kind: String {
        let e = url.pathExtension.lowercased()
        if BrowserView.videoExts.contains(e) { return "video" }
        if BrowserView.audioExts.contains(e) { return "audio" }
        return "photo"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: kind == "video" ? "film" : (kind == "audio" ? "waveform" : "photo"))
                    .foregroundStyle(Theme.accent).font(.caption)
                Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Close preview").help("Close preview")
            }
            switch kind {
            case "photo":
                photo
            default:
                // One player for video and audio: controls, scrubbing and fullscreen come from AVKit.
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 190)
                    .background(Color.black.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Player for \(url.lastPathComponent)")
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    var photo: some View {
        Group {
            if let img = NSImage(contentsOfFile: url.path) {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Label("Can't display this image", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .frame(maxHeight: 220)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
    }
}
