import SwiftUI
import AppKit

/// Preflight review for one or more planned jobs (menu bar spec p.7, p.10). Used inline in the panel and as a sheet in the main window.
struct PreflightView: View {
    @EnvironmentObject var model: AppModel
    @Binding var plans: [TransferPlan]
    var compact = false
    @Binding var acceptUnverified: Bool
    @Binding var mergeConfirmed: Bool
    @Local private var showConflicts = false

    var blocks: [String] { plans.flatMap { $0.issues.filter { $0.level == .block }.map(\.message) } }
    var warns: [String] { Array(Set(plans.flatMap { $0.issues.filter { $0.level == .warn }.map(\.message) })).sorted() }
    var conflicts: Int { plans.reduce(0) { $0 + $1.conflicts.count } }
    var sizeOnly: Bool { plans.contains { $0.job.verification == .sizeOnly } }
    var destinationExists: Bool { model.draftDestination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    /// Copy is allowed only with no blocking issue, explicit approval of skipped checksums, and explicit consent to merge.
    @MainActor static func canCopy(_ plans: [TransferPlan], model: AppModel, acceptUnverified: Bool, mergeConfirmed: Bool, replaceConfirmed: Bool = true) -> Bool {
        let blocked = plans.contains { $0.issues.contains { $0.level == .block } }
        let sizeOnly = plans.contains { $0.job.verification == .sizeOnly }
        let exists = model.draftDestination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // Replace is destructive: it needs its own tick, separate from "add to this folder".
        let replacing = plans.contains { $0.job.conflictPolicy == .replace || $0.items.contains { $0.policy == .replace } }
        return !plans.isEmpty && !blocked && (!sizeOnly || acceptUnverified) && (!exists || mergeConfirmed) && (!replacing || replaceConfirmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let files = plans.reduce(0) { $0 + $1.items.count }, scanned = plans.reduce(0) { $0 + ($1.job.scannedFiles ?? 0) }
            let bytes = plans.reduce(Int64(0)) { $0 + $1.job.totalBytes }
            let excluded = plans.reduce(0) { $0 + $1.excluded.count }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("Copy from", plans.map { "\($0.job.sourceVolume?.name ?? "?") [\($0.job.sourceVolume?.shortID ?? "?")] / \(URL(fileURLWithPath: $0.job.sourcePath).lastPathComponent)" }.joined(separator: "\n"))
                row("Copy to", (model.draftDestination?.path ?? plans.first?.job.outputPath ?? "?") + "  (\(plans.first?.job.destinationVolume?.name ?? "?") [\(plans.first?.job.destinationVolume?.shortID ?? "?")])")
                row("Mode", plans.first?.job.mode.label ?? "")
                row("Files", "\(files) selected of \(scanned) scanned · \(bytes.bytesText)\(excluded > 0 ? " · \(excluded) excluded" : "")")
                row("Formats", formats)
                row("Free at destination", plans.first?.job.destinationVolume.map { "\($0.available.bytesText) (\($0.fileSystem))" } ?? "?")
                row("Conflicts", conflicts == 0 ? "None" : "\(conflicts) existing name(s): \(plans.first?.job.conflictPolicy.label ?? "")")
                if let scope = plans.first?.job.scope, scope != .all {
                    row("Compare", "\(scope.label) · \(plans.reduce(0) { $0 + $1.presentSame }) same size, \(plans.reduce(0) { $0 + $1.presentDiff }) differ, \(plans.compactMap(\.copyBytes).reduce(Int64(0), +).bytesText) to copy")
                }
                row("Verification", (plans.first?.job.verification ?? .sha256).label)
            }
            if plans.first?.job.mode == .selectiveCopy {
                Label("Selective copy is not a complete camera backup.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            ForEach(blocks, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout) }
            ForEach(warns, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            if destinationExists, let d = model.draftDestination {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\"\(d.lastPathComponent)\" already exists at the destination.", systemImage: "folder.badge.questionmark").foregroundStyle(.orange)
                    HStack {
                        Button("Use \"\(TransferRunner.uniqueName(for: d).lastPathComponent)\" instead") { model.companion.draft.outputName = TransferRunner.uniqueName(for: d).lastPathComponent; plans = model.planDraft() }
                        Toggle("Copy into the existing folder (conflict rules apply)", isOn: $mergeConfirmed).toggleStyle(.checkbox)
                    }.font(.caption)
                }
            }
            if conflicts > 0 {
                DisclosureGroup("Decide per file (\(conflicts))", isExpanded: $showConflicts) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(plans.indices, id: \.self) { pi in
                                ForEach(plans[pi].conflicts, id: \.self) { rel in
                                    if let i = plans[pi].items.firstIndex(where: { $0.relativePath == rel }) {
                                        HStack {
                                            Text(rel).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Picker("", selection: Binding(get: { plans[pi].items[i].policy ?? plans[pi].job.conflictPolicy }, set: { plans[pi].items[i].policy = $0 })) {
                                                ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.label) }
                                            }.labelsHidden().frame(width: 230).accessibilityLabel("Decision for \(rel)")
                                        }
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: compact ? 110 : 160)
                }
            }
            if sizeOnly {
                Toggle("I accept that these files will be copied but not checksum-verified", isOn: $acceptUnverified).toggleStyle(.checkbox).foregroundStyle(.orange)
            }
            if plans.contains(where: { $0.items.contains { $0.policy == .replace } || $0.job.conflictPolicy == .replace }) {
                Label("Some existing files will be replaced.", systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
        }
    }

    var formats: String {
        var totals: [MediaCategory: CategoryTotal] = [:]
        for p in plans { for (k, v) in p.included { totals[k, default: CategoryTotal()].count += v.count; totals[k, default: CategoryTotal()].bytes += v.bytes } }
        return totals.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value.count)" }.joined(separator: " · ")
    }

    @ViewBuilder func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary).font(compact ? .caption : .callout); Text(v).font(compact ? .caption : .callout).textSelection(.enabled) }
    }
}

/// Live job card: phase, current file, files/bytes, rolling speed, remaining time, controls.
struct JobProgressCard: View {
    @EnvironmentObject var model: AppModel
    let job: TransferJob

    var body: some View {
        let live = model.live[job.id]
        let waiting = model.queue.contains(job.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.name).bold().lineLimit(1)
                Spacer()
                Text(waiting ? "Waiting" : (live?.phase ?? job.status.label)).font(.caption.bold()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(job.copiedBytes), total: Double(max(job.totalBytes, 1)))
            HStack {
                Text("\(job.doneFiles ?? 0) of \(job.totalFiles) files · \(job.copiedBytes.bytesText) of \(job.totalBytes.bytesText)")
                Spacer()
                if let bps = live?.bytesPerSecond, bps > 0 {
                    Text("\(Int64(bps).bytesText)/s · \(LocalMetrics.duration(Double(job.totalBytes - job.copiedBytes) / bps)) left")
                }
            }.font(.caption).foregroundStyle(.secondary)
            // Always one line, so the card doesn't jump between files.
            Text((live?.currentFile).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent } ?? " ")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if job.status == .interrupted, let w = job.warnings.last { Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                if model.running.contains(job.id) { Button("Pause") { model.pause(job) } }
                if [.paused, .interrupted].contains(job.status) && !model.running.contains(job.id) && !waiting { Button("Resume") { model.resume(job) } }
                if waiting { Button("Start Next") { model.startNext(job) } }
                Button("Cancel") { model.cancel(job) }
            }.controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// Persistent audit summary after jobs end (spec p.10), with next actions as labelled icons.
struct CompletionCard: View {
    @EnvironmentObject var model: AppModel
    let ids: [UUID]
    @Local private var showExceptions = false

    /// The external source drive of these copies, while it is still connected.
    var ejectableSource: VolumeIdentity? {
        let vols = ids.compactMap { id in model.jobs.first { $0.id == id }?.sourceVolume }
        guard let v = vols.first, vols.allSatisfy({ $0.mountPath == v.mountPath }), !v.isInternal,
              FileManager.default.fileExists(atPath: v.mountPath) else { return nil }
        return v
    }

    func eject(_ v: VolumeIdentity) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v.mountPath)) }
        catch { model.errorMessage = "\(v.name) could not be ejected: \(error.localizedDescription) Close any app using it and try again." }
    }

    var body: some View {
        let r = model.report(for: ids)
        let dest = model.draftDestination ?? URL(fileURLWithPath: r.destinations.first ?? "/")
        let checking = ids.contains { model.rechecking.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: r.isVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22)).foregroundStyle(r.isVerified ? Theme.verified : Theme.attention)
                VStack(alignment: .leading, spacing: 1) {
                    // The folder is the thing you made: say it big, then what happened to it.
                    Text(dest.lastPathComponent).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(dest.path)
                    Text(r.isVerified ? "\(r.verified) \(r.verified == 1 ? "file" : "files") copied and checked"
                         : (r.failed > 0 ? "\(r.failed) of \(r.copied + r.failed) files could not be copied" : "\(r.copied) copied, \(r.notVerified) not checked"))
                        .font(.callout.weight(.semibold)).foregroundStyle(r.isVerified ? Theme.verified : Theme.attention)
                    Text("\(r.copiedBytes.bytesText) in \(LocalMetrics.duration(r.duration))\(r.skipped > 0 ? ", \(r.skipped) already there" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button { NSWorkspace.shared.open(dest) } label: { Label("Open Folder", systemImage: "folder") }
                Button { model.recheck(ids) } label: { Label(checking ? "Checking…" : "Check Again", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(checking).help("Read every copy again and compare it with the original")
                if r.failed > 0 {
                    Button {
                        for id in ids { if let j = model.jobs.first(where: { $0.id == id }), [.partiallyVerified, .failed].contains(j.status) { model.retryFailed(j) } }
                    } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
                }
                if !r.exceptions.isEmpty {
                    Button { showExceptions.toggle() } label: { Label(showExceptions ? "Hide Problems" : "Show Problems", systemImage: "list.bullet") }
                }
                Spacer()
                // Only after every file is verified: the card is then safe to take out.
                if r.isVerified, let card = ejectableSource {
                    Button { eject(card) } label: { Label("Eject \(card.name)", systemImage: "eject.fill") }
                        .help("Every file is checked. Safe to take the card out.")
                }
                Button { model.exportReport(ids) } label: { Label("Save Report", systemImage: "doc.text") }
                    .help("Save a list of every file with its checksum")
            }
            if showExceptions {
                ScrollView { VStack(alignment: .leading) { ForEach(r.exceptions, id: \.self) { Text($0).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 90)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    func stat(_ icon: String, _ value: String, _ label: String, _ tint: Color = .secondary) -> some View {
        VStack(spacing: 1) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(value).font(Theme.number(13))
        }
        .help(label).accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(value)")
    }
}

/// Queue with order, start-next, pause/resume/cancel and history removal (spec p.9).
struct QueueRows: View {
    @EnvironmentObject var model: AppModel
    var includeHistory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.activeJobs) { JobProgressCard(job: $0) }
            ForEach(Array(model.waitingJobs.enumerated()), id: \.element.id) { i, j in
                HStack(spacing: 4) {
                    Image(systemName: "hourglass").foregroundStyle(.secondary).help("Waiting")
                    VStack(alignment: .leading) { Text(j.name).lineLimit(1); Text("\(j.totalFiles) files · \(j.totalBytes.bytesText)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    IconButton(symbol: "arrow.up", label: "Move earlier", size: 11) { model.moveInQueue(j, by: -1) }.disabled(i == 0)
                    IconButton(symbol: "arrow.down", label: "Move later", size: 11) { model.moveInQueue(j, by: 1) }.disabled(i == model.waitingJobs.count - 1)
                    Button("Start Now") { model.startNext(j) }.controlSize(.small)
                    Button("Cancel") { model.cancel(j) }.controlSize(.small)
                }
            }
            let attention = model.jobs.filter { [.paused, .interrupted].contains($0.status) && !model.running.contains($0.id) && !model.queue.contains($0.id) }
            ForEach(attention) { j in
                HStack(spacing: 4) {
                    Image(systemName: j.status == .interrupted ? "exclamationmark.triangle.fill" : "pause.circle").foregroundStyle(Theme.attention)
                    VStack(alignment: .leading) { Text(j.name).lineLimit(1); Text(j.status == .interrupted ? (j.warnings.last ?? "Needs attention") : "Paused").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button("Resume") { model.resume(j) }.controlSize(.small)
                    Button("Other Drive…") { model.continueElsewhere(j) }.controlSize(.small).help("Continue this copy on another drive")
                }
            }
            if includeHistory {
                let done = model.jobs.filter { [.verified, .partiallyVerified, .failed, .cancelled, .copiedUnverified].contains($0.status) }.prefix(15)
                if !done.isEmpty {
                    Text("Finished").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(Array(done)) { j in
                        HStack(spacing: 4) {
                            Image(systemName: j.status == .verified ? "checkmark.circle.fill" : "exclamationmark.triangle").foregroundStyle(j.status == .verified ? Theme.verified : Theme.attention)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(j.name).lineLimit(1)
                                Text(j.status == .verified ? "Copied and checked" : j.status.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: j.outputPath)) }.controlSize(.small)
                            Button(model.rechecking.contains(j.id) ? "Checking…" : "Check Again") { model.recheck([j.id]) }.controlSize(.small)
                                .disabled(model.rechecking.contains(j.id) || j.status == .failed)
                            Button("Remove") { model.removeHistory(j) }.controlSize(.small).help("Removes it from this list. Copied files stay.")
                        }
                    }
                }
            }
            if model.activeJobs.isEmpty && model.waitingJobs.isEmpty && attention.isEmpty && !includeHistory {
                Label("No transfers queued", systemImage: "tray").foregroundStyle(.secondary)
            }
        }
    }
}
