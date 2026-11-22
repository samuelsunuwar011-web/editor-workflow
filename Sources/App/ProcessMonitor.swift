import SwiftUI
import AppKit
import Combine
import Darwin

/// "Background Activity": an Activity Monitor lite, grouped by app.
/// Opens as its own window (`ProcessMonitorController.shared.open()`) and as the panel's Activity tab.
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

/// All processes of one app, aggregated: what the user actually wants to see
/// ("DaVinci Resolve — 6 processes, 312 % CPU, 4.2 GB").
struct ProcessAppGroup: Identifiable {
    /// Bundle path when the processes came from a .app, otherwise the executable path.
    let key: String
    /// Display name: bundle name without ".app", else the executable's last component.
    let name: String
    let icon: NSImage
    /// Sum of the members' ps CPU (multi-core apps exceed 100).
    let cpu: Double
    let rssKB: Int64
    /// Member pids, ascending — the quit order.
    let pids: [Int32]
    let isOwnApp: Bool
    /// Every member is marked killed.
    let killed: Bool
    /// First failed-quit error, if any member refused to die.
    let killError: String?

    var id: String { key }
    var procCount: Int { pids.count }
}

/// Sort columns; the header cycles ascending/descending for the clicked one.
enum ProcessMonitorSort: String, CaseIterable {
    case name, pid, cpu, memory
    var title: String {
        switch self {
        case .name: return "App"
        case .pid: return "Procs"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        }
    }
}

@MainActor
final class ProcessMonitorModel: ObservableObject {
    @Published private(set) var rows: [ProcessMonitorRow] = []
    @Published private(set) var groups: [ProcessAppGroup] = []
    @Published private(set) var sortKey: ProcessMonitorSort = .memory
    @Published private(set) var sortAscending = false
    @Published var search = ""
    /// App-group keys ticked for "Quit Selected".
    @Published var selection: Set<String> = []
    /// App-groups expanded to show their individual processes.
    @Published var expanded: Set<String> = []
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

    /// Rebuilds `rows` and `groups` from ps. Consecutive refreshes merge: an existing pid keeps its
    /// icon and its kill state, and CPU stays whatever ps reported (ps already averages it).
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
        groups = Self.aggregate(out)
        // Drop ticks and expansions for apps that just vanished.
        let aliveKeys = Set(groups.map(\.key))
        selection = selection.intersection(aliveKeys)
        expanded = expanded.intersection(aliveKeys)
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

    /// Groups ps rows into apps: anything under a .app (or under .../Contents/) belongs to that bundle;
    /// loose binaries each form their own group.
    static func aggregate(_ rows: [ProcessMonitorRow]) -> [ProcessAppGroup] {
        struct Acc {
            var name = ""
            var cpu = 0.0
            var rssKB: Int64 = 0
            var pids: [Int32] = []
            var own = false
            var killed = true
            var error: String?
            var sample = ""
        }
        var byKey: [String: Acc] = [:]
        for row in rows {
            let (key, name) = appKey(row.command)
            var g = byKey[key] ?? Acc()
            if g.name.isEmpty { g.name = name; g.sample = row.command }
            g.cpu += row.cpu
            g.rssKB += row.rssKB
            g.pids.append(row.pid)
            g.own = g.own || row.isOwnApp
            g.killed = g.killed && row.killed
            if let e = row.killError, g.error == nil { g.error = e }
            byKey[key] = g
        }
        return byKey.map { key, g in
            ProcessAppGroup(key: key, name: g.name, icon: iconForGroup(g.sample),
                            cpu: g.cpu, rssKB: g.rssKB, pids: g.pids.sorted(), isOwnApp: g.own,
                            killed: g.killed, killError: g.error)
        }
    }

    /// Bundle path when the executable lives inside a .app, else the executable path itself.
    static func appKey(_ command: String) -> (key: String, name: String) {
        if let r = command.range(of: ".app/"), r.upperBound < command.endIndex {
            let bundle = String(command[..<r.upperBound])          // includes ".app/"
            let path = String(bundle.dropLast())                   // strip trailing "/"
            return (path, (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))
        }
        if let r = command.range(of: "/Contents/") {
            let path = String(command[..<r.lowerBound])
            return (path, (path as NSString).lastPathComponent)
        }
        let name = (command as NSString).lastPathComponent
        return (command, name.isEmpty ? command : name)
    }

    private static func iconForGroup(_ command: String) -> NSImage {
        if command.hasPrefix("/") {
            return NSWorkspace.shared.icon(forFile: command)
        }
        return ProcessMonitorRow.genericIcon
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

    /// Groups after search + sort — what the list renders.
    var visibleGroups: [ProcessAppGroup] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = groups
        if !q.isEmpty {
            list = list.filter { g in
                g.name.localizedCaseInsensitiveContains(q)
                    || g.pids.contains { String($0).contains(q) }
                    || rows.contains { $0.command.contains(q) && Self.appKey($0.command).key == g.key }
            }
        }
        let key = sortKey
        list.sort { a, b in
            switch key {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .pid: return a.procCount < b.procCount
            case .cpu: return a.cpu < b.cpu
            case .memory: return a.rssKB < b.rssKB
            }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    /// Members of one expanded group, filtered by the same search, in pid order.
    func visibleMembers(of group: ProcessAppGroup) -> [ProcessMonitorRow] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            guard group.pids.contains(row.pid) else { return false }
            if q.isEmpty { return true }
            return row.name.localizedCaseInsensitiveContains(q) || String(row.pid).contains(q) || row.command.localizedCaseInsensitiveContains(q)
        }
        .sorted { $0.pid < $1.pid }
    }

    func setSort(_ key: ProcessMonitorSort) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    func toggleSelect(_ group: ProcessAppGroup) {
        if selection.contains(group.key) { selection.remove(group.key) } else { selection.insert(group.key) }
    }

    func toggleExpand(_ group: ProcessAppGroup) {
        if expanded.contains(group.key) { expanded.remove(group.key) } else { expanded.insert(group.key) }
    }

    /// Ticks (or unticks) every group the search currently shows.
    func toggleSelectAll() {
        let visible = visibleGroups.map(\.key)
        if visible.allSatisfy({ selection.contains($0) }) { selection.subtract(visible) }
        else { selection.formUnion(visible) }
    }

    var allVisibleSelected: Bool {
        let visible = visibleGroups.map(\.key)
        return !visible.isEmpty && visible.allSatisfy { selection.contains($0) }
    }

    // MARK: Summary

    var physicalKB: Int64 { Int64(ProcessInfo.processInfo.physicalMemory / 1024) }

    /// Fraction of physical memory the summed rss occupies (shared pages count once per process, as ps does).
    var pressure: Double {
        guard physicalKB > 0 else { return 0 }
        return min(1, Double(rssTotalKB) / Double(physicalKB))
    }

    var overMemoryBudget: Bool { Double(rssTotalKB) * 1024 > 0.7 * Double(ProcessInfo.processInfo.physicalMemory) }

    /// The heaviest apps right now — "show me what's using the most".
    var topConsumers: [ProcessAppGroup] {
        groups.sorted { $0.cpu > $1.cpu }.prefix(3).filter { $0.cpu >= 1 }.map { $0 }
    }

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
        killPids([row.pid])
    }

    /// One confirmation, then every pid of every ticked app.
    func forceQuit(selectedGroups: [ProcessAppGroup]) {
        guard !selectedGroups.isEmpty else { return }
        let procs = selectedGroups.reduce(0) { $0 + $1.procCount }
        let alert = NSAlert()
        alert.messageText = "Force quit \(selectedGroups.count) app(s), \(procs) process(es)?"
        alert.informativeText = selectedGroups.map(\.name).joined(separator: ", ") + "\n\nUnsaved data in those apps will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.contentTintColor = .systemRed
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        killPids(selectedGroups.flatMap(\.pids))
    }

    /// Everything on screen except this app (killing ourselves would take the panel down mid-confirm).
    func quitAll(visibleGroups visible: [ProcessAppGroup]) {
        let targets = visible.filter { !$0.isOwnApp }
        guard !targets.isEmpty else { return }
        let procs = targets.reduce(0) { $0 + $1.procCount }
        let alert = NSAlert()
        alert.messageText = "Force quit all \(targets.count) app(s), \(procs) process(es)?"
        alert.informativeText = "This app and macOS system processes are skipped. Unsaved data in everything else will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.contentTintColor = .systemRed
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        killPids(targets.flatMap(\.pids))
    }

    private func killPids(_ pids: [Int32]) {
        for pid in pids {
            // errno is read immediately: strerror of a stale errno would name the wrong failure.
            if kill(pid, SIGKILL) == 0 {
                states[pid] = RowState(killed: true, error: nil)
            } else {
                states[pid] = RowState(killed: false, error: String(cString: strerror(errno)))
            }
        }
        refresh()
    }
}

// MARK: - View

struct ProcessMonitorView: View {
    @StateObject private var model = ProcessMonitorModel()

    /// Column widths shared by the header and every row, so the two stay aligned.
    enum Col {
        static let check: CGFloat = 22
        static let procs: CGFloat = 56
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
                    .accessibilityLabel("Search apps or processes by name or PID")
            }
            .padding(.horizontal, 8)
            .frame(width: 170, height: 28)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .help("Filter by name or PID")

            Spacer(minLength: 8)

            Button {
                model.forceQuit(selectedGroups: model.visibleGroups.filter { model.selection.contains($0.key) })
            } label: {
                Label("Quit Selected", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.selection.isEmpty)
            .help("Force quit every ticked app")
            .accessibilityLabel("Force quit selected apps")

            Button {
                model.quitAll(visibleGroups: model.visibleGroups)
            } label: {
                Label("Quit All", systemImage: "power")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .help("Force quit every visible app except this one and system processes")
            .accessibilityLabel("Quit all visible apps")

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.pressure, total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
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
                Text("\(model.groups.count) apps · \(model.rows.count) processes")
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
            .accessibilityLabel("\(model.groups.count) apps, \(model.rows.count) processes, \(ProcessMonitorRow.memoryText(model.rssTotalKB)) of memory, \(String(format: "%.1f", model.cpuTotal)) percent CPU")

            if !model.topConsumers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "flame").font(.caption).foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Using most: " + model.topConsumers.map { "\($0.name) \(String(format: "%.0f%%", $0.cpu))" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Using most CPU: " + model.topConsumers.map { "\($0.name), \(String(format: "%.0f", $0.cpu)) percent" }.joined(separator: ", "))
            }

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
            Button { model.toggleSelectAll() } label: {
                Image(systemName: model.allVisibleSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(model.allVisibleSelected ? Theme.accent : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: Col.check)
            .help("Select every app in the list")
            .accessibilityLabel("Select all apps")

            HStack(spacing: 8) {
                Color.clear.frame(width: 16).accessibilityHidden(true)
                headerButton(.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            headerButton(.pid).frame(width: Col.procs, alignment: .trailing)
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
                } else if model.visibleGroups.isEmpty {
                    empty("No match")
                } else {
                    ForEach(model.visibleGroups) { group in
                        AppGroupRow(
                            group: group,
                            selected: model.selection.contains(group.key),
                            expanded: model.expanded.contains(group.key),
                            members: model.expanded.contains(group.key) ? model.visibleMembers(of: group) : [],
                            onToggleSelect: { model.toggleSelect(group) },
                            onToggleExpand: { model.toggleExpand(group) },
                            forceQuit: { model.forceQuit($0) },
                            forceQuitGroup: { model.forceQuit(selectedGroups: [group]) }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .contextMenu { rowMenu(group) }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(group.name), \(group.procCount) processes, \(String(format: "%.1f", group.cpu)) percent CPU, \(ProcessMonitorRow.memoryText(group.rssKB))")
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
    private func rowMenu(_ group: ProcessAppGroup) -> some View {
        Button(model.expanded.contains(group.key) ? "Collapse Processes" : "Expand Processes") { model.toggleExpand(group) }
        Button("Quit This App…") { model.forceQuit(selectedGroups: [group]) }
            .disabled(group.killed)
            .help("Quit every process of this app; unsaved data will be lost")
        Divider()
        Button(model.selection.contains(group.key) ? "Deselect" : "Select for Quit") { model.toggleSelect(group) }
        Button("Copy App Path") { copy(group.key) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Group row

private struct AppGroupRow: View {
    let group: ProcessAppGroup
    let selected: Bool
    let expanded: Bool
    let members: [ProcessMonitorRow]
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let forceQuit: (ProcessMonitorRow) -> Void
    let forceQuitGroup: () -> Void
    @Local private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button(action: onToggleSelect) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Theme.accent : (hovering ? Color.secondary : Color.secondary.opacity(0.6)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: ProcessMonitorView.Col.check)
                .help(selected ? "Deselect \(group.name)" : "Select \(group.name) for Quit Selected")
                .accessibilityLabel(selected ? "Deselect \(group.name)" : "Select \(group.name) for quit selected")

                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide this app's processes" : "Show this app's processes")
                .accessibilityLabel(expanded ? "Collapse \(group.name)" : "Expand \(group.name)")

                Image(nsImage: group.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(group.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(group.killed, color: .secondary)
                    .foregroundStyle(group.killed ? Color.secondary : Color.primary)
                if group.procCount > 1 {
                    Text("\(group.procCount) procs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(group.procCount) processes")
                }
                if group.isOwnApp {
                    Text("this app")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("This is Editor Workflow, the app you are using")
                        .accessibilityLabel("This is Editor Workflow, the app you are using")
                }
                Spacer(minLength: 8)
                Text(String(format: "%.1f", group.cpu))
                    .monospacedDigit()
                    .frame(width: ProcessMonitorView.Col.cpu, alignment: .trailing)
                Text(ProcessMonitorRow.memoryText(group.rssKB))
                    .monospacedDigit()
                    .frame(width: ProcessMonitorView.Col.mem, alignment: .trailing)
                GroupQuitButton(group: group, action: forceQuitGroup)
            }
            .font(.system(size: 12))
            if let err = group.killError {
                Text("Force quit failed for some processes: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
                    .accessibilityLabel("Force quit failed for some processes: \(err)")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(members) { member in
                        ProcessMemberRow(row: member, forceQuit: forceQuit)
                            .padding(.leading, 34)
                    }
                }
                .padding(.top, 3)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// One process inside an expanded app group.
private struct ProcessMemberRow: View {
    let row: ProcessMonitorRow
    let forceQuit: (ProcessMonitorRow) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(row.killed, color: .secondary)
                .foregroundStyle(row.killed ? Color.secondary : Color.primary)
            Spacer(minLength: 8)
            Text("\(row.pid)")
                .monospacedDigit()
                .frame(width: ProcessMonitorView.Col.procs, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f", row.cpu))
                .monospacedDigit()
                .frame(width: ProcessMonitorView.Col.cpu, alignment: .trailing)
            Text(ProcessMonitorRow.memoryText(row.rssKB))
                .monospacedDigit()
                .frame(width: ProcessMonitorView.Col.mem, alignment: .trailing)
            ForceQuitButton(row: row, action: { forceQuit(row) })
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("process \(row.name), pid \(row.pid), \(String(format: "%.1f", row.cpu)) percent CPU, \(ProcessMonitorRow.memoryText(row.rssKB))")
    }
}

/// Quit control for a whole app group.
private struct GroupQuitButton: View {
    let group: ProcessAppGroup
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
        .disabled(group.killed)
        .opacity(group.killed ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help("Force quit \(group.name) — all \(group.procCount) process(es); unsaved data will be lost")
        .accessibilityLabel("Force quit \(group.name), \(group.procCount) processes")
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
            w.setContentSize(NSSize(width: 680, height: 540))
            w.minSize = NSSize(width: 560, height: 400)
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
