import Foundation
import CryptoKit

struct PreflightIssue: Hashable {
    enum Level: String { case block, warn }
    var level: Level
    var message: String
}

struct CategoryTotal: Hashable { var count = 0; var bytes: Int64 = 0 }

struct TransferPlan {
    var job: TransferJob
    var items: [TransferItem]
    var excluded: [TransferItem]
    var included: [MediaCategory: CategoryTotal]
    var skippedLinks: [String]
    var issues: [PreflightIssue]
    /// Files whose destination name already exists; the review screen can set a decision per file.
    var conflicts: [String] = []
    /// With a scope != .all: how many files are already at the destination with the same size / a different size.
    var presentSame = 0
    var presentDiff = 0
    /// Bytes of the files that will actually be copied (scope-aware).
    var copyBytes: Int64?
    var canStart: Bool { !issues.contains { $0.level == .block } }
    /// First levels of the output tree, for the review screen.
    var outputPreview: [String] {
        let tops = Set(items.map { $0.relativePath.split(separator: "/").prefix(2).joined(separator: "/") })
        return tops.sorted().prefix(40).map { (job.outputPath as NSString).appendingPathComponent($0) }
    }
}

enum Hashing {
    static let chunk = 8 * 1024 * 1024

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: chunk), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Folder names and extensions that mark a camera structure whose clips depend on companions.
enum CameraPackages {
    static let folderMarkers: Set<String> = ["PRIVATE", "M4ROOT", "XDROOT", "AVCHD", "BPAV", "CONTENTS", "CLIP", "SUB", "BDMV", "STREAM", "CANONMSC", "CRM"]
    static let extMarkers: Set<String> = ["rdm", "rdc", "braw", "r3d", "mxf", "crm", "ari"]

    static func warnings(for items: [TransferItem], excluded: [TransferItem]) -> [String] {
        var out: [String] = []
        let comps = Set(items.flatMap { $0.relativePath.split(separator: "/").dropLast().map { $0.uppercased() } })
        let markers = comps.intersection(folderMarkers)
        if !markers.isEmpty {
            out.append("Camera structure detected (\(markers.sorted().joined(separator: ", "))). Clips here can depend on folder layout and metadata files. Use Camera Card Backup for originals.")
        }
        let exts = Set(items.map { URL(fileURLWithPath: $0.relativePath).pathExtension.lowercased() }).intersection(extMarkers)
        if !exts.isEmpty {
            out.append("RAW or professional clip formats (\(exts.sorted().joined(separator: ", "))) can rely on sidecars or spanned files.")
        }
        // Excluded files that share a base name with an included clip are likely companions.
        // Camera naming appends a suffix after the clip stem (C0001.MP4 + C0001M01.XML); a longer
        // number (C0001 vs C00012) is a different clip, not a companion.
        let includedStems = Set(items.map { ($0.relativePath as NSString).deletingPathExtension.collisionKey })
        func isCompanion(_ stem: String) -> Bool {
            guard !stem.isEmpty else { return false }
            var end = stem.startIndex
            while end < stem.endIndex {
                let prefix = String(stem[stem.startIndex..<end])
                let next = stem[end]
                if includedStems.contains(prefix), !next.isNumber { return true }
                end = stem.index(after: end)
            }
            return includedStems.contains(stem)
        }
        let companions = excluded.filter { isCompanion(($0.relativePath as NSString).deletingPathExtension.collisionKey) }
        if !companions.isEmpty {
            out.append("\(companions.count) excluded file(s) share a name with included clips and may be required companions, e.g. \(companions.prefix(3).map { $0.relativePath }.joined(separator: ", ")).")
        }
        return out
    }
}

enum TransferPlanner {
    /// Builds the plan and runs every preflight check. `freeSpace` is injectable for tests.
    static func plan(name: String, source: URL, destinationRoot: URL, mode: TransferMode, filter: SelectiveFilter?,
                     policy: ConflictPolicy, freeSpace: ((URL) -> Int64?)? = nil, only: Set<String>? = nil,
                     verification: VerificationPolicy = .sha256, outputName: String? = nil,
                     allowMissingDestination: Bool = false, scope: CopyScope = .all) -> TransferPlan {
        let fm = FileManager.default
        var src = source.canonical
        // A not-yet-created destination is fine when its parent exists (it is created when the copy starts).
        let destMissing = allowMissingDestination && !fm.fileExists(atPath: destinationRoot.path)
        let destRoot = destMissing ? destinationRoot.deletingLastPathComponent().canonical.appendingPathComponent(destinationRoot.lastPathComponent) : destinationRoot.canonical
        let destProbe = destMissing ? destRoot.deletingLastPathComponent() : destRoot
        // A single file is copied straight into the destination folder.
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: src.path, isDirectory: &isFolder), !isFolder.boolValue {
            return filePlan(name: name, file: src, destinationRoot: destRoot, mode: mode, policy: policy, freeSpace: freeSpace, verification: verification, probe: destProbe, scope: scope)
        }
        src = src.canonical
        let srcVol = Volumes.identity(of: src)
        let dstVol = Volumes.identity(of: destProbe)
        let defaultName = src.path == "/" ? (srcVol?.name ?? "Source") : src.lastPathComponent
        let folderName = (outputName?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "/", with: "-") } ?? defaultName
        let output = destRoot.appendingPathComponent(folderName, isDirectory: true)

        var job = TransferJob(name: name, mode: mode, filter: mode == .selectiveCopy ? filter : nil, conflictPolicy: policy,
                              sourcePath: src.path, sourceVolume: srcVol, destinationRoot: destRoot.path,
                              outputPath: output.path, destinationVolume: dstVol)
        job.scope = scope == .all ? nil : scope
        var issues: [PreflightIssue] = []
        // Camera originals are always checksum-verified; the faster policy is only for selective copies.
        job.verification = mode == .cameraCardBackup ? .sha256 : verification
        if job.verification == .sizeOnly {
            issues.append(.init(level: .warn, message: "Size-only verification: files will be reported as copied, not verified."))
        }
        var items: [TransferItem] = [], excluded: [TransferItem] = [], links: [String] = [], dirs: [String] = []
        var included: [MediaCategory: CategoryTotal] = [:]

        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: src.path, isDirectory: &isDir) || !isDir.boolValue {
            issues.append(.init(level: .block, message: "Source folder is not available: \(src.path)"))
        }
        if !fm.fileExists(atPath: destProbe.path, isDirectory: &isDir) || !isDir.boolValue {
            issues.append(.init(level: .block, message: "Destination folder is not available: \(destRoot.path)"))
        }

        // Recursion and overlap: never copy a folder into itself or over its own source.
        let s = src.path.hasSuffix("/") ? src.path : src.path + "/"
        let o = output.path + "/"
        if o.hasPrefix(s) || s.hasPrefix(o) {
            issues.append(.init(level: .block, message: "Source and destination overlap. Choose a destination outside \(src.path)."))
        }

        if !issues.contains(where: { $0.level == .block }) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
            let e = fm.enumerator(at: src, includingPropertiesForKeys: keys, options: [], errorHandler: { url, err in
                issues.append(.init(level: .warn, message: "Cannot read \(url.path): \(err.localizedDescription)")); return true
            })
            while let url = e?.nextObject() as? URL {
                let v = try? url.resourceValues(forKeys: Set(keys))
                let rel = url.path.hasPrefix(s) ? String(url.path.dropFirst(s.count)) : String(url.canonical.path.dropFirst(s.count))
                if v?.isSymbolicLink == true { links.append(rel); continue }
                if v?.isDirectory == true {
                    // Hidden folders (e.g. .Spotlight-V100, .Trashes) are system metadata, not camera data.
                    if url.lastPathComponent.hasPrefix(".") && (mode == .selectiveCopy || isSystemFolder(url.lastPathComponent)) {
                        e?.skipDescendants(); continue
                    }
                    dirs.append(rel); continue
                }
                guard v?.isRegularFile == true else { continue }
                if mode == .cameraCardBackup && [".DS_Store"].contains(url.lastPathComponent) { continue }
                if let only, !only.contains(rel) { continue }
                let item = TransferItem(relativePath: rel, bytes: Int64(v?.fileSize ?? 0))
                if mode == .cameraCardBackup || (filter ?? SelectiveFilter()).includes(url) {
                    items.append(item)
                    included[MediaCategory.of(url), default: CategoryTotal()].count += 1
                    included[MediaCategory.of(url), default: CategoryTotal()].bytes += item.bytes
                } else {
                    excluded.append(item)
                }
            }
        }

        job.totalFiles = items.count
        job.scannedFiles = items.count + excluded.count + links.count
        job.totalBytes = items.reduce(0) { $0 + $1.bytes }
        job.directories = mode == .cameraCardBackup ? dirs : []

        if !issues.contains(where: { $0.level == .block }) && items.isEmpty { issues.append(.init(level: .block, message: "No files match. Nothing to copy.")) }
        if !links.isEmpty {
            issues.append(.init(level: .warn, message: "\(links.count) symbolic link(s) will not be followed or copied, e.g. \(links.prefix(3).joined(separator: ", "))."))
        }
        if let d = dstVol {
            if d.isReadOnly { issues.append(.init(level: .block, message: "Destination volume \(d.name) is read-only.")) }
            if !d.isLocal { issues.append(.init(level: .warn, message: "Destination is a network volume. Speed and atomic renames depend on the server.")) }
            if let max = d.maxFileSize, let big = items.first(where: { $0.bytes > max }) {
                issues.append(.init(level: .block, message: "\(big.relativePath) (\(big.bytes.bytesText)) exceeds the 4 GB file limit of \(d.name) (\(d.fileSystem)). Use an exFAT or APFS destination."))
            }
            if !d.caseSensitive {
                var seen: [String: String] = [:]
                for i in items {
                    let k = i.relativePath.collisionKey
                    if let other = seen[k], other != i.relativePath {
                        issues.append(.init(level: .warn, message: "\"\(i.relativePath)\" and \"\(other)\" collide on a case-insensitive destination. The second one will be kept under a new name."))
                    }
                    seen[k] = i.relativePath
                }
            }
        }
        if fm.fileExists(atPath: destProbe.path) && !fm.isWritableFile(atPath: destProbe.path) {
            issues.append(.init(level: .block, message: "No write permission for \(destRoot.path)."))
        }
        let free = freeSpace?(destRoot) ?? dstVol?.available
        if let free {
            let needed = Int64(Double(job.totalBytes) * 1.05) + 50_000_000
            if needed > free {
                issues.append(.init(level: .block, message: "Not enough space: needs \(needed.bytesText) including 5% headroom, \(free.bytesText) free on destination."))
            } else if let cap = dstVol?.capacity, cap > 0, free - job.totalBytes < cap / 10 {
                issues.append(.init(level: .warn, message: "The destination will be nearly full after this copy (\((free - job.totalBytes).bytesText) left)."))
            }
        }
        if fm.fileExists(atPath: output.path) {
            issues.append(.init(level: .warn, message: "\(output.lastPathComponent) already exists at the destination. Existing files follow the conflict rule: \(policy.label)."))
        }
        if mode == .selectiveCopy {
            for w in CameraPackages.warnings(for: items, excluded: excluded) { issues.append(.init(level: .warn, message: w)) }
        }
        job.warnings = issues.filter { $0.level == .warn }.map(\.message)
        var plan = TransferPlan(job: job, items: items, excluded: excluded, included: included, skippedLinks: links, issues: issues)
        plan.conflicts = items.map(\.relativePath).filter { fm.fileExists(atPath: output.appendingPathComponent($0).path) }
        // Scope analysis: one stat per conflicting file, so the review screen can say what will really be copied.
        if scope != .all && !plan.conflicts.isEmpty {
            var sameSet: Set<String> = [], diff = 0
            for i in items where plan.conflicts.contains(i.relativePath) {
                let a = try? fm.attributesOfItem(atPath: output.appendingPathComponent(i.relativePath).path)
                if (a?[.size] as? NSNumber)?.int64Value == i.bytes { sameSet.insert(i.relativePath) } else { diff += 1 }
            }
            plan.presentSame = sameSet.count
            plan.presentDiff = diff
            // missingOnly: every existing file stays. continueCopy: same-size files are checked against
            // the source at copy time, so only the size-differing ones are counted as sure work.
            plan.copyBytes = items.reduce(Int64(0)) { sum, i in
                guard plan.conflicts.contains(i.relativePath) else { return sum + i.bytes }
                if scope == .missingOnly { return sum }
                return sameSet.contains(i.relativePath) ? sum : sum + i.bytes
            }
        }
        return plan
    }

    /// Plan for one file: copied into the destination folder itself.
    static func filePlan(name: String, file: URL, destinationRoot: URL, mode: TransferMode, policy: ConflictPolicy,
                         freeSpace: ((URL) -> Int64?)?, verification: VerificationPolicy, probe: URL? = nil,
                         scope: CopyScope = .all) -> TransferPlan {
        let probe = probe ?? destinationRoot
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        var job = TransferJob(name: name, mode: mode, conflictPolicy: policy, sourcePath: dir.path, sourceVolume: Volumes.identity(of: dir),
                              destinationRoot: destinationRoot.path, outputPath: destinationRoot.path, destinationVolume: Volumes.identity(of: probe))
        job.scope = scope == .all ? nil : scope
        job.verification = mode == .cameraCardBackup ? .sha256 : verification
        let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = TransferItem(relativePath: file.lastPathComponent, bytes: bytes)
        job.totalFiles = 1; job.scannedFiles = 1; job.totalBytes = bytes
        var issues: [PreflightIssue] = []
        if dir.path == destinationRoot.path { issues.append(.init(level: .block, message: "The file is already in this folder. Choose another destination.")) }
        if !fm.isWritableFile(atPath: probe.path) { issues.append(.init(level: .block, message: "No write permission for \(destinationRoot.path).")) }
        if let d = job.destinationVolume {
            if d.isReadOnly { issues.append(.init(level: .block, message: "Destination volume \(d.name) is read-only.")) }
            if let max = d.maxFileSize, bytes > max { issues.append(.init(level: .block, message: "\(file.lastPathComponent) exceeds the 4 GB limit of \(d.name).")) }
        }
        if let free = freeSpace?(probe) ?? job.destinationVolume?.available, Int64(Double(bytes) * 1.05) + 50_000_000 > free {
            issues.append(.init(level: .block, message: "Not enough space on the destination."))
        }
        var cat: [MediaCategory: CategoryTotal] = [:]
        cat[MediaCategory.of(file)] = CategoryTotal(count: 1, bytes: bytes)
        var p = TransferPlan(job: job, items: [item], excluded: [], included: cat, skippedLinks: [], issues: issues)
        p.job.warnings = issues.filter { $0.level == .warn }.map(\.message)
        if fm.fileExists(atPath: destinationRoot.appendingPathComponent(item.relativePath).path) { p.conflicts = [item.relativePath] }
        return p
    }

    /// Drops selected items already inside another selected folder, and duplicates, so nothing is copied twice.
    static func normalizeSources(_ urls: [URL]) -> [URL] {
        let canon = urls.map(\.canonical)
        var out: [URL] = []
        for (i, u) in canon.enumerated() {
            if out.contains(where: { $0.path == u.path }) { continue }
            let insideAnother = canon.enumerated().contains { j, other in
                j != i && other.path != u.path && u.path.hasPrefix(other.path.hasSuffix("/") ? other.path : other.path + "/")
            }
            if !insideAnother { out.append(u) }
        }
        return out
    }

    /// Two jobs must not run against each other: same output folder, or one writing inside the other's source.
    static func overlaps(_ a: TransferJob, _ b: TransferJob) -> Bool {
        func inside(_ x: String, _ y: String) -> Bool { x == y || x.hasPrefix(y.hasSuffix("/") ? y : y + "/") }
        return inside(a.outputPath, b.outputPath) || inside(b.outputPath, a.outputPath)
            || inside(a.outputPath, b.sourcePath) || inside(b.outputPath, a.sourcePath)
    }

    /// Remaining (not yet verified) files of `job`, re-planned onto another destination, e.g. after "destination full".
    static func continuation(of job: TransferJob, remaining: [TransferItem], to newRoot: URL, freeSpace: ((URL) -> Int64?)? = nil) -> TransferPlan {
        let source = job.sourceVolume.flatMap { Volumes.remap(job.sourcePath, from: $0) } ?? job.sourcePath
        var p = plan(name: job.name + " (continued)", source: URL(fileURLWithPath: source), destinationRoot: newRoot, mode: job.mode,
                     filter: job.filter, policy: job.conflictPolicy, freeSpace: freeSpace, only: Set(remaining.map(\.relativePath)),
                     verification: job.verification ?? .sha256)
        let overrides = Dictionary(remaining.map { ($0.relativePath, $0.policy) }, uniquingKeysWith: { a, _ in a })
        for i in p.items.indices { p.items[i].policy = overrides[p.items[i].relativePath] ?? nil }
        return p
    }

    static func isSystemFolder(_ name: String) -> Bool {
        [".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100"].contains(name)
    }
}

final class TransferRunner {
    let db: Database
    let paths: AppPaths
    /// Test hook: called with the temp file after writing and before verification.
    var afterWrite: ((URL) -> Void)?

    init(db: Database, paths: AppPaths) { self.db = db; self.paths = paths }

    func saveNew(_ plan: TransferPlan) throws {
        try db.transaction {
            try db.save("job", id: plan.job.id.uuidString, plan.job)
            for i in plan.items { try db.save("titem", id: plan.job.id.uuidString + "|" + i.relativePath, parent: plan.job.id.uuidString, i) }
        }
    }

    func items(_ jobID: UUID) -> [TransferItem] { db.all("titem", parent: jobID.uuidString) }

    /// Controlled retry: failed files go back to pending; verified files stay. Returns the number reset.
    @discardableResult
    func resetFailed(_ job: TransferJob) throws -> Int {
        var n = 0
        try db.transaction {
            for var i in items(job.id) where i.state == .failed || i.state == .unverified {
                i.state = .pending; i.message = (i.message.map { "Retried after: " + $0 })
                try db.save("titem", id: job.id.uuidString + "|" + i.relativePath, parent: job.id.uuidString, i)
                n += 1
            }
            var j = job; j.status = .planned; j.finished = nil
            try db.save("job", id: j.id.uuidString, j)
        }
        return n
    }

    /// Before resuming: both volumes must be the same devices as recorded. Returns current paths or a reason.
    func revalidate(_ job: TransferJob) -> Result<(source: String, output: String), Reason> {
        guard let sv = job.sourceVolume, let dv = job.destinationVolume else { return .failure(Reason("Volume identity was not recorded.")) }
        guard let src = Volumes.remap(job.sourcePath, from: sv) else {
            return .failure(Reason("Source drive \(sv.name) (\(sv.shortID)) is not connected. A different drive with the same name is not accepted."))
        }
        guard let out = Volumes.remap(job.outputPath, from: dv) else {
            return .failure(Reason("Destination drive \(dv.name) (\(dv.shortID)) is not connected."))
        }
        return .success((src, out))
    }

    /// Runs (or resumes) a job. Completed items are not copied again.
    /// Removes the app's record of a finished job (history, manifest). Copied media is not touched.
    /// "Check again": re-reads every copied file and compares it with the checksum taken from the source at copy time.
    func recheck(_ job: TransferJob, progress: (Int, Int) -> Void = { _, _ in }) -> (ok: Int, changed: [String], missing: [String]) {
        let out = URL(fileURLWithPath: job.outputPath)
        let done = items(job.id).filter { $0.state.isDone && $0.sourceHash != nil }
        var ok = 0, changed: [String] = [], missing: [String] = []
        for (i, it) in done.enumerated() {
            let u = out.appendingPathComponent(it.destinationRelativePath ?? it.relativePath)
            if !FileManager.default.fileExists(atPath: u.path) { missing.append(it.relativePath) }
            else if (try? Hashing.sha256(u)) == it.sourceHash { ok += 1 }
            else { changed.append(it.relativePath) }
            progress(i + 1, done.count)
        }
        return (ok, changed, missing)
    }

    func deleteRecord(_ job: TransferJob) throws {
        try db.deleteChildren("titem", parent: job.id.uuidString)
        try db.delete("job", id: job.id.uuidString)
        for ext in ["json", "csv"] { try? FileManager.default.removeItem(at: paths.manifests.appendingPathComponent("\(job.id.uuidString).\(ext)")) }
    }

    func run(_ jobIn: TransferJob, progress: @escaping (TransferJob) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false },
             activity: @escaping (String, String) -> Void = { _, _ in }) -> TransferJob {
        var job = jobIn
        let fm = FileManager.default
        let srcRoot: URL, outRoot: URL
        switch revalidate(job) {
        case .failure(let reason):
            job.status = .interrupted
            job.warnings.append(reason.description)
            persist(job); return job
        case .success(let p):
            srcRoot = URL(fileURLWithPath: p.source); outRoot = URL(fileURLWithPath: p.output)
        }

        let sleepGuard = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Copying media: \(job.name)")
        defer { ProcessInfo.processInfo.endActivity(sleepGuard) }

        job.status = .running
        job.started = job.started ?? Date()
        persist(job)
        do {
            try fm.createDirectory(at: outRoot, withIntermediateDirectories: true)
            for d in job.directories { try fm.createDirectory(at: outRoot.appendingPathComponent(d), withIntermediateDirectories: true) }
        } catch {
            job.status = .failed; job.warnings.append("Cannot create destination folders: \(error.localizedDescription)")
            persist(job); return job
        }

        var items = self.items(job.id)
        job.copiedBytes = items.filter { $0.state.isDone }.reduce(0) { $0 + $1.bytes }
        job.doneFiles = items.filter { $0.state.isDone }.count
        var stopReason: String?
        var lastProgress = Date.distantPast
        for idx in items.indices where !items[idx].state.isDone {
            if isCancelled() { job.status = .paused; break }
            // Per-file autorelease pool: chunk buffers from thousands of files must not pile up.
            var doneState: ItemState = .pending
            autoreleasepool {
                var item = items[idx]
                item.state = .copying
                item = copy(item, srcRoot: srcRoot, outRoot: outRoot, policy: item.policy ?? job.conflictPolicy, sizeOnly: job.verification == .sizeOnly, job: &job, isCancelled: isCancelled, activity: activity)
                items[idx] = item
                doneState = item.state
                try? db.save("titem", id: job.id.uuidString + "|" + item.relativePath, parent: job.id.uuidString, item)
                if item.state.isDone { job.copiedBytes += item.bytes; job.doneFiles = (job.doneFiles ?? 0) + 1 }
            }
            // The UI does not need every chunk's update: 4/s plus one at each finished file.
            if Date().timeIntervalSince(lastProgress) > 0.25 || doneState.isDone || doneState == .failed { lastProgress = Date(); progress(job) }
            if doneState == .failed || doneState == .pending {
                let item = items[idx]
                if !fm.fileExists(atPath: srcRoot.path) || Volumes.find(job.sourceVolume!) == nil { stopReason = "Source drive disconnected."; break }
                if Volumes.find(job.destinationVolume!) == nil { stopReason = "Destination drive disconnected."; break }
                if item.message?.contains("No space") == true || item.message?.contains("ENOSPC") == true { stopReason = "Destination is full."; break }
                if doneState == .pending { job.status = .paused; break } // cancelled mid-file
            }
        }

        if let stopReason {
            job.status = .interrupted
            job.warnings.append(stopReason)
        } else if job.status != .paused {
            let done = items.filter { $0.state.isDone }.count
            let failed = items.filter { $0.state == .failed || $0.state == .unverified }.count
            let sizeOnly = items.contains { $0.state == .copiedUnverified }
            // An empty job proves nothing: never report it as verified.
            job.status = items.isEmpty ? .failed : (failed == 0 && done == items.count ? (sizeOnly ? .copiedUnverified : .verified) : (done == 0 ? .failed : .partiallyVerified))
            if items.isEmpty { job.warnings.append("No files were recorded for this job.") }
            job.finished = Date()
        }
        job.manifestPath = try? writeManifest(job, items)
        persist(job)
        progress(job)
        return job
    }

    private func persist(_ job: TransferJob) { try? db.save("job", id: job.id.uuidString, job) }

    private func copy(_ itemIn: TransferItem, srcRoot: URL, outRoot: URL, policy: ConflictPolicy, sizeOnly: Bool = false, job: inout TransferJob,
                      isCancelled: () -> Bool, activity: (String, String) -> Void = { _, _ in }) -> TransferItem {
        var item = itemIn
        let fm = FileManager.default
        let src = srcRoot.appendingPathComponent(item.relativePath)
        var dst = outRoot.appendingPathComponent(item.relativePath)
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) {
                let srcSize = (try? fm.attributesOfItem(atPath: src.path))?[.size] as? NSNumber
                let dstSize = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber
                let sameSize = srcSize != nil && srcSize == dstSize
                let scope = job.scope ?? .all
                if scope == .missingOnly {
                    item.state = .skippedExisting; item.destinationRelativePath = item.relativePath
                    item.message = "Already at the destination; only missing files are copied."
                    return item
                }
                var sh: String?, dh: String?
                // Content is only worth hashing when the sizes match: different sizes can never be identical.
                if sameSize && (scope == .continueCopy || policy == .skipIdenticalElseKeepBoth) {
                    sh = try Hashing.sha256(src); dh = try Hashing.sha256(dst)
                    if sh == dh {
                        item.state = .skippedIdentical; item.sourceHash = sh; item.destinationHash = dh
                        item.destinationRelativePath = item.relativePath
                        item.message = "Identical file already at the destination; skipped."
                        return item
                    }
                }
                switch policy {
                case .skipIdenticalElseKeepBoth:
                    // Sizes differ (or content differs after the hash above): keep both under a new name.
                    dst = Self.uniqueName(for: dst)
                case .keepBoth:
                    dst = Self.uniqueName(for: dst)
                case .skipExisting:
                    item.state = .skippedExisting; item.destinationRelativePath = item.relativePath
                    item.message = "Existing file kept; not copied."
                    return item
                case .replace:
                    break
                }
            }
            let temp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).ewpart")
            try? fm.removeItem(at: temp) // our own leftover from an interrupted run
            func stamp() -> (Int64, Date?) {
                let a = try? fm.attributesOfItem(atPath: src.path)
                return ((a?[.size] as? NSNumber)?.int64Value ?? -1, a?[.modificationDate] as? Date)
            }
            let before = stamp()
            activity(item.relativePath, "Copying")
            let srcHash = try streamCopy(from: src, to: temp, isCancelled: isCancelled)
            guard let srcHash else { try? fm.removeItem(at: temp); item.state = .pending; return item }
            afterWrite?(temp)
            // The camera or another app changed the file while it was read: the copy is not a faithful snapshot.
            if stamp() != before {
                try? fm.removeItem(at: temp)
                item.state = .failed
                item.message = "Source changed during copy; retry when it is stable."
                return item
            }
            activity(item.relativePath, "Verifying")
            if sizeOnly {
                let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard size == item.bytes else {
                    try? fm.removeItem(at: temp); item.state = .failed
                    item.message = "Size mismatch: expected \(item.bytes) bytes, wrote \(size). Source untouched."
                    return item
                }
                item.sourceHash = srcHash
                preserveMetadata(from: src, to: temp, job: &job, rel: item.relativePath)
                dst = try finalize(temp: temp, final: dst, overwrite: policy == .replace)
                item.destinationRelativePath = String(dst.path.dropFirst(outRoot.path.count + 1))
                item.state = .copiedUnverified
                item.message = "Size matched; destination not checksum-verified (size-only policy)."
                return item
            }
            let dstHash = try Hashing.sha256(temp)
            item.sourceHash = srcHash; item.destinationHash = dstHash
            guard srcHash == dstHash else {
                try? fm.removeItem(at: temp)
                item.state = .failed
                item.message = "Checksum mismatch: source \(srcHash.prefix(12))… destination \(dstHash.prefix(12))…. Not verified; source untouched."
                return item
            }
            preserveMetadata(from: src, to: temp, job: &job, rel: item.relativePath)
            dst = try finalize(temp: temp, final: dst, overwrite: policy == .replace)
            item.destinationRelativePath = String(dst.path.dropFirst(outRoot.path.count + 1))
            item.state = .verified
            if item.destinationRelativePath != item.relativePath { item.message = "Saved as \(dst.lastPathComponent) (name conflict)." }
        } catch {
            item.state = .failed
            item.message = (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOSPC)
                ? "No space left on destination." : error.localizedDescription
        }
        return item
    }

    /// Streams src to dst while hashing. Returns nil if cancelled.
    private func streamCopy(from src: URL, to dst: URL, isCancelled: () -> Bool) throws -> String? {
        let fd = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Cannot create \(dst.path): \(String(cString: strerror(errno)))"])
        }
        let r = try FileHandle(forReadingFrom: src), w = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? r.close(); try? w.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.int64Value ?? 0
        // Read ahead on another thread while this one hashes and writes: card reads and disk writes overlap.
        let pipe = ChunkPipe(capacity: 4)
        let reader = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: reader) {
            do {
                while let d = try r.read(upToCount: Hashing.chunk), !d.isEmpty { if !pipe.put(d) { break } }
                pipe.finish(nil)
            } catch { pipe.finish(error) }
        }
        defer { pipe.stop(); reader.wait() }   // reader is done before the handles close
        var hasher = SHA256()
        while let d = try pipe.take() {
            if isCancelled() { return nil }
            hasher.update(data: d)
            try w.write(contentsOf: d)
        }
        // A full flush per file keeps camera originals safe, but on slow external drives F_FULLFSYNC
        // can cost seconds each time: only big files get it, small ones are fsync'd.
        if size >= 128 * 1024 * 1024 { _ = fcntl(w.fileDescriptor, F_FULLFSYNC) } else { fsync(w.fileDescriptor) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Atomic rename. Without `overwrite`, RENAME_EXCL guarantees an existing file is never replaced.
    private func finalize(temp: URL, final: URL, overwrite: Bool) throws -> URL {
        var target = final
        for _ in 0..<1000 {
            let rc = overwrite ? rename(temp.path, target.path) : renamex_np(temp.path, target.path, UInt32(RENAME_EXCL))
            if rc == 0 { return target }
            if errno == EEXIST && !overwrite { target = Self.uniqueName(for: target); continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Cannot finalize \(target.lastPathComponent): \(String(cString: strerror(errno)))"])
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSLocalizedDescriptionKey: "No free name for \(final.lastPathComponent)"])
    }

    private func preserveMetadata(from src: URL, to dst: URL, job: inout TransferJob, rel: String) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: src.path) else { return }
        var attrs: [FileAttributeKey: Any] = [:]
        for k in [FileAttributeKey.modificationDate, .creationDate, .posixPermissions] { if let v = a[k] { attrs[k] = v } }
        do { try FileManager.default.setAttributes(attrs, ofItemAtPath: dst.path) } catch {
            if job.metadataNotPreserved.count < 200 { job.metadataNotPreserved.append("\(rel): \(error.localizedDescription)") }
        }
    }

    static func uniqueName(for url: URL) -> URL {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        // A trailing number is a camera or file counter: continue the sequence (23879 → 23880, 23881…).
        if let m = base.range(of: #"\d+$"#, options: .regularExpression) {
            let digits = String(base[m]), prefix = String(base[..<m.lowerBound])
            var n = Int(digits) ?? 0
            let pad = digits.count
            for _ in 0..<100_000 {
                n += 1
                let num = pad > 1 ? String(format: "%0\(pad)d", n) : String(n)
                let c = dir.appendingPathComponent(ext.isEmpty ? "\(prefix)\(num)" : "\(prefix)\(num).\(ext)")
                if !fm.fileExists(atPath: c.path) { return c }
            }
        }
        for n in 2... {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: c.path) { return c }
        }
        return url
    }

    /// JSON + CSV manifest in app storage. Returns the JSON path.
    func writeManifest(_ job: TransferJob, _ items: [TransferItem]) throws -> String {
        try FileManager.default.createDirectory(at: paths.manifests, withIntermediateDirectories: true)
        let base = paths.manifests.appendingPathComponent("\(job.id.uuidString)")
        struct Manifest: Encodable { var job: TransferJob; var items: [TransferItem] }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(Manifest(job: job, items: items)).write(to: base.appendingPathExtension("json"))
        // RFC 4180: quote fields that contain a comma, quote or line break. Newlines must not split rows.
        func q(_ s: String?) -> String {
            let v = s ?? ""
            return v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : v
        }
        var csv = "relative_path,bytes,state,destination_path,source_sha256,destination_sha256,message\n"
        for i in items {
            csv += [q(i.relativePath), String(i.bytes), i.state.rawValue, q(i.destinationRelativePath), i.sourceHash ?? "", i.destinationHash ?? "", q(i.message)].joined(separator: ",") + "\n"
        }
        try csv.write(to: base.appendingPathExtension("csv"), atomically: false, encoding: .utf8)
        return base.appendingPathExtension("json").path
    }
}


/// Bounded hand-off between the reading thread and the writing thread (at most `capacity` chunks in memory).
final class ChunkPipe: @unchecked Sendable {
    private let cond = NSCondition()
    private var buffer: [Data] = []
    private var finished = false, stopped = false
    private var failure: Error?
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }

    /// Blocks while full. Returns false once the consumer stopped.
    func put(_ d: Data) -> Bool {
        cond.lock(); defer { cond.unlock() }
        while buffer.count >= capacity && !stopped { cond.wait() }
        if stopped { return false }
        buffer.append(d); cond.broadcast()
        return true
    }
    func finish(_ error: Error?) { cond.lock(); finished = true; failure = error; cond.broadcast(); cond.unlock() }
    func stop() { cond.lock(); stopped = true; cond.broadcast(); cond.unlock() }
    /// Next chunk in order; nil at the end; rethrows a read error.
    func take() throws -> Data? {
        cond.lock(); defer { cond.unlock() }
        while buffer.isEmpty && !finished { cond.wait() }
        if !buffer.isEmpty { let d = buffer.removeFirst(); cond.broadcast(); return d }
        if let failure { throw failure }
        return nil
    }
}
