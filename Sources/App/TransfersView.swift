import SwiftUI
import AppKit


/// Main-window transfer screen: the same route as the menu bar panel, wider, with the queue under it.
struct TransfersView: View {
    @EnvironmentObject var model: AppModel
    /// Used by the project wizard: each queued job's output becomes a media source.
    var onQueued: ((TransferJob) -> Void)? = nil
    @StateObject private var panel = PanelState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TransferPage(panel: panel, wide: true, onQueued: onQueued)
                if !(model.activeJobs.isEmpty && model.waitingJobs.isEmpty && !model.jobs.contains { [.paused, .interrupted].contains($0.status) }) {
                    Divider()
                    QueueRows(includeHistory: false)
                }
            }
            .padding(20)
        }
        .navigationTitle("Transfers")
        .onAppear {
            if let p = model.transferPreset {
                if let s = p.source { model.companion.draft.sources = [s]; model.sourceBrowser.open(URL(fileURLWithPath: s).deletingLastPathComponent()); model.sourceBrowser.selection = [s] }
                if let d = p.destination { model.companion.draft.destinationParent = d; model.destBrowser.open(URL(fileURLWithPath: d)) }
                model.transferPreset = nil
            }
        }
    }
}

func unique(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0).inserted } }

// MARK: - Queue / History

struct JobRow: View {
    let job: TransferJob
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).bold().lineLimit(1)
                Text(job.status.label).font(.caption.bold()).foregroundStyle(color)
            }
            if job.status == .running || job.status == .paused || job.status == .interrupted {
                ProgressView(value: Double(job.copiedBytes), total: Double(max(job.totalBytes, 1)))
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            if let w = job.warnings.last, job.status == .interrupted { Text(w).font(.caption).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .combine)
    }
    /// Finished: size, files, speed. Unfinished: how far it got. No "0 bytes/s" noise.
    var summary: String {
        let done = job.copiedBytes >= job.totalBytes && job.totalBytes > 0
        var parts = done ? [job.totalBytes.bytesText, "\(job.totalFiles) files"]
                         : ["\(job.copiedBytes.bytesText) of \(job.totalBytes.bytesText)", "\(job.doneFiles ?? 0) of \(job.totalFiles) files"]
        if let s = job.started, job.copiedBytes > 0 {
            let t = (job.finished ?? Date()).timeIntervalSince(s)
            if t > 1 { parts.append("\(Int64(Double(job.copiedBytes) / t).bytesText)/s") }
        }
        return parts.joined(separator: ", ")
    }
    var color: Color {
        switch job.status {
        case .verified: return .green
        case .partiallyVerified, .paused, .interrupted, .copiedUnverified: return .orange
        case .failed, .cancelled: return .red
        default: return .secondary
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Local private var selected: TransferJob.ID?
    @Local private var showMetrics = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.jobs, selection: $selected) { j in JobRow(job: j).tag(j.id) }
                    .contextMenu(forSelectionType: TransferJob.ID.self) { ids in
                        Button("Remove from History…") { remove(ids) }
                            .disabled(ids.isEmpty || ids.contains { model.running.contains($0) || model.queue.contains($0) })
                    }
                    .overlay {
                        if model.jobs.isEmpty {
                            EmptyState(icon: "clock.arrow.circlepath", title: "No copies yet", action: "Copy footage") { model.selection = .transfers }
                        }
                    }
                HStack { Button { showMetrics = true } label: { Label("Local Metrics", systemImage: "chart.bar") }; Spacer() }.padding(8)
            }.frame(minWidth: 360)
            if let id = selected, let j = model.jobs.first(where: { $0.id == id }) {
                JobDetail(job: j).frame(minWidth: 420)
            } else {
                EmptyState(icon: "checkmark.shield", title: "Pick a copy to see its checks")
            }
        }
        .navigationTitle("History")
        .onDeleteCommand { if let selected { remove([selected]) } }
        .sheet(isPresented: $showMetrics) { MetricsView().environmentObject(model) }
    }
}

extension HistoryView {
    /// Forgets the records only. Copied files stay where they are; a paused copy can no longer be resumed.
    func remove(_ ids: Set<TransferJob.ID>) {
        let busy = ids.contains { model.running.contains($0) || model.queue.contains($0) }
        guard !ids.isEmpty, !busy else { return }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? "Remove this copy from History?" : "Remove \(ids.count) copies from History?"
        a.informativeText = "Only the record is removed. The copied files stay where they are. A paused copy can no longer be resumed."
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let s = selected, ids.contains(s) { selected = nil }
        for id in ids { if let j = model.jobs.first(where: { $0.id == id }) { model.removeHistory(j) } }
    }
}

struct MetricsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Local private var m: LocalMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Metrics").font(.title2.bold())
            Label("Stays on this Mac", systemImage: "lock").font(.caption).foregroundStyle(.secondary).help("Computed from the app's own records. Nothing is sent anywhere.")
            if let m {
                Form {
                    Section("Transfers") { ForEach(m.transfers, id: \.self) { LabeledContent($0.label, value: $0.value) } }
                    Section("Projects") { ForEach(m.projects, id: \.self) { LabeledContent($0.label, value: $0.value) } }
                    Section("Templates") { ForEach(m.templates, id: \.self) { LabeledContent($0.label, value: $0.value) } }
                }.formStyle(.grouped)
            } else { ProgressView() }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 640, height: 560)
        .task {
            let db = model.db, jobs = model.jobs, sessions = model.sessions, templates = model.templateList
            m = await Task.detached { LocalMetrics.compute(jobs: jobs, items: db.all("titem", as: TransferItem.self), sessions: sessions, templates: templates) }.value
        }
    }
}

struct JobDetail: View {
    @EnvironmentObject var model: AppModel
    let job: TransferJob
    @Local private var items: [TransferItem] = []
    @Local private var problemsOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.name).font(.title3.bold())
            Text("\(job.mode.label) · \(job.status.label) · created \(job.created.formatted())\(duration)").foregroundStyle(.secondary)
            Text("From \(job.sourceVolume?.name ?? "?") [\(job.sourceVolume?.shortID ?? "?")]: \(job.sourcePath)").font(.caption).textSelection(.enabled)
            Text("To \(job.destinationVolume?.name ?? "?") [\(job.destinationVolume?.shortID ?? "?")]: \(job.outputPath)").font(.caption).textSelection(.enabled)
            let counts = Dictionary(grouping: items, by: \.state).mapValues(\.count)
            Text(counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: " · ")).font(.caption)
            ForEach(job.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if !job.metadataNotPreserved.isEmpty { Text("Metadata not preserved for \(job.metadataNotPreserved.count) file(s).").font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 2) {
                IconButton(symbol: problemsOnly ? "exclamationmark.triangle.fill" : "list.bullet", label: problemsOnly ? "Showing problems only" : "Showing all files", tint: .secondary) { problemsOnly.toggle() }
                Divider().frame(height: 18)
                IconButton(symbol: "folder", label: "Open destination") { NSWorkspace.shared.open(URL(fileURLWithPath: job.outputPath)) }
                if let m = job.manifestPath {
                    IconButton(symbol: "doc.text.magnifyingglass", label: "Show manifest") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m)]) }
                    IconButton(symbol: "square.and.arrow.up", label: "Export summary") { export(m) }
                }
                if [.partiallyVerified, .failed].contains(job.status) { IconButton(symbol: "arrow.clockwise", label: "Retry failed files", tint: Theme.accent) { model.retryFailed(job) } }
                if [.partiallyVerified, .failed, .interrupted].contains(job.status) { IconButton(symbol: "folder.badge.plus", label: "Continue on another drive") { model.continueElsewhere(job) } }
            }
            List(items.filter { !problemsOnly || !$0.state.isDone }) { i in
                VStack(alignment: .leading) {
                    HStack { Text(i.relativePath).font(.caption.monospaced()); Spacer(); Text(i.state.rawValue).font(.caption.bold()) }
                    if let m = i.message { Text(m).font(.caption).foregroundStyle(.orange) }
                    if let h = i.sourceHash { Text("sha256 \(h)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .padding(16)
        .task(id: job.id) { items = model.runner.items(job.id) }
        .task(id: job.status) { items = model.runner.items(job.id) }
    }

    var duration: String {
        guard let s = job.started else { return "" }
        let t = (job.finished ?? Date()).timeIntervalSince(s)
        return " · took " + LocalMetrics.duration(t)
    }

    func export(_ manifest: String) {
        guard let dir = AppModel.chooseFolder(prompt: "Export Here") else { return }
        for ext in ["json", "csv"] {
            let src = URL(fileURLWithPath: manifest).deletingPathExtension().appendingPathExtension(ext)
            let dst = TransferRunner.uniqueNameIfNeeded(dir.appendingPathComponent("\(job.name.replacingOccurrences(of: "/", with: "-")) manifest.\(ext)"))
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        NSWorkspace.shared.open(dir)
    }
}
