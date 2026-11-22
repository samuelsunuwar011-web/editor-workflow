import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Scratchpad (modeled on Vorssaint's Scratchpad + Shelf, GPL-3.0):
// up to 12 named notes in a dropdown, autosaved to JSON, plus a shelf of dragged-in
// files/photos with thumbnails. Opens as a floating panel that joins all spaces.

struct ScratchpadPad: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String = ""
    var modified = Date()
}

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var name: String
}

struct ScratchpadDocument: Codable {
    var pads: [ScratchpadPad] = []
    var selectedID: UUID?
    var shelf: [ShelfItem] = []
}

@MainActor
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()
    @Published var doc = ScratchpadDocument()
    @Published var saveState: String = "Saved"   // Saved / Saving… / Save failed — retrying
    private var generation = 0
    private var saveFailed = false

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EditorWorkflow")
        return base.appendingPathComponent("Scratchpad.json")
    }

    private init() { load() }

    func load() {
        if let d = try? Data(contentsOf: Self.fileURL), let doc = try? JSONDecoder().decode(ScratchpadDocument.self, from: d) {
            self.doc = doc
        }
        if doc.pads.isEmpty {
            doc.pads = [ScratchpadPad(name: "Scratchpad 1")]
            doc.selectedID = doc.pads[0].id
        }
        if doc.selectedID == nil || !doc.pads.contains(where: { $0.id == doc.selectedID }) {
            doc.selectedID = doc.pads.first?.id
        }
    }

    var selected: ScratchpadPad? { doc.pads.first { $0.id == doc.selectedID } }

    // MARK: Pad operations (max 12)

    var canAdd: Bool { doc.pads.count < 12 }

    func addPad() {
        guard canAdd else { return }
        // "Scratchpad 1" ... "Scratchpad 12": first unused number.
        let used = Set(doc.pads.map(\.name))
        var name = "Scratchpad \(doc.pads.count + 1)"
        for n in 1...12 where used.contains("Scratchpad \(n)") == false { name = "Scratchpad \(n)"; break }
        let pad = ScratchpadPad(name: name)
        doc.pads.append(pad)
        doc.selectedID = pad.id
        scheduleSave()
    }

    func closePad(_ id: UUID) {
        guard doc.pads.count > 1, let i = doc.pads.firstIndex(where: { $0.id == id }) else { return }
        if !doc.pads[i].text.isEmpty {
            let a = NSAlert()
            a.messageText = "Close \"\(doc.pads[i].name)\"?"
            a.informativeText = "This note has text. Closing removes it from the scratchpad (export first to keep it)."
            a.addButton(withTitle: "Close Note")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        doc.pads.remove(at: i)
        if doc.selectedID == id { doc.selectedID = doc.pads.first?.id }
        scheduleSave()
    }

    func renameSelected(to name: String) {
        let trimmed = String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = doc.selectedID, let i = doc.pads.firstIndex(where: { $0.id == id }) else { return }
        doc.pads[i].name = trimmed
        scheduleSave()
    }

    func clearSelected() {
        guard let id = doc.selectedID, let i = doc.pads.firstIndex(where: { $0.id == id }), !doc.pads[i].text.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Clear \"\(doc.pads[i].name)\"?"
        a.informativeText = "All text in this note will be removed."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        doc.pads[i].text = ""
        doc.pads[i].modified = Date()
        scheduleSave()
    }

    func setText(_ text: String) {
        guard let id = doc.selectedID, let i = doc.pads.firstIndex(where: { $0.id == id }), doc.pads[i].text != text else { return }
        doc.pads[i].text = text
        doc.pads[i].modified = Date()
        scheduleSave()
    }

    func exportSelected() {
        guard let pad = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Scratchpad \(ISO8601DateFormatter().string(from: Date()).prefix(10)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pad.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { saveState = "Save failed — retrying"; saveFailed = true }
    }

    // MARK: Shelf

    func addShelf(urls: [URL]) {
        for u in urls where !doc.shelf.contains(where: { $0.path == u.path }) {
            doc.shelf.append(ShelfItem(path: u.path, name: u.lastPathComponent))
        }
        scheduleSave()
    }

    func removeShelf(_ id: UUID) {
        doc.shelf.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Debounced autosave (0.8 s), verified by the write itself

    func scheduleSave() {
        generation += 1
        let gen = generation
        saveState = "Saving…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            try enc.encode(doc).write(to: Self.fileURL, options: .atomic)
            saveState = "Saved"; saveFailed = false
        } catch {
            saveState = "Save failed — retrying"; saveFailed = true
        }
    }
}

// MARK: Shelf tab — the photo/file shelf, with smart drop routing

/// Top-level Shelf tab. Photos drop straight onto the shelf as thumbnails;
/// a .drp routes to Add Template (it becomes a template), a folder or footage
/// file routes to New Project with that media preselected.
struct ShelfPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = ScratchpadStore.shared
    @Local private var dropTargeted = false
    @Local private var confirmRemove: ShelfItem?

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "ico", "avif"]
    private static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts", "insv"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Shelf", systemImage: "photo.on.rectangle").font(.headline)
                Text("\(store.doc.shelf.count) item(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Drop photos here · .drp makes a template · footage starts a project")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if store.doc.shelf.isEmpty {
                empty
            } else {
                grid
            }
        }
        .padding(.vertical, 4)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let lock = NSLock()
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { route(urls) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(Theme.accent)
                    .padding(4)
            }
        }
    }

    /// Photos → shelf. One .drp or one footage item → its own page. Never silently multi-route.
    private func route(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let images = urls.filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
        let rest = urls.filter { !Self.imageExts.contains($0.pathExtension.lowercased()) }
        if !images.isEmpty { store.addShelf(urls: images) }
        if rest.isEmpty { return }
        if rest.count == 1 { model.handleDropped(rest) }
        else { model.errorMessage = "Drop one .drp or one footage folder at a time — photos all go to the Shelf." }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Drop anything here").font(.callout.weight(.medium))
            Text("Photos and images become thumbnails on this shelf.\nA .drp becomes a template. A folder or video opens New Project with that footage.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(dropTargeted ? Theme.accent.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 10)], spacing: 10) {
                ForEach(store.doc.shelf) { item in
                    ShelfCard(item: item) {
                        confirmRemove = item
                    }
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 360)
        .confirmationDialog("Remove \"\(confirmRemove?.name ?? "")\" from the shelf?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove from Shelf", role: .destructive) {
                if let i = confirmRemove { store.removeShelf(i.id) }
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: {
            Text("The file itself is not deleted.")
        }
    }
}

/// One shelf card: thumbnail, name, remove button.
struct ShelfCard: View {
    @EnvironmentObject var model: AppModel
    let item: ShelfItem
    let onRemove: () -> Void

    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts", "insv"]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "ico", "avif"]

    var body: some View {
        let url = URL(fileURLWithPath: item.path)
        let ext = url.pathExtension.lowercased()
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumb(ext: ext, url: url)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove \(item.name) from shelf")
            }
            Text(item.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Start Project with This") { model.handleDropped([url]) }
            Divider()
            Button("Remove from Shelf", role: .destructive, action: onRemove)
        }
        .help("\(item.name) — drop photos to add, right click for actions")
    }

    @ViewBuilder private func thumb(ext: String, url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: item.path)
        Group {
            if !exists {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                    Image(systemName: "questionmark").foregroundStyle(.secondary)
                }
                .frame(height: 72)
            } else if Self.imageExts.contains(ext), let img = NSImage(contentsOfFile: item.path) {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(height: 72).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if Self.videoExts.contains(ext) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.black)
                    VStack(spacing: 3) {
                        Image(systemName: "play.circle.fill").foregroundStyle(.white).font(.title2)
                        Text(ext.uppercased()).font(.caption2).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(height: 72)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                    VStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 36, height: 36)
                        Text(ext.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 72)
            }
        }
        .opacity(exists ? 1 : 0.5)
    }
}

// MARK: Notes tab

/// The scratchpad as a panel tab (the ⋯ menu still opens it as its own window too).
struct ScratchpadPage: View {
    var body: some View {
        ScratchpadView()
    }
}

// MARK: Controller

@MainActor
final class ScratchpadController: NSObject {
    static let shared = ScratchpadController()
    private var window: NSWindow?

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if window == nil {
            let host = NSHostingController(rootView: ScratchpadView())
            let w = NSWindow(contentViewController: host)
            w.title = "Scratchpad"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 420, height: 360))
            w.minSize = NSSize(width: 380, height: 280)
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.setFrameAutosaveName("ScratchpadWindow")
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: UI

struct ScratchpadView: View {
    @ObservedObject private var store = ScratchpadStore.shared
    @Local private var renaming = false
    @Local private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            editor
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 280)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(store.doc.pads) { pad in
                    Button {
                        store.doc.selectedID = pad.id
                    } label: {
                        if pad.id == store.doc.selectedID {
                            Label(pad.name, systemImage: "checkmark")
                        } else { Text(pad.name) }
                    }
                }
                Divider()
                Button("New Note") { store.addPad() }.disabled(!store.canAdd)
                    .help(store.canAdd ? "Add a note (up to 12)" : "12 notes maximum")
            } label: {
                HStack(spacing: 3) {
                    Text(store.selected?.name ?? "Scratchpad")
                        .lineLimit(1).font(.callout.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Notes dropdown, \(store.doc.pads.count) of 12")

            if renaming {
                TextField("Name", text: $newName, onCommit: {
                    store.renameSelected(to: newName); renaming = false
                })
                .textFieldStyle(.roundedBorder).frame(width: 140)
                .onExitCommand { renaming = false }
            }
            Spacer()
            Button { store.addPad() } label: { Image(systemName: "plus") }
                .disabled(!store.canAdd).help("New note").accessibilityLabel("New note")
            Button {
                newName = store.selected?.name ?? ""; renaming = true
            } label: { Image(systemName: "pencil") }.help("Rename note").accessibilityLabel("Rename note")
            Button { store.clearSelected() } label: { Image(systemName: "trash") }
                .help("Clear note").accessibilityLabel("Clear note")
            Button {
                if let id = store.doc.selectedID { store.closePad(id) }
            } label: { Image(systemName: "xmark") }
                .disabled(store.doc.pads.count <= 1)
                .help("Close note").accessibilityLabel("Close note")
            Button { store.exportSelected() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Save note as a .txt file").accessibilityLabel("Export note as text file")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: binding)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
            if (store.selected?.text.isEmpty) ?? true {
                Text("Type a note…").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var binding: Binding<String> {
        Binding(get: { store.selected?.text ?? "" }, set: { store.setText($0) })
    }

    // MARK: Footer — pad count and save state (files/photos live on the Shelf tab)

    private var footer: some View {
        HStack {
            Text("\(store.doc.pads.count) / 12 notes").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(store.saveState)
                .font(.caption2)
                .foregroundStyle(store.saveState == "Saved" ? .secondary : (store.saveState.hasPrefix("Save failed") ? Color.red : .orange))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

