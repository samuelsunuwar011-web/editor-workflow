import SwiftUI
import AppKit
import Combine
import Darwin

/// "Background Activity": a Force Quit / Activity Monitor lite window.
/// The host app opens it with `ProcessMonitorController.shared.open()` (main thread).
/// Self-contained: no AppModel, no environment objects, nothing else in the app needs to change.

// MARK: - Model

/// One line of `ps`. Identity is the pid, so rows merge across refreshes instead of reordering wholesale.
struct ProcessMonitorRow: Identifiable {
    let pid: Int32
    let ppid: Int32
    /// As reported by ps (a decayed lifetime average, already in percent) — no cross-refresh math.
    let cpu: Double
    /// Resident set size in kilobytes, as ps reports it.
    let rssKB: Int64
    /// Trailing `comm` field: a path when ps knows one, a bare name when it does not.
    let command: String
    /// Our own bundle's executables, so the user can spot what this app costs.
    let isOwnApp: Bool
    /// Filled from the model's icon cache on every refresh.
    var icon: NSImage = ProcessMonitorRow.genericIcon
    /// Set by Force Quit; the row greys out and the next refresh that no longer sees the pid drops it.
    var killed = false
    /// `strerror(errno)` of a failed kill, kept for the same lifetime as `killed`.
    var killError: String?

    var id: Int32 { pid }

    /// `comm` is a path; the row shows its last component ("Editor Workflow", not the whole path).
    var name: String {
        let n = (command as NSString).lastPathComponent
        return n.isEmpty ? command : n
    }

    static let genericIcon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 16, height: 16))

    /// "1.2 GB" above a gigabyte, whole megabytes below it.
    static func memoryText(_ kib: Int64) -> String {
        let mb = Double(kib) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb.rounded())) MB"
    }

    /// Gigabytes, for the header total.
    static func gigabytes(_ kib: Int64) -> String { String(format: "%.1f GB", Double(kib) / 1_048_576) }
}

/// Sort columns; the header cycles ascending/descending for the clicked one.
enum ProcessMonitorSort: String, CaseIterable {
    case name, pid, cpu, memory
    var title: String {
        switch self {
        case .name: return "Name"
        case .pid: return "PID"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        }
    }
}

@MainActor
final class ProcessMonitorModel: ObservableObject {
    @Published private(set) var rows: [ProcessMonitorRow] = []
    @Published private(set) var sortKey: ProcessMonitorSort = .memory
    @Published private(set) var sortAscending = false
    @Published var search = ""
    @Published private(set) var rssTotalKB: Int64 = 0
    @Published private(set) var cpuTotal: Double = 0
    @Published private(set) var psError: String?

    /// 2 s refresh on the main run loop in `.common`, so scrolling or a menu doesn't pause it.
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var icons: [String: NSImage] = [:]
    /// Per-pid Force Quit outcome, merged into every refresh until the pid disappears.
    private var states: [Int32: RowState] = [:]

    private struct RowState { var killed = false; var error: String? }

    private static let bundleID = "app.editorworkflow.mac"
    private static let ownBundlePath = Bundle.main.bundleIdentifier == bundleID ? Bundle.main.bundlePath : ""
    private static let ownExecutable = Bundle.main.executablePath ?? ""

    // MARK: Data

    /// Rebuilds `rows` from ps. Consecutive refreshes merge: an existing pid keeps its icon and its
    /// kill state, and CPU stays whatever ps reported (ps already averages it over the process lifetime).
    func refresh() {
        guard let text = Self.psOutput() else {
            psError = "ps did not run"
            return
        }
        let parsed = Self.parse(text)
        let alive = Set(parsed.map(\.pid))
        for pid in states.keys where !alive.contains(pid) { states.removeValue(forKey: pid) }

        var out: [ProcessMonitorRow] = []
        out.reserveCapacity(parsed.count)
        var totalKB: Int64 = 0
        var totalCPU = 0.0
        for var row in parsed {
            row.icon = icon(for: row.command)
            if let state = states[row.pid] { row.killed = state.killed; row.killError = state.error }
            totalKB += row.rssKB
            totalCPU += row.cpu
            out.append(row)
        }
        rows = out
        rssTotalKB = totalKB
        cpuTotal = totalCPU
        psError = nil
    }

    /// `/bin/ps -axo pid=,ppid=,pcpu=,rss=,comm=`. Read the pipe before waiting: a full ps listing is
    /// close enough to the 64 KB pipe buffer that waiting first would deadlock.
    private static func psOutput() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Four numeric fields from the left; everything after them is `comm`, which may contain spaces.
    static func parse(_ text: String) -> [ProcessMonitorRow] {
        var rows: [ProcessMonitorRow] = []
        rows.reserveCapacity(512)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // maxSplits 5: the last part holds the unsplit remainder, so joining parts[4...] is the full comm.
            let parts = line.split(maxSplits: 5, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard parts.count >= 5,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]), let rssKB = Int64(parts[3])
            else { continue }
            let command = parts[4...].joined(separator: " ")
            if command.isEmpty { continue }
            rows.append(ProcessMonitorRow(pid: pid, ppid: ppid, cpu: cpu, rssKB: rssKB,
                                          command: command, isOwnApp: isOwn(command)))
        }
        return rows
    }

    private static func isOwn(_ command: String) -> Bool {
        guard !ownBundlePath.isEmpty else { return false }
        return command == ownExecutable || command.hasPrefix(ownBundlePath + "/")
    }

    private func icon(for command: String) -> NSImage {
        if let cached = icons[command] { return cached }
        // Only absolute paths have a real icon; anything else gets the generic app glyph.
        let img = command.hasPrefix("/")
            ? NSWorkspace.shared.icon(forFile: command)
            : ProcessMonitorRow.genericIcon
        icons[command] = img
        return img
    }

    // MARK: Sorting and filtering

    var visibleRows: [ProcessMonitorRow] {
        var list = rows
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(q) || String($0.pid).contains(q) }
        }
        let key = sortKey
        list.sort { a, b in
            switch key {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .pid: return a.pid < b.pid
            case .cpu: return a.cpu < b.cpu
            case .memory: return a.rssKB < b.rssKB
            }
        }
        // Ties keep a stable pid order so the list doesn't shuffle between refreshes.
        if !sortAscending { list.reverse() }
        return list
    }

    func setSort(_ key: ProcessMonitorSort) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    // MARK: Summary

    var physicalKB: Int64 { Int64(ProcessInfo.processInfo.physicalMemory / 1024) }

    /// Fraction of physical memory the summed rss occupies (shared pages count once per process, as ps does).
    var pressure: Double {
        guard physicalKB > 0 else { return 0 }
        return min(1, Double(rssTotalKB) / Double(physicalKB))
    }

    var overMemoryBudget: Bool { Double(rssTotalKB) * 1024 > 0.7 * Double(ProcessInfo.processInfo.physicalMemory) }

    // MARK: Force Quit

    func forceQuit(_ row: ProcessMonitorRow) {
        let alert = NSAlert()
        alert.messageText = "Force quit \(row.name) (pid \(row.pid))?"
        alert.informativeText = "Unsaved data in that app will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.contentTintColor = .systemRed
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // errno is read immediately: strerror of a stale errno would name the wrong failure.
        if kill(row.pid, SIGKILL) == 0 {
            states[row.pid] = RowState(killed: true, error: nil)
        } else {
            states[row.pid] = RowState(killed: false, error: String(cString: strerror(errno)))
        }
        refresh()
    }
}

// MARK: - View

struct ProcessMonitorView: View {
    @StateObject private var model = ProcessMonitorModel()

    /// Column widths shared by the header and every row, so the two stay aligned.
    enum Col {
        static let pid: CGFloat = 64
        static let cpu: CGFloat = 74
        static let mem: CGFloat = 88
        static let quit: CGFloat = 30
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            summary
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            columnHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Divider()
            list
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { model.refresh() }
        .onReceive(model.timer) { _ in model.refresh() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .help("Refresh the process list now")
                .accessibilityLabel("Refresh process list")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search processes by name or PID")
            }
            .padding(.horizontal, 8)
            .frame(width: 200, height: 28)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .help("Filter by name or PID")

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.pressure, total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                    // Memory pressure colours: green, then orange, red past 80 %.
                    .tint(model.pressure > 0.8 ? .red : model.pressure > 0.6 ? .orange : .green)
                    .accessibilityLabel("Memory pressure")
                    .accessibilityValue(Text("\(Int(model.pressure * 100)) percent"))
                    .help("Memory in use as a share of physical memory")
                Text("RAM \(ProcessMonitorRow.memoryText(model.rssTotalKB)) of \(ProcessMonitorRow.memoryText(model.physicalKB))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Memory in use \(ProcessMonitorRow.memoryText(model.rssTotalKB)) of \(ProcessMonitorRow.memoryText(model.physicalKB))")
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text("\(model.rows.count) processes")
                Text("\(ProcessMonitorRow.memoryText(model.rssTotalKB)) memory")
                Text(String(format: "%.1f%% CPU", model.cpuTotal))
                Spacer(minLength: 8)
                if let err = model.psError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(model.rows.count) processes, \(ProcessMonitorRow.memoryText(model.rssTotalKB)) of memory, \(String(format: "%.1f", model.cpuTotal)) percent CPU")

            if model.overMemoryBudget {
                Label("System has run out of application memory — quit what you don't need.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("System has run out of application memory — quit what you don't need.")
            }
        }
    }

    // MARK: Column header

    private var columnHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 16).accessibilityHidden(true)
                headerButton(.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            headerButton(.pid).frame(width: Col.pid, alignment: .trailing)
            headerButton(.cpu).frame(width: Col.cpu, alignment: .trailing)
            headerButton(.memory).frame(width: Col.mem, alignment: .trailing)
            Color.clear.frame(width: Col.quit).accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold))
    }

    private func headerButton(_ key: ProcessMonitorSort) -> some View {
        let active = model.sortKey == key
        return Button { model.setSort(key) } label: {
            HStack(spacing: 3) {
                Text(key.title)
                if active {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(key.title)")
        .accessibilityLabel("Sort by \(key.title)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: Rows

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.rows.isEmpty {
                    empty("Reading processes…")
                } else if model.visibleRows.isEmpty {
                    empty("No match")
                } else {
                    ForEach(model.visibleRows) { row in
                        ProcessRowView(row: row, forceQuit: { model.forceQuit($0) })
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .contextMenu { rowMenu(row) }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("\(row.name), process \(row.pid), \(String(format: "%.1f", row.cpu)) percent CPU, \(ProcessMonitorRow.memoryText(row.rssKB))")
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func rowMenu(_ row: ProcessMonitorRow) -> some View {
        Button("Force Quit…") { model.forceQuit(row) }
            .disabled(row.killed)
            .help("Quit this process; unsaved data will be lost")
        Divider()
        Button("Copy PID") { copy("\(row.pid)" ) }
        Button("Copy Command") { copy(row.command) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Row

private struct ProcessRowView: View {
    let row: ProcessMonitorRow
    let forceQuit: (ProcessMonitorRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: row.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(row.killed, color: .secondary)
                    .foregroundStyle(row.killed ? Color.secondary : Color.primary)
                if row.isOwnApp {
                    Text("this app")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("This is Editor Workflow, the app you are using")
                        .accessibilityLabel("This process is Editor Workflow, the app you are using")
                }
                Spacer(minLength: 8)
                Text("\(row.pid)")
                    .monospacedDigit()
                    .frame(width: ProcessMonitorView.Col.pid, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f", row.cpu))
                    .monospacedDigit()
                    .frame(width: ProcessMonitorView.Col.cpu, alignment: .trailing)
                Text(ProcessMonitorRow.memoryText(row.rssKB))
                    .monospacedDigit()
                    .frame(width: ProcessMonitorView.Col.mem, alignment: .trailing)
                ForceQuitButton(row: row, action: { forceQuit(row) })
            }
            .font(.system(size: 12))
            if let err = row.killError {
                Text("Force quit failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .accessibilityLabel("Force quit failed: \(err)")
            }
        }
    }
}

/// Small destructive control: red on hover, and it never fires without the confirmation alert.
private struct ForceQuitButton: View {
    let row: ProcessMonitorRow
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? "xmark.circle.fill" : "xmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.red : Color.secondary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.killed)
        .opacity(row.killed ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help("Force quit \(row.name) (pid \(row.pid)) — unsaved data will be lost")
        .accessibilityLabel("Force quit \(row.name), process \(row.pid)")
    }
}

// MARK: - Window

/// Owns the one "Background Activity" window. The host app calls `ProcessMonitorController.shared.open()`.
final class ProcessMonitorController: NSObject {
    static let shared = ProcessMonitorController()
    private var window: NSWindow?

    /// Opens (or re-focuses) the window. Call on the main thread.
    func open() {
        if window == nil {
            let host = NSHostingController(rootView: ProcessMonitorView())
            // A window must not size itself from its content: that fed a layout loop elsewhere in this app.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 640, height: 520))
            w.minSize = NSSize(width: 520, height: 380)
            w.title = "Background Activity"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            // Returns true when a saved frame was restored: center only on the very first open.
            let restored = w.setFrameAutosaveName("ProcessMonitorWindow")
            if !restored { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
