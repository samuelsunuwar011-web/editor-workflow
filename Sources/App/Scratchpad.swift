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
            shelf
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

    // MARK: Shelf of dragged-in files and photos

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    private static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf"]

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Shelf", systemImage: "photo.on.rectangle").font(.caption).foregroundStyle(.secondary)
                Text("drop files or photos here").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("\(store.doc.pads.count) / 12 notes · \(store.saveState)")
                    .font(.caption2)
                    .foregroundStyle(store.saveState == "Saved" ? .secondary : (store.saveState.hasPrefix("Save failed") ? Color.red : .orange))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if store.doc.shelf.isEmpty {
                        Text("Files you drop appear here as thumbnails.").font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(store.doc.shelf) { item in
                        ShelfTile(item: item) {
                            store.removeShelf(item.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 86)
        }
        .padding(8)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var got = 0
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    got += 1
                    Task { @MainActor in
                        store.addShelf(urls: [url])
                    }
                }
            }
            return true
        }
    }
}

/// One shelf tile: image thumbnail, video frame-less film tile, or the system file icon.
struct ShelfTile: View {
    let item: ShelfItem
    let onRemove: () -> Void

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    private static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf"]

    var body: some View {
        VStack(spacing: 3) {
            thumb
            Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 64)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Divider()
            Button("Remove from Shelf", role: .destructive) { onRemove() }
        }
        .help("\(item.name) — right click to open or remove")
    }

    @ViewBuilder private var thumb: some View {
        let url = URL(fileURLWithPath: item.path)
        let ext = url.pathExtension.lowercased()
        let exists = FileManager.default.fileExists(atPath: item.path)
        Group {
            if !exists {
                Image(systemName: "questionmark").frame(width: 56, height: 56)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.secondary)
            } else if Self.imageExts.contains(ext), let img = NSImage(contentsOfFile: item.path) {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if Self.videoExts.contains(ext) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                    Image(systemName: "film").foregroundStyle(.white).font(.title3)
                }
                .frame(width: 56, height: 56)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable().frame(width: 48, height: 48)
            }
        }
        .opacity(exists ? 1 : 0.5)
    }
}
