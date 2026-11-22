import Foundation

// MARK: - Completion report (menu bar spec p.10)

/// Audit summary of one or more jobs: scanned/selected, copied/skipped/failed, verified/not verified, bytes, time, paths, exceptions.
struct TransferReport: Equatable {
    var scanned = 0, selected = 0
    var copied = 0, skipped = 0, failed = 0
    var pending = 0
    var verified = 0, notVerified = 0
    var totalBytes: Int64 = 0, copiedBytes: Int64 = 0
    var duration: TimeInterval = 0
    var sources: [String] = []
    var destinations: [String] = []
    var exceptions: [String] = []

    /// Every selected file reached the destination and passed the chosen verification.
    var isVerified: Bool { selected > 0 && failed == 0 && pending == 0 && notVerified == 0 && copied + skipped == selected }
    var isComplete: Bool { selected > 0 && failed == 0 && pending == 0 && copied + skipped == selected }

    static func make(_ pairs: [(TransferJob, [TransferItem])]) -> TransferReport {
        var r = TransferReport()
        for (job, items) in pairs {
            r.scanned += job.scannedFiles ?? items.count
            r.selected += items.count
            r.totalBytes += job.totalBytes
            r.sources.append(job.sourcePath)
            r.destinations.append(job.outputPath)
            if let s = job.started { r.duration += (job.finished ?? Date()).timeIntervalSince(s) }
            for i in items {
                switch i.state {
                case .verified: r.copied += 1; r.verified += 1; r.copiedBytes += i.bytes
                case .copiedUnverified: r.copied += 1; r.notVerified += 1; r.copiedBytes += i.bytes
                case .skippedIdentical: r.skipped += 1; r.verified += 1
                case .skippedExisting: r.skipped += 1; r.notVerified += 1
                    r.exceptions.append("Skipped (name existed, not compared): \(i.relativePath)")
                case .failed, .unverified: r.failed += 1
                    r.exceptions.append("\(i.relativePath): \(i.message ?? "failed")")
                case .pending, .copying: r.pending += 1
                }
            }
            r.exceptions += job.warnings.filter { $0.contains("disconnected") || $0.contains("full") || $0.contains("closed") }
        }
        return r
    }

    var text: String {
        var lines = [
            "Editor Workflow transfer report",
            "Sources: " + sources.joined(separator: "; "),
            "Destinations: " + destinations.joined(separator: "; "),
            "Files scanned \(scanned) | selected \(selected)",
            "Copied \(copied) | skipped \(skipped) | failed \(failed)" + (pending > 0 ? " | pending \(pending)" : ""),
            "Verified \(verified) | not verified \(notVerified)",
            "Bytes \(copiedBytes.bytesText) of \(totalBytes.bytesText) | duration \(LocalMetrics.duration(duration))",
            "Result: " + (isVerified ? "Completed & verified" : (isComplete ? "Completed, not all files verified" : "Partial: see exceptions")),
        ]
        if !exceptions.isEmpty { lines.append("Exceptions:"); lines += exceptions.map { "  - " + $0 } }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Drive connection policy (menu bar spec p.4)

enum AutoOpenMode: String, Codable, CaseIterable {
    case open, notify, never
    var label: String { self == .open ? "Open panel automatically" : (self == .notify ? "Notify only" : "Never") }
}

enum DriveDecision: Equatable { case openPanel, notify, askTrust, ignore }

enum DrivePolicy {
    /// Never copies anything: only decides whether to open the panel, notify, ask to trust, or stay quiet.
    static func decide(_ v: VolumeIdentity, mode: AutoOpenMode, trustedOnly: Bool, trusted: Set<String>,
                       editorInFront: Bool, busy: Bool) -> DriveDecision {
        // Only real drives mount under /Volumes; macOS helper volumes (Preboot, Update, snapshots) do not.
        if v.isInternal || mode == .never || !v.mountPath.hasPrefix("/Volumes/") { return .ignore }
        if trustedOnly && !(v.uuid.map(trusted.contains) ?? false) { return .askTrust }
        // "Open automatically" means every time; busy or Resolve in front no longer silences it (the user asked for the pop-up).
        if mode == .notify { return .notify }
        return .openPanel
    }
}

// MARK: - Persisted companion state (spec p.19)

enum CompanionTab: String, Codable, CaseIterable { case transfer, favorites, create }
enum TransferStage: String, Codable { case source, destination, review }

/// Everything the menu bar must keep when the panel closes, the app restarts, or the user switches tabs.
struct TransferDraft: Codable, Equatable {
    var stage: TransferStage = .source
    var sources: [String] = []
    var destinationParent: String?
    var outputName: String = ""
    var mode: TransferMode = .cameraCardBackup
    var filter = SelectiveFilter()
    var policy: ConflictPolicy = .skipIdenticalElseKeepBoth
    /// Optional so panel state saved by older versions still decodes; nil = copy everything.
    var scope: CopyScope?
    var verification: VerificationPolicy = .sha256
    var acceptUnverified = false
    /// Jobs started from this draft (one per source); used for the completion card.
    var jobIDs: [UUID] = []
}

/// Copy → template handoff, or template-first setup. Survives restarts.
struct ProjectHandoff: Codable, Equatable {
    var transferJobIDs: [UUID] = []
    var mediaSource: String?
    var useInPlace = false
    var templateID: UUID?
    var projectName = ""
    var projectLibrary = ""
    var mappings: [BinMapping] = []
    var settings: SettingsProfile?
    var continueWithPartial = false
    var resultSessionID: UUID?
}

struct CompanionState: Codable, Equatable {
    var tab: CompanionTab = .transfer
    var draft = TransferDraft()
    var handoff: ProjectHandoff?
    var sourceBrowserPath: String?
    var destinationBrowserPath: String?
    var favoritesOrder: [UUID] = []
    var lastVerifiedDestination: String?
}

// MARK: - Camera cards

enum CameraCard {
    /// Recognizes common camera folder layouts on a card. Returns a brand name, or nil when it does not look like a camera card.
    static func detect(_ root: URL) -> String? {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(p).path) }
        let dcim = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("DCIM").path)) ?? []).map { $0.uppercased() }
        let top = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).map { $0.uppercased() }
        if dcim.contains(where: { $0.hasSuffix("GOPRO") }) || top.contains(where: { $0.contains("GOPRO") }) { return "GoPro" }
        if has("PRIVATE/M4ROOT") || has("PRIVATE/SONY") || has("XDROOT") || has("BPAV") { return "Sony" }
        if dcim.contains(where: { $0.contains("CANON") }) || has("CONTENTS/CLIPS001") || has("CANONMSC") { return "Canon" }
        if dcim.contains(where: { $0.contains("NIKON") || $0.hasPrefix("NCZ") }) { return "Nikon" }
        if dcim.contains(where: { $0.contains("PANA") }) || has("PRIVATE/PANA_GRP") || has("CONTENTS/CLIP") { return "Panasonic" }
        if dcim.contains(where: { $0.contains("FUJI") }) { return "Fujifilm" }
        if dcim.contains(where: { $0.contains("MEDIA") }) && top.contains(where: { $0.hasPrefix("DJI") }) || dcim.contains(where: { $0.contains("DJI") }) { return "DJI" }
        if top.contains(where: { $0.hasSuffix(".RDM") }) { return "RED" }
        if top.contains(where: { $0.hasSuffix(".BRAW") }) || ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains(where: { $0.lowercased().hasSuffix(".braw") }) { return "Blackmagic" }
        if has("PRIVATE/AVCHD") || has("AVCHD") { return "AVCHD camera" }
        if !dcim.isEmpty || has("PRIVATE") { return "Camera" }
        return nil
    }

    /// A readable folder name for a card copy: "GoPro 2026-11-09" instead of "NO NAME".
    static func folderName(volumeName: String, brand: String?, date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let generic = ["NO NAME", "UNTITLED", "EOS_DIGITAL", "NIKON", "CANON", "SD", "SDCARD", "LUMIX", "DCIM"]
        let base = generic.contains(volumeName.uppercased()) ? (brand ?? "Card") : volumeName
        return "\(base) \(f.string(from: date))"
    }
}
