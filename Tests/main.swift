import Foundation

// Assert-based self-tests mapped to the spec's acceptance criteria (p.18).
// Run with scripts/test.sh. Set EW_BIG=1 to include the >4 GiB file test.

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0, passed = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passed += 1 } else { failures += 1; print("  FAIL (line \(line)): \(msg)") }
}
func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { failures += 1; print("  FAIL: threw \(error)") }
}

let fm = FileManager.default
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ew-tests-\(UUID().uuidString.prefix(8))")
try fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }

func write(_ url: URL, _ s: String) { try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try? s.write(to: url, atomically: false, encoding: .utf8) }
func freshEnv(_ tag: String) throws -> (Database, AppPaths, URL) {
    let root = base.appendingPathComponent(tag)
    let paths = AppPaths(root: root.appendingPathComponent("support"))
    try paths.create()
    return (try Database(path: paths.database.path), paths, root)
}

/// A fake camera card: Sony-like structure, hidden files, sidecars, empty folder.
func makeCard(_ root: URL) -> URL {
    let card = root.appendingPathComponent("CARD")
    write(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), String(repeating: "video-1 ", count: 5000))
    write(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001M01.XML"), "<meta/>")
    write(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002.MP4"), String(repeating: "video-2 ", count: 7000))
    write(card.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML"), "<pro/>")
    write(card.appendingPathComponent("DCIM/100MSDCF/DSC0001.JPG"), "jpeg")
    write(card.appendingPathComponent(".hiddenCameraIndex"), "idx")
    write(card.appendingPathComponent("AUDIO/ZOOM0001.WAV"), String(repeating: "a", count: 3000))
    try? fm.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL"), withIntermediateDirectories: true)
    return card
}

// MARK: Backup integrity

test("Camera Card Backup copies everything and every file verifies") {
    let (db, paths, root) = try freshEnv("backup")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .skipIdenticalElseKeepBoth)
    check(plan.canStart, "plan should start: \(plan.issues)")
    check(plan.items.count == 7, "all 7 files incl. hidden + sidecars, got \(plan.items.count)")
    let runner = TransferRunner(db: db, paths: paths)
    try runner.saveNew(plan)
    let job = runner.run(plan.job)
    check(job.status == .verified, "status verified, got \(job.status) \(job.warnings)")
    let items = runner.items(job.id)
    check(items.allSatisfy { $0.state == .verified && $0.sourceHash == $0.destinationHash && $0.sourceHash != nil }, "every item hash-verified: \(items.compactMap(\.message).prefix(2))")
    for i in items {
        let d = dest.appendingPathComponent("CARD").appendingPathComponent(i.relativePath)
        check((try? Hashing.sha256(d)) == i.sourceHash, "destination file matches manifest: \(i.relativePath)")
    }
    check(fm.fileExists(atPath: dest.appendingPathComponent("CARD/PRIVATE/M4ROOT/THMBNL").path), "empty camera folder preserved")
    let csv = (try? String(contentsOfFile: job.manifestPath!.replacingOccurrences(of: ".json", with: ".csv"), encoding: .utf8)) ?? ""
    check(csv.split(separator: "\n").count == 8, "CSV manifest lists every file")
    check(!((try? fm.contentsOfDirectory(atPath: dest.appendingPathComponent("CARD/PRIVATE/M4ROOT/CLIP").path)) ?? ["missing.ewpart"]).contains { $0.hasSuffix(".ewpart") }, "no temp files left")
}

test("Check again finds a changed and a missing copy") {
    let (db, paths, root) = try freshEnv("recheck")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    let runner = TransferRunner(db: db, paths: paths)
    try runner.saveNew(plan)
    let job = runner.run(plan.job)
    let first = runner.recheck(job)
    check(first.ok == 7 && first.changed.isEmpty && first.missing.isEmpty, "fresh copy rechecks clean: \(first)")
    let items = runner.items(job.id)
    try Data("tampered".utf8).write(to: URL(fileURLWithPath: job.outputPath).appendingPathComponent(items[0].relativePath))
    try fm.removeItem(at: URL(fileURLWithPath: job.outputPath).appendingPathComponent(items[1].relativePath))
    let second = runner.recheck(job)
    check(second.ok == 5 && second.changed == [items[0].relativePath] && second.missing == [items[1].relativePath], "changed and missing reported: \(second)")
}

test("Checksum mismatch is never reported as verified, source untouched") {
    let (db, paths, root) = try freshEnv("mismatch")
    let card = makeCard(root)
    let before = try Hashing.sha256(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"))
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    let runner = TransferRunner(db: db, paths: paths)
    runner.afterWrite = { url in if url.lastPathComponent.contains("C0001.MP4") { try? "corrupt".write(to: url, atomically: false, encoding: .utf8) } }
    try runner.saveNew(plan)
    let job = runner.run(plan.job)
    check(job.status == .partiallyVerified, "partially verified, got \(job.status)")
    let bad = runner.items(job.id).first { $0.relativePath.hasSuffix("C0001.MP4") }!
    check(bad.state == .failed && bad.message?.contains("Checksum mismatch") == true, "item failed with mismatch evidence")
    check(!fm.fileExists(atPath: dest.appendingPathComponent("CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4").path), "corrupt file not finalized")
    check((try? Hashing.sha256(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"))) == before, "source unchanged")
}

// MARK: Copy scope (continue / sync missing)

test("Continue skips files already copied; missing-only copies only what is absent") {
    let (db, paths, root) = try freshEnv("scope")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)

    // 1) Full copy first.
    let first = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, outputName: "CARD")
    try runner.saveNew(first)
    let job1 = runner.run(first.job)
    check(job1.status == .verified, "baseline copy verified, got \(job1.status)")

    // 2) Continue over the same destination: everything identical is skipped, nothing is copied.
    let again = TransferPlanner.plan(name: "again", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, outputName: "CARD", scope: .continueCopy)
    check(again.job.scope == .continueCopy, "scope is stored on the job")
    check(again.conflicts.count == 7 && again.presentSame == 7 && again.presentDiff == 0, "analysis: 7 present, same size: s\(again.presentSame) d\(again.presentDiff)")
    check(again.copyBytes == 0, "continue estimates 0 bytes to copy, got \(again.copyBytes as Any)")
    try runner.saveNew(again)
    let job2 = runner.run(again.job)
    check(job2.status == .verified, "continue run finished, got \(job2.status) \(job2.warnings)")
    check(runner.items(job2.id).allSatisfy { $0.state == .skippedIdentical }, "every file skipped as identical: \(runner.items(job2.id).map { "\($0.relativePath):\($0.state)" }.prefix(3))")

    // 3) Missing-only: delete one file, truncate another. Only the missing one is copied.
    let out = URL(fileURLWithPath: first.job.outputPath)
    try fm.removeItem(at: out.appendingPathComponent("AUDIO/ZOOM0001.WAV"))
    try Data("short".utf8).write(to: out.appendingPathComponent("DCIM/100MSDCF/DSC0001.JPG"))
    let sync = TransferPlanner.plan(name: "sync", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, outputName: "CARD", scope: .missingOnly)
    check(sync.conflicts.count == 6 && sync.presentSame == 5 && sync.presentDiff == 1, "6 existing (5 same size, 1 differs): c\(sync.conflicts.count) s\(sync.presentSame) d\(sync.presentDiff)")
    check(sync.copyBytes == 3000, "only the deleted WAV (3000 bytes) to copy, got \(sync.copyBytes as Any)")
    try runner.saveNew(sync)
    let job3 = runner.run(sync.job)
    check(job3.status == .verified, "sync run finished, got \(job3.status) \(job3.warnings)")
    let items3 = runner.items(job3.id)
    let wav = items3.first { $0.relativePath.hasSuffix("ZOOM0001.WAV") }
    let jpg = items3.first { $0.relativePath.hasSuffix("DSC0001.JPG") }
    check(wav?.state == .verified && fm.fileExists(atPath: out.appendingPathComponent("AUDIO/ZOOM0001.WAV").path), "missing file was copied and verified")
    check(jpg?.state == .skippedExisting, "differing file kept, not overwritten: \(jpg?.state as Any)")
    check((try? String(contentsOf: out.appendingPathComponent("DCIM/100MSDCF/DSC0001.JPG"), encoding: .utf8)) == "short", "destination content untouched")
    check(items3.filter { $0.state == .skippedExisting }.count == 6, "6 pre-existing files skipped: \(items3.filter { $0.state == .skippedExisting }.count)")
}

// MARK: Media filtering

test("Selective copy lists included/excluded files and warns about camera packages") {
    let (_, _, root) = try freshEnv("selective")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    var f = SelectiveFilter(); f.categories = [.video]
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .selectiveCopy, filter: f, policy: .keepBoth)
    check(Set(plan.items.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }) == ["C0001.MP4", "C0002.MP4"], "only video included: \(plan.items.map(\.relativePath))")
    check(plan.excluded.count == 5, "5 excluded incl. hidden index: \(plan.excluded.map(\.relativePath))")
    check(plan.issues.contains { $0.message.contains("Camera structure detected") }, "camera structure warning")
    check(plan.issues.contains { $0.message.contains("companions") }, "companion file warning (C0001M01.XML)")
    check(plan.included[.video]?.count == 2, "category preview counts")
}

// MARK: Safety preflight

test("Recursive / overlapping destination is blocked") {
    let (_, _, root) = try freshEnv("recursive")
    let card = makeCard(root)
    let p1 = TransferPlanner.plan(name: "t", source: card, destinationRoot: card, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    check(!p1.canStart && p1.issues.contains { $0.message.contains("overlap") }, "source as own destination blocked")
    let p2 = TransferPlanner.plan(name: "t", source: card, destinationRoot: card.appendingPathComponent("DCIM"), mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    check(!p2.canStart, "destination inside source blocked")
    let p3 = TransferPlanner.plan(name: "t", source: card, destinationRoot: root, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    check(!p3.canStart, "output folder equal to source blocked")
}

test("Low free space blocks the transfer before copying") {
    let (_, _, root) = try freshEnv("space")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, freeSpace: { _ in 1000 })
    check(!plan.canStart && plan.issues.contains { $0.message.contains("Not enough space") }, "space block")
}

test("FAT32 4 GB limit and case collisions are reported") {
    var v = VolumeIdentity(uuid: "x", name: "CARD", mountPath: "/", capacity: 0, available: 0, fileSystem: "msdos", isInternal: false, isRemovable: true, isReadOnly: false, isLocal: true, caseSensitive: false)
    check(v.maxFileSize == 4_294_967_295, "msdos limit")
    v.fileSystem = "apfs"; check(v.maxFileSize == nil, "apfs no limit")
    check("Café".collisionKey == "Cafe\u{301}".collisionKey, "NFC normalization collision key")
    check("A.MOV".collisionKey == "a.mov".collisionKey, "case collision key")
}

// MARK: Duplicate handling

test("Existing names are never silently overwritten; identical files skipped") {
    let (db, paths, root) = try freshEnv("dupes")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD")
    let existing = dest.appendingPathComponent("CARD/AUDIO/ZOOM0001.WAV")
    write(existing, "USER'S DIFFERENT FILE")
    let runner = TransferRunner(db: db, paths: paths)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .skipIdenticalElseKeepBoth)
    try runner.saveNew(plan)
    let job = runner.run(plan.job)
    check(job.status == .verified, "verified \(job.status)")
    check((try? String(contentsOf: existing, encoding: .utf8)) == "USER'S DIFFERENT FILE", "user file untouched")
    let wav = runner.items(job.id).first { $0.relativePath.hasSuffix("ZOOM0001.WAV") }!
    check(wav.destinationRelativePath == "AUDIO/ZOOM0002.WAV" && wav.message != nil, "kept both, numbered like a camera counter: \(wav.destinationRelativePath ?? "")")

    let plan2 = TransferPlanner.plan(name: "t2", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .skipIdenticalElseKeepBoth)
    try runner.saveNew(plan2)
    let job2 = runner.run(plan2.job)
    let states = runner.items(job2.id).map(\.state)
    check(job2.status == .verified, "second run verified")
    check(states.filter { $0 == .skippedIdentical }.count == 6, "identical files skipped on re-run: \(states)")

    // A trailing counter continues instead of adding " (2)": 23879 → 23880.
    let numbered = root.appendingPathComponent("numbers/23879.MP4")
    write(numbered, "x")
    check(TransferRunner.uniqueName(for: numbered).lastPathComponent == "23880.MP4", "numeric counter continues")
    let padded = root.appendingPathComponent("numbers/C0001.MP4")
    write(padded, "x")
    check(TransferRunner.uniqueName(for: padded).lastPathComponent == "C0002.MP4", "zero padding kept")
    let plain = root.appendingPathComponent("numbers/Clip.MP4")
    write(plain, "x")
    check(TransferRunner.uniqueName(for: plain).lastPathComponent == "Clip (2).MP4", "no counter: parenthesised number")
}

// MARK: Interruption

test("Cancelled job is not complete; resume finishes; different drive refused") {
    let (db, paths, root) = try freshEnv("resume")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    try runner.saveNew(plan)
    var n = 0
    var job = runner.run(plan.job, progress: { _ in n += 1 }, isCancelled: { n >= 2 })
    check(job.status == .paused, "paused, not complete: \(job.status)")
    check(runner.items(job.id).contains { !$0.state.isDone }, "pending items remain")
    job = runner.run(job)
    check(job.status == .verified, "resumed to verified: \(job.status)")
    check(runner.items(job.id).allSatisfy { $0.state == .verified }, "no duplicate copies on resume")

    var fake = job
    fake.sourceVolume?.uuid = "SAME-NAME-DIFFERENT-CARD"
    if case .success = runner.revalidate(fake) { check(false, "different drive must be refused") } else { check(true, "") }
    fake.sourceVolume?.uuid = nil
    if case .success = runner.revalidate(fake) { check(false, "unidentifiable drive must be refused") } else { check(true, "") }
}

// MARK: Folder search

test("Two same-name folders on different roots show distinct paths") {
    let (_, _, root) = try freshEnv("search")
    let a = root.appendingPathComponent("Disk1/Clients/Mohan & Anbika"), b = root.appendingPathComponent("Disk2/Archive/Mohan & Anbika")
    try fm.createDirectory(at: a, withIntermediateDirectories: true); try fm.createDirectory(at: b, withIntermediateDirectories: true)
    let hits = FolderSearch.search("mohan & anbika", in: [root.appendingPathComponent("Disk1"), root.appendingPathComponent("Disk2")])
    check(hits.count == 2 && Set(hits.map(\.path)).count == 2, "two distinct hits: \(hits.map(\.path))")
    check(hits.allSatisfy { !$0.volumeName.isEmpty }, "volume shown")
}

// MARK: Templates

/// Minimal zip file (empty archive with one local header) standing in for a .drp when no fixture exists.
func fixtureDrp(_ root: URL) -> URL {
    let real = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spike/fixtures/master.drp")
    if fm.fileExists(atPath: real.path) { return real }
    let u = root.appendingPathComponent("master.drp")
    try? (Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 100)).write(to: u)
    return u
}

test("Master safety: 20 projects leave the master checksum unchanged") {
    let (db, paths, root) = try freshEnv("master")
    let store = TemplateStore(db: db, paths: paths)
    let projects = ProjectStore(db: db, templates: store)
    let drp = fixtureDrp(root)
    let srcHash = try Hashing.sha256(drp)
    let t = try store.importTemplate(from: drp, name: "Mehndi Long Video")
    check(t.current.masterHash == srcHash, "stored master hash equals original")
    let perms = (try fm.attributesOfItem(atPath: t.current.masterPath)[.posixPermissions] as? NSNumber)?.intValue
    check(perms == 0o444, "master is read-only")
    let dest = root.appendingPathComponent("Projects"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    var names = Set<String>()
    for _ in 0..<20 {
        let s = try projects.create(name: "Mohan & Anbika - Mehndi", template: store.get(t.id)!, destinationRoot: dest, createFolders: true, sources: [], mappings: [], settings: t.current.settings)
        names.insert(s.name)
        check(s.state == .manualStepRequired, "honest initial state")
        check(s.instanceDrpPath != t.current.masterPath, "distinct instance file")
    }
    check(names.count == 20, "20 unique project names")
    check(store.verifyMaster(store.get(t.id)!.current), "master checksum unchanged after 20 runs")
    check((try? Hashing.sha256(drp)) == srcHash, "original file untouched")
    check(throwsError { try TemplateStore.validate(root.appendingPathComponent("x.txt")) }, "non-drp rejected")
}

func throwsError(_ f: () throws -> Void) -> Bool { do { try f(); return false } catch { return true } }

test("Templates that ship in the app are imported once, keeping name and category") {
    // The maker's library: one template exported as a seed, like scripts/seed.sh does.
    let (db, paths, root) = try freshEnv("seed-src")
    let store = TemplateStore(db: db, paths: paths)
    let t = try store.importTemplate(from: fixtureDrp(root), name: "Seed Wedding", category: "Weddings", tags: ["wedding"])
    let dir = root.appendingPathComponent("bundle/templates")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let drp = try store.export(t.id, to: dir)
    let key = "seed-wedding"
    let manifest = SeedManifest(seeds: [SeedTemplate(key: key, file: drp.lastPathComponent, name: "Seed Wedding",
                                                     category: "Weddings", summary: "Long form wedding film", tags: ["wedding"])])
    try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("seeds.json"))

    // A fresh Mac: first launch imports, the second imports nothing.
    let (db2, paths2, _) = try freshEnv("seed-dst")
    let fresh = TemplateStore(db: db2, paths: paths2)
    let added = fresh.importSeeds(from: dir, done: [])
    check(added == [key], "first run imports the seed: \(added)")
    check(fresh.all.contains { $0.name == "Seed Wedding" && $0.category == "Weddings" && $0.tags.contains("wedding") },
          "seed keeps name, category and tags: \(fresh.all.map(\.name))")
    check(fresh.all.first?.current.originalFilename == drp.lastPathComponent, "seed file recorded")
    check(fresh.importSeeds(from: dir, done: Set(added)).isEmpty, "second run imports nothing")
    let again = fresh.importSeeds(from: dir, done: [])
    check(again == [key] && fresh.all.count == 1, "same name never becomes a second template: \(fresh.all.count)")

    // The maker's own library already has it: the seed is recorded, not duplicated.
    let (db3, paths3, root3) = try freshEnv("seed-existing")
    let mine = TemplateStore(db: db3, paths: paths3)
    _ = try mine.importTemplate(from: fixtureDrp(root3), name: "Seed Wedding")
    let added3 = mine.importSeeds(from: dir, done: [])
    check(added3 == [key] && mine.all.count == 1, "existing template wins over the seed: \(mine.all.count)")

    // A package built with --no-seeds has no seed folder: nothing imports, nothing breaks.
    check(fresh.importSeeds(from: root.appendingPathComponent("no-such-bundle"), done: []).isEmpty,
          "missing seed folder is not an error")
}

test("Template edits create versions; sessions keep the version they used") {
    let (db, paths, root) = try freshEnv("versions")
    let store = TemplateStore(db: db, paths: paths)
    let projects = ProjectStore(db: db, templates: store)
    let t = try store.importTemplate(from: fixtureDrp(root))
    let dest = root.appendingPathComponent("P"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let s1 = try projects.create(name: "One", template: t, destinationRoot: dest, createFolders: false, sources: [], mappings: [], settings: t.current.settings)
    let t2 = try store.newVersion(of: t.id, note: "bins") { $0.bins = [BinPlanEntry(binPath: "01 Footage/Camera A", defaultSourceRule: "cam a")] }
    check(t2.current.number == 2 && t2.versions.count == 2, "version 2 created")
    check(projects.get(s1.id)?.templateVersion == 1, "old session pinned to v1")
    check((try? store.newVersion(of: t.id, note: "noop") { _ in })?.versions.count == 2, "no-change save adds no version")
    var meta = t2; meta.name = "Renamed"; meta.favorite = true
    try store.updateMetadata(meta)
    check(store.get(t.id)?.versions.count == 2 && store.get(t.id)?.name == "Renamed", "metadata edit does not version")
}

// MARK: Projects

test("Bin mapping suggestions: rule match, existing bin, new nested bin") {
    let (db, paths, root) = try freshEnv("mapping")
    let projects = ProjectStore(db: db, templates: TemplateStore(db: db, paths: paths))
    let src = root.appendingPathComponent("Mohan & Anbika")
    for d in ["CAM A", "CAM B", "Drone"] { write(src.appendingPathComponent("\(d)/clip.mov"), "x") }
    let bins = [BinPlanEntry(binPath: "01 Footage/Camera A", defaultSourceRule: "cam a"), BinPlanEntry(binPath: "01 Footage/Camera B", defaultSourceRule: "cam b")]
    let m = projects.suggestMappings(sources: [MediaSource(path: src.path, label: "Mohan & Anbika")], bins: bins, templateID: nil)
    check(m.count == 3, "one row per camera folder")
    check(m.first { $0.sourcePath.hasSuffix("CAM A") }?.targetBin == "01 Footage/Camera A", "CAM A -> existing bin")
    let drone = m.first { $0.sourcePath.hasSuffix("Drone") }
    check(drone?.targetBin == "", "unmatched Drone -> Master bin (top level)")
    // Folders inside a camera folder become bins inside its bin; a folder with only subfolders gets no import of its own.
    write(src.appendingPathComponent("CAM A/Day 2/Audio/a.wav"), "x")
    let n = projects.suggestMappings(sources: [MediaSource(path: src.path, label: "Mohan & Anbika")], bins: bins, templateID: nil)
    check(n.contains { $0.sourcePath.hasSuffix("CAM A/Day 2/Audio") && $0.targetBin == "01 Footage/Camera A/Day 2/Audio" }, "nested folder mirrored: \(n.map(\.targetBin))")
    check(!n.contains { $0.sourcePath.hasSuffix("CAM A/Day 2") }, "folder without its own files is not imported")
}

test("Mappings follow the footage copied into the project") {
    let m = [BinMapping(sourcePath: "/Volumes/CARD/DCIM", targetBin: "Footage/DCIM"), BinMapping(sourcePath: "/Volumes/CARD/DCIM/100", targetBin: "Footage/DCIM/100"),
             BinMapping(sourcePath: "/Volumes/CARD2/X", targetBin: "Footage/X")]
    let r = ProjectStore.remap(m, from: "/Volumes/CARD/DCIM", to: "/P/Footage/DCIM")
    check(r.map(\.sourcePath) == ["/P/Footage/DCIM", "/P/Footage/DCIM/100", "/Volumes/CARD2/X"], "remapped: \(r.map(\.sourcePath))")
    check(r.map(\.targetBin) == m.map(\.targetBin), "bins unchanged")
}

test("A project folder inside its footage is refused; project folders are not bin rows") {
    let (db, paths, root) = try freshEnv("nesting")
    let store = TemplateStore(db: db, paths: paths)
    let projects = ProjectStore(db: db, templates: store)
    let t = try store.importTemplate(from: fixtureDrp(root))
    let footage = root.appendingPathComponent("clip")
    write(footage.appendingPathComponent("CAM A/a.mov"), "x")
    let inside = footage.appendingPathComponent("Projects")
    try fm.createDirectory(at: inside, withIntermediateDirectories: true)
    check(throwsError {
        _ = try projects.create(name: "P", template: t, destinationRoot: inside, createFolders: false,
                                sources: [MediaSource(path: footage.path, label: "clip")], mappings: [], settings: t.current.settings)
    }, "project inside footage is refused")
    // An earlier app project inside the footage must not become a bin source.
    write(footage.appendingPathComponent("Old Project/Resolve/Old Project.drp"), "x")
    write(footage.appendingPathComponent("Old Project/01 Raw Footage/a.mov"), "x")
    let rows = projects.suggestMappings(sources: [MediaSource(path: footage.path, label: "clip")], bins: [], templateID: nil)
    check(!rows.contains { $0.sourcePath.contains("Old Project") }, "old project folder skipped: \(rows.map(\.sourcePath))")
    // A folder holding only sidecars adds no row (nothing Resolve can import).
    write(footage.appendingPathComponent("Sidecars/notes.xml"), "x")
    let rows2 = projects.suggestMappings(sources: [MediaSource(path: footage.path, label: "clip")], bins: [], templateID: nil)
    check(!rows2.contains { $0.sourcePath.hasSuffix("Sidecars") }, "sidecar-only folder skipped")
}

test("Project names never overwrite; truthful states from receipts") {
    check(ProjectStore.uniqueName("Edit", taken: ["edit", "Edit (2)"]) == "Edit (3)", "unique name")
    let ok = ResolveReceipt(step: "a", capability: "canImportMedia", status: "ok")
    let imp = ResolveReceipt(step: "i", capability: "canImportProject", status: "ok")
    check(ProjectStore.state(from: []) == .manualStepRequired, "no Resolve steps = manual")
    check(ProjectStore.state(from: [ResolveReceipt(step: "e", capability: "edition", status: "manual")]) == .manualStepRequired, "Free = manual")
    check(ProjectStore.state(from: [imp, ok]) == .ready, "all ok = ready")
    check(ProjectStore.state(from: [imp, ok, ResolveReceipt(step: "f", capability: "canSetSetting", status: "skipped")]) == .partiallyCompleted, "skipped = partial")
    check(ProjectStore.state(from: [ResolveReceipt(step: "i", capability: "canImportProject", status: "failed")]) == .failed, "import failed = failed")
    check(ProjectStore.state(from: [ResolveReceipt(step: "b", capability: "bridge", status: "failed")]) == .failed, "bridge failed = failed")
    check(ProjectStore.state(from: [imp, ResolveReceipt(step: "a", capability: "canImportMedia", status: "failed"), ok]) == .ready, "retry success supersedes earlier failure")
}

test("Free checklist names manual steps and missing assets") {
    var v = TemplateVersion(number: 1, masterPath: "/m.drp", masterHash: "h", originalFilename: "m.drp")
    v.assets = [AssetRuleEntry(name: "Client logo", kind: .logo, rule: .replace), AssetRuleEntry(name: "Film LUT", kind: .lut, rule: .keep, essential: true, status: .knownMissing)]
    var s = ProjectSession(name: "P", templateID: UUID(), templateVersion: 1, templateName: "T", projectFolder: "/p", instanceDrpPath: "/p/Resolve/P.drp")
    s.mappings = [BinMapping(sourcePath: "/x/CAM A", targetBin: "01 Footage/Camera A"), BinMapping(sourcePath: "/x/Music", targetBin: "03 Audio", action: .later)]
    let text = ProjectStore.checklist(for: s, version: v)
    check(text.contains("has not imported anything"), "honest manual statement")
    check(text.contains("Client logo") && text.contains("Film LUT: Known missing (essential)"), "assets listed")
    check(text.contains("[later]  03 Audio"), "later mapping listed")
}

test("Resolve plan: bins deduplicated, omitted mappings excluded, frame rate passed") {
    var v = TemplateVersion(number: 1, masterPath: "/m.drp", masterHash: "h", originalFilename: "m.drp")
    v.bins = [BinPlanEntry(binPath: "01 Footage/Camera A")]
    var s = ProjectSession(name: "P", templateID: UUID(), templateVersion: 1, templateName: "T", projectFolder: "/p")
    s.mappings = [BinMapping(sourcePath: "/a", targetBin: "01 Footage/Camera A"), BinMapping(sourcePath: "/b", targetBin: "X", action: .omit)]
    let p = ResolveAdapter.plan(for: s, version: v, masterPath: v.masterPath)
    check((p["bins"] as? [String]) == ["01 Footage/Camera A"], "bins dedup")
    check((p["imports"] as? [[String: Any]])?.count == 1, "omit excluded")
    check((p["settings"] as? [String: Any])?.isEmpty == true, "untouched settings are not sent")
    s.settings.apply = true
    check((ResolveAdapter.plan(for: s, version: v, masterPath: v.masterPath)["settings"] as? [String: Any])?["width"] != nil, "chosen settings are sent")
}

test("Database round-trip and wizard draft persistence") {
    let (db, paths, _) = try freshEnv("db")
    let projects = ProjectStore(db: db, templates: TemplateStore(db: db, paths: paths))
    var d = WizardDraft(); d.step = 3; d.projectName = "Draft"
    projects.saveDraft(d)
    let db2 = try Database(path: paths.database.path)
    let p2 = ProjectStore(db: db2, templates: TemplateStore(db: db2, paths: paths))
    check(p2.draft == d, "draft survives reopen")
}

// MARK: Gap features

test(".drp diagnostics: version, bins, corrupt archive, version compare") {
    let (_, _, root) = try freshEnv("drpinfo")
    let drp = fixtureDrp(root)
    let info = DrpInfo.read(drp)
    if info.listed {
        check(info.appVersion == "21.1.0.0014", "version read from project.xml: \(info.appVersion ?? "nil")")
        check(info.bins == ["01 Footage", "01 Footage/Camera A", "03 Audio"], "bins from archive: \(info.bins)")
    }
    let bad = root.appendingPathComponent("bad.drp")
    let txt = root.appendingPathComponent("readme.txt"); write(txt, "x")
    let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); z.arguments = ["-qj", bad.path, txt.path]
    try z.run(); z.waitUntilExit()
    check(throwsError { try TemplateStore.validate(bad) }, "zip without project.xml rejected as corrupt")
    check(DrpInfo.isNewer("21.2.0", than: "21.1.0") && !DrpInfo.isNewer("21.1.0.0014", than: "21.1.0"), "version compare ignores build")
}

test("Per-file conflict decision overrides the job rule; conflicts listed") {
    let (db, paths, root) = try freshEnv("perfile")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD")
    write(dest.appendingPathComponent("CARD/AUDIO/ZOOM0001.WAV"), "OLD")
    write(dest.appendingPathComponent("CARD/DCIM/100MSDCF/DSC0001.JPG"), "OLD")
    var plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .skipExisting)
    check(Set(plan.conflicts) == ["AUDIO/ZOOM0001.WAV", "DCIM/100MSDCF/DSC0001.JPG"], "conflicts: \(plan.conflicts)")
    let i = plan.items.firstIndex { $0.relativePath == "AUDIO/ZOOM0001.WAV" }!
    plan.items[i].policy = .replace
    let runner = TransferRunner(db: db, paths: paths)
    try runner.saveNew(plan)
    _ = runner.run(plan.job)
    check((try? String(contentsOf: dest.appendingPathComponent("CARD/AUDIO/ZOOM0001.WAV"), encoding: .utf8)) != "OLD", "replaced only where chosen")
    check((try? String(contentsOf: dest.appendingPathComponent("CARD/DCIM/100MSDCF/DSC0001.JPG"), encoding: .utf8)) == "OLD", "job rule (skip) kept the other")
}

test("Continue remaining files on a new destination") {
    let (db, paths, root) = try freshEnv("continue")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD1"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)
    let plan = TransferPlanner.plan(name: "t", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    try runner.saveNew(plan)
    var n = 0
    let job = runner.run(plan.job, progress: { _ in n += 1 }, isCancelled: { n >= 3 })
    let remaining = runner.items(job.id).filter { !$0.state.isDone }
    let dest2 = root.appendingPathComponent("SSD2"); try fm.createDirectory(at: dest2, withIntermediateDirectories: true)
    let cont = TransferPlanner.continuation(of: job, remaining: remaining, to: dest2)
    check(cont.items.count == remaining.count && cont.canStart, "only remaining files planned: \(cont.items.count)/\(remaining.count)")
    try runner.saveNew(cont)
    check(runner.run(cont.job).status == .verified, "continuation verified")
}

test("Retry reuses the earlier Resolve project and skips finished imports") {
    var v = TemplateVersion(number: 1, masterPath: "/m.drp", masterHash: "h", originalFilename: "m.drp")
    v.bins = []
    var s = ProjectSession(name: "P", templateID: UUID(), templateVersion: 1, templateName: "T", projectFolder: "/p")
    s.mappings = [BinMapping(sourcePath: "/a", targetBin: "A"), BinMapping(sourcePath: "/b", targetBin: "B")]
    s.resolveProjectName = "P"
    let instance = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".drp")
    try? Data([0x50, 0x4B]).write(to: instance)
    defer { try? fm.removeItem(at: instance) }
    s.instanceDrpPath = instance.path
    s.receipts = [ResolveReceipt(step: "Import project", capability: "canImportProject", status: "ok", detail: "P"),
                  ResolveReceipt(step: "Import into A: a", capability: "canImportMedia", status: "ok"),
                  ResolveReceipt(step: "Import into B: b", capability: "canImportMedia", status: "failed")]
    let p = ResolveAdapter.plan(for: s, version: v, masterPath: v.masterPath)
    check(p["existingProject"] as? String == "P", "reuses project this session imported")
    check(p["drp"] as? String == instance.path, "imports the project instance, not the library master")
    check(p["exportDrp"] as? String == instance.path, "exports the saved project back to the instance")
    check((p["imports"] as? [[String: Any]])?.map { $0["bin"] as? String } == ["B"], "only failed import retried")
    // A same-named project made by the editor is never reused.
    var other = s
    other.receipts = [ResolveReceipt(step: "Import project", capability: "canImportProject", status: "failed")]
    let q = ResolveAdapter.plan(for: other, version: v, masterPath: v.masterPath)
    check(q["existingProject"] as? String == "", "does not borrow an unrelated same-named project")
    // Optional imports carry their flag to the bridge.
    other.mappings = [BinMapping(sourcePath: "/c", targetBin: "C", action: .optionalImport)]
    let r = ResolveAdapter.plan(for: other, version: v, masterPath: v.masterPath)
    check((r["imports"] as? [[String: Any]])?.first?["optional"] as? Bool == true, "optional import flag is passed")
    // Clip input color space is sent without forcing project resolution or frame rate.
    var colored = s
    colored.settings.inputColorSpace = "Rec.2100 HLG"
    let csp = ResolveAdapter.plan(for: colored, version: v, masterPath: v.masterPath)
    check(csp["inputColorSpace"] as? String == "Rec.2100 HLG", "clip input color space is passed")
    check((csp["settings"] as? [String: Any])?.isEmpty == true, "color space alone does not send resolution settings")
    check(ProjectStore.checklist(for: colored, version: v).contains("Input Color Space > HLG"), "checklist tells the manual path")
}

test("Name pattern, asset scan merge, local metrics") {
    var t = Template(name: "Mehndi Long Video", versions: [TemplateVersion(number: 1, masterPath: "", masterHash: "", originalFilename: "")])
    t.category = "Wedding"
    let d = DateComponents(calendar: .current, year: 2026, month: 11, day: 8).date!
    check(ProjectStore.applyPattern("{date} {template} - {category}", template: t, date: d) == "2026-11-08 Mehndi Long Video - Wedding", "pattern filled")
    let old = [AssetRuleEntry(name: "Logo", location: "/l.png", status: .notChecked)]
    let merged = TemplateStore.merge([AssetRuleEntry(name: "Logo", location: "/l.png", status: .knownMissing), AssetRuleEntry(name: "A001", location: "/a.mp4", status: .available)], into: old)
    check(merged.count == 2 && merged[0].status == .knownMissing, "scan merged by location")
    var j = TransferJob(name: "j", mode: .cameraCardBackup, conflictPolicy: .keepBoth, sourcePath: "/", destinationRoot: "/", outputPath: "/o")
    j.status = .verified; j.started = Date(timeIntervalSinceNow: -10); j.finished = Date(); j.copiedBytes = 1000
    var s = ProjectSession(name: "P", templateID: t.id, templateVersion: 1, templateName: t.name, projectFolder: "/p")
    s.state = .manualStepRequired; s.wizardSeconds = 42
    let m = LocalMetrics.compute(jobs: [j], items: [TransferItem(relativePath: "a", bytes: 1, message: "Checksum mismatch: x")], sessions: [s], templates: [t])
    check(m.transfers.contains { $0.value.contains("1 of 1 files") }, "mismatch counted")
    check(m.projects.contains { $0.label.contains("Free") && $0.value.hasPrefix("1 of 1") }, "manual share for Free/unknown")
}

test("Verification policy, retry failed, packaged assets, capability gating, scan mapping") {
    let (db, paths, root) = try freshEnv("final")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)
    // camera backup ignores size-only; selective honors it and reports "not verified"
    let cam = TransferPlanner.plan(name: "c", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, verification: .sizeOnly)
    check(cam.job.verification == .sha256, "camera backup always SHA-256")
    var f = SelectiveFilter(); f.categories = [.video]
    let sel = TransferPlanner.plan(name: "s", source: card, destinationRoot: dest, mode: .selectiveCopy, filter: f, policy: .keepBoth, verification: .sizeOnly)
    check(sel.canStart, "selective plan can start: \(sel.issues.map(\.message)) items=\(sel.items.count)")
    try runner.saveNew(sel)
    check(sel.items.count == 2, "size-only warning does not stop the scan")
    let sj = runner.run(sel.job)
    check(sj.status == .copiedUnverified, "size-only job is not called verified: \(sj.status)")
    check(runner.items(sj.id).allSatisfy { $0.state == .copiedUnverified }, "items marked not verified")
    // retry failed
    let dest2 = root.appendingPathComponent("SSD2"); try fm.createDirectory(at: dest2, withIntermediateDirectories: true)
    let p2 = TransferPlanner.plan(name: "r", source: card, destinationRoot: dest2, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    runner.afterWrite = { u in if u.lastPathComponent.contains("C0002") { try? "x".write(to: u, atomically: false, encoding: .utf8) } }
    try runner.saveNew(p2)
    let j2 = runner.run(p2.job)
    check(j2.status == .partiallyVerified, "one corrupted file -> partial")
    runner.afterWrite = nil
    check((try? runner.resetFailed(j2)) == 1, "one failed file reset")
    check(runner.run(db.get("job", id: j2.id.uuidString, as: TransferJob.self)!).status == .verified, "controlled retry verifies")
    // packaging
    let store = TemplateStore(db: db, paths: paths)
    let t = try store.importTemplate(from: fixtureDrp(root))
    let logo = root.appendingPathComponent("logo.png"); write(logo, "PNG")
    let packed = try store.packageFile(logo, templateID: t.id)
    check(fm.fileExists(atPath: packed) && (try? Hashing.sha256(URL(fileURLWithPath: packed))) == (try? Hashing.sha256(logo)), "asset packaged with checksum")
    try store.remove(t.id)
    check(!fm.fileExists(atPath: packed), "template removal clears packaged assets")
    // capability gating
    var s = ProjectSession(name: "P", templateID: UUID(), templateVersion: 1, templateName: "T", projectFolder: "/p")
    s.mappings = [BinMapping(sourcePath: "/a", targetBin: "A")]
    let v = TemplateVersion(number: 1, masterPath: "/m", masterHash: "h", originalFilename: "m")
    let gated = ResolveAdapter.plan(for: s, version: v, masterPath: "/m", allowed: ["canImportProject"])
    check((gated["allowed"] as? [String]) == ["canImportProject"], "allowed list passed to bridge")
    check(Capabilities.key("21.1.0.14") == "21.1" && Capabilities.builtIn["21.1"] != nil && Capabilities.builtIn["21.2"] == nil, "only tested versions are built in")
    var st = ResolveStatus(installed: true, reachable: true, edition: .studio, message: "")
    check(!st.canAutomate && st.needsSelfTest, "untested version: no automation until self-test")
    st.capabilities = ["canImportProject": true]
    check(st.canAutomate, "proven capability enables automation")
    // scan mapping
    let a = ResolveAdapter.assets(fromScan: ["clips": [["name": "A001", "path": "/nope/A001.mp4", "type": "Video", "exists": false]],
                                             "fonts": ["Helvetica", "NoSuchFont123"], "luts": ["nope/x.cube"], "ofx": ["ofx.com.vendor.Glow"], "titles": ["Lower Third"]])
    check(a.first { $0.name == "A001" }?.status == .knownMissing, "missing clip")
    check(ResolveAdapter.assets(fromScan: ["clips": [["name": "v", "path": "/v.mov", "type": "Video + Audio", "exists": true], ["name": "m", "path": "/m.wav", "type": "Audio", "exists": true]]]).map(\.kind) == [.footage, .music], "video+audio is footage")
    check(a.first { $0.name == "Helvetica" }?.status == .available && a.first { $0.name == "NoSuchFont123" }?.status == .knownMissing, "fonts checked against installed")
    check(a.first { $0.kind == .lut }?.status == .knownMissing && a.first { $0.kind == .ofx }?.status == .notChecked, "LUT missing, OFX not checked")
    // log
    Log.directory = paths.logs
    let id = Log.error("test failure", ["job": "x"])
    check(id.hasPrefix("EW-") && ((try? String(contentsOf: paths.logs.appendingPathComponent("app.log"), encoding: .utf8)) ?? "").contains(id), "error logged with ID")
}

// MARK: Menu bar companion (spec v2.0)

test("Companion: file sources, rename output, overlap/dupe selection, queue overlap") {
    let (db, paths, root) = try freshEnv("companion")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let file = card.appendingPathComponent("AUDIO/ZOOM0001.WAV")
    let fp = TransferPlanner.plan(name: "f", source: file, destinationRoot: dest, mode: .selectiveCopy, filter: nil, policy: .keepBoth)
    check(fp.canStart && fp.items.map(\.relativePath) == ["ZOOM0001.WAV"] && fp.job.outputPath == dest.canonical.path, "single file plans into destination")
    let runner = TransferRunner(db: db, paths: paths)
    try runner.saveNew(fp)
    check(runner.run(fp.job).status == .verified && fm.fileExists(atPath: dest.appendingPathComponent("ZOOM0001.WAV").path), "file copied and verified")
    let named = TransferPlanner.plan(name: "n", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, outputName: "Mohan & Anbika")
    check(named.job.outputPath.hasSuffix("/Mohan & Anbika"), "output folder renamed")
    check(named.job.scannedFiles == 7, "scanned count recorded")
    let norm = TransferPlanner.normalizeSources([card, card.appendingPathComponent("PRIVATE"), card, file])
    check(norm.map(\.lastPathComponent) == ["CARD"], "child and duplicate selections dropped: \(norm.map(\.lastPathComponent))")
    var a = named.job, b = named.job; b.id = UUID()
    check(TransferPlanner.overlaps(a, b), "same output overlaps")
    b.outputPath = dest.appendingPathComponent("Other").path; b.sourcePath = root.appendingPathComponent("X").path
    check(!TransferPlanner.overlaps(a, b), "independent jobs do not overlap")
    a.outputPath = card.appendingPathComponent("inside").path
    b.sourcePath = card.path
    check(TransferPlanner.overlaps(a, b), "writing into another job's source overlaps")
    let missing = dest.appendingPathComponent("New Client")
    let mp = TransferPlanner.plan(name: "m", source: card.appendingPathComponent("AUDIO"), destinationRoot: missing, mode: .cameraCardBackup, filter: nil, policy: .keepBoth, allowMissingDestination: true)
    check(mp.canStart && !fm.fileExists(atPath: missing.path), "missing destination accepted, not created at planning")
    try runner.saveNew(mp)
    check(runner.run(mp.job).status == .verified && fm.fileExists(atPath: missing.appendingPathComponent("AUDIO/ZOOM0001.WAV").path), "created when copying")
    let mfp = TransferPlanner.plan(name: "mf", source: file, destinationRoot: dest.appendingPathComponent("Files"), mode: .selectiveCopy, filter: nil, policy: .keepBoth, allowMissingDestination: true)
    check(mfp.canStart, "file into missing folder plans: \(mfp.issues.map(\.message))")
    try runner.deleteRecord(fp.job)
    check(runner.items(fp.job.id).isEmpty && db.get("job", id: fp.job.id.uuidString, as: TransferJob.self) == nil && fm.fileExists(atPath: dest.appendingPathComponent("ZOOM0001.WAV").path), "history removed, media kept")
}

test("Companion: source changing mid-copy is caught; report counts; drive policy") {
    let (db, paths, root) = try freshEnv("companion2")
    let card = makeCard(root)
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)
    let plan = TransferPlanner.plan(name: "c", source: card, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    runner.afterWrite = { u in if u.lastPathComponent.contains("C0002") { write(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002.MP4"), "camera still writing") } }
    try runner.saveNew(plan)
    var phases: [String] = []
    let job = runner.run(plan.job, activity: { _, p in phases.append(p) })
    runner.afterWrite = nil
    let bad = runner.items(job.id).first { $0.relativePath.hasSuffix("C0002.MP4") }!
    check(bad.state == .failed && bad.message?.contains("Source changed") == true, "changed source flagged")
    check(phases.contains("Copying") && phases.contains("Verifying"), "phases reported")
    let r = TransferReport.make([(job, runner.items(job.id))])
    check(r.selected == 7 && r.copied == 6 && r.failed == 1 && r.verified == 6 && !r.isVerified, "report counts: \(r)")
    check(r.text.contains("Partial") && r.exceptions.contains { $0.contains("C0002") }, "report text names the exception")
    let ext = VolumeIdentity(uuid: "U1", name: "CARD", mountPath: "/Volumes/CARD", capacity: 1, available: 1, fileSystem: "exfat", isInternal: false, isRemovable: true, isReadOnly: false, isLocal: true, caseSensitive: false)
    var internalVol = ext; internalVol.isInternal = true
    check(DrivePolicy.decide(ext, mode: .open, trustedOnly: false, trusted: [], editorInFront: false, busy: false) == .openPanel, "open")
    check(DrivePolicy.decide(ext, mode: .open, trustedOnly: false, trusted: [], editorInFront: true, busy: false) == .openPanel, "editor in front still opens")
    check(DrivePolicy.decide(ext, mode: .open, trustedOnly: false, trusted: [], editorInFront: false, busy: true) == .openPanel, "busy still opens (route kept)")
    var helper = ext; helper.mountPath = "/System/Volumes/Update"
    check(DrivePolicy.decide(helper, mode: .open, trustedOnly: false, trusted: [], editorInFront: false, busy: false) == .ignore, "system helper volume ignored")
    check(DrivePolicy.decide(ext, mode: .notify, trustedOnly: false, trusted: [], editorInFront: false, busy: false) == .notify, "notify mode")
    check(DrivePolicy.decide(ext, mode: .open, trustedOnly: true, trusted: [], editorInFront: false, busy: false) == .askTrust, "untrusted asks")
    check(DrivePolicy.decide(ext, mode: .open, trustedOnly: true, trusted: ["U1"], editorInFront: false, busy: false) == .openPanel, "trusted opens")
    check(DrivePolicy.decide(internalVol, mode: .open, trustedOnly: false, trusted: [], editorInFront: false, busy: false) == .ignore, "internal ignored")
    check(DrivePolicy.decide(ext, mode: .never, trustedOnly: false, trusted: [], editorInFront: false, busy: false) == .ignore, "never")
    var st = CompanionState(); st.draft.sources = ["/a"]; st.draft.stage = .destination; st.tab = .favorites
    try db.save("ui", id: "companion", st)
    check(db.get("ui", id: "companion", as: CompanionState.self) == st, "companion state round-trips")
}

test("Camera card detection and folder names") {
    let (_, _, root) = try freshEnv("cards")
    let gopro = root.appendingPathComponent("G"); write(gopro.appendingPathComponent("DCIM/100GOPRO/GX010001.MP4"), "x")
    let sony = root.appendingPathComponent("S"); write(sony.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), "x")
    let canon = root.appendingPathComponent("C"); write(canon.appendingPathComponent("DCIM/100CANON/IMG_0001.CR3"), "x")
    let bm = root.appendingPathComponent("B"); write(bm.appendingPathComponent("A001_C001.braw"), "x")
    let plain = root.appendingPathComponent("P"); write(plain.appendingPathComponent("notes.txt"), "x")
    check(CameraCard.detect(gopro) == "GoPro" && CameraCard.detect(sony) == "Sony" && CameraCard.detect(canon) == "Canon" && CameraCard.detect(bm) == "Blackmagic", "brands detected")
    check(CameraCard.detect(plain) == nil, "plain drive is not a camera card")
    let d = DateComponents(calendar: .current, year: 2026, month: 11, day: 9).date!
    check(CameraCard.folderName(volumeName: "NO NAME", brand: "GoPro", date: d) == "GoPro 2026-11-09", "generic card name replaced")
    check(CameraCard.folderName(volumeName: "A001", brand: "Sony", date: d) == "A001 2026-11-09", "named card kept")
}

test("Cover photos: real image check, content naming, framing, survives reload, export/import") {
    let (db, paths, root) = try freshEnv("covers")
    let store = TemplateStore(db: db, paths: paths)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(7), count: 40))
    let cs = store.covers
    check(CoverStore.imageExtension(png) == "png" && CoverStore.imageExtension(Data("hello".utf8)) == nil, "magic bytes decide the type")
    check(throwsError { _ = try cs.save(Data("not an image".utf8)) }, "text refused")
    let n1 = try cs.save(png), n2 = try cs.save(png)
    check(n1 == n2 && n1.hasSuffix(".png") && n1.count == 20, "same content, same name: \(n1)")
    check(CoverStore.value(n1) == n1 && CoverStore.value(n1, x: 30, y: 60) == n1 + "#30,60", "centered framing not stored")
    let p = cs.parse(n1 + "#30,60")
    check(p?.x == 30 && p?.y == 60 && p?.url.lastPathComponent == n1, "value round-trips")
    check(cs.parse("../../etc/passwd") == nil && cs.parse("/abs/x.png") == nil, "only exact cover names accepted")
    let t = try store.importTemplate(from: fixtureDrp(root))
    try store.setCover(t.id, value: n1 + "#30,60")
    var meta = store.get(t.id)!; meta.name = "Renamed"; try store.updateMetadata(meta)
    let db2 = try Database(path: paths.database.path)
    check(TemplateStore(db: db2, paths: paths).get(t.id)?.cover == n1 + "#30,60", "cover survives metadata save and reload")
    let out = root.appendingPathComponent("export"); try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let drp = try store.export(t.id, to: out)
    check(fm.fileExists(atPath: drp.deletingPathExtension().appendingPathExtension("cover.json").path), "cover packed beside export")
    let (db3, paths3, _) = try freshEnv("covers-import")
    let store3 = TemplateStore(db: db3, paths: paths3)
    let imported = try store3.importTemplate(from: drp)
    check(imported.cover == n1 + "#30,60" && fm.fileExists(atPath: paths3.covers.appendingPathComponent(n1).path), "import restores cover from packed image")
    check(cs.unpack(CoverStore.Packed(pos: "#1,1", base64: Data("fake".utf8).base64EncodedString())) == nil, "fake packed image rejected")
    check(CoverFinder.queries("Mehndi Long Video") == ["Mehndi Long Video", "Mehndi"], "query fallback: \(CoverFinder.queries("Mehndi Long Video"))")
    check(CoverFinder.queries("YouTube 4K Edit v2") == ["YouTube 4K Edit v2", "YouTube"], "filler words dropped: \(CoverFinder.queries("YouTube 4K Edit v2"))")
    check(CoverFinder.searchTerm("wedding long (slog)") == "wedding", "parentheses and jargon dropped: \(CoverFinder.searchTerm("wedding long (slog)"))")
    check(CoverFinder.searchTerm("ram engagement") == "engagement", "event word wins over the client name: \(CoverFinder.searchTerm("ram engagement"))")
    check(CoverFinder.searchTerm("Mohan & Anbika - Mehndi") == "Mehndi", "last meaningful word: \(CoverFinder.searchTerm("Mohan & Anbika - Mehndi"))")
    check(CoverFinder.searchTerm("S-Log3 Wedding 4K") == "Wedding", "camera jargon ignored: \(CoverFinder.searchTerm("S-Log3 Wedding 4K"))")
    check(CoverStore.ogImage(#"<meta property="og:image" content="https://i.pinimg.com/736x/ab/c.jpg?a=1&amp;b=2">"#) == "https://i.pinimg.com/736x/ab/c.jpg?a=1&b=2", "pin page share image found")
    check(CoverStore.ogImage(#"<meta content="https://x.test/a.png" property='og:image'>"#) == "https://x.test/a.png", "share image, reversed attributes")
    check(CoverStore.ogImage("<html><title>none</title></html>") == nil, "page without share image")
}

test("Read-ahead pipe keeps order and passes read errors") {
    let p = ChunkPipe(capacity: 2)
    DispatchQueue.global().async { for i in 0..<50 { _ = p.put(Data([UInt8(i)])) }; p.finish(nil) }
    var got: [UInt8] = []
    while let d = try p.take() { got.append(d[0]) }
    check(got == Array(0..<50), "chunks arrive in order")
    let q = ChunkPipe(capacity: 2)
    q.finish(CoverStore.CoverError.badResponse)
    var threw = false
    do { _ = try q.take() } catch { threw = true }
    check(threw, "read error reaches the writer")
}

// MARK: Scale

test("Many small files (2,000) copy and verify") {
    let (db, paths, root) = try freshEnv("many")
    let src = root.appendingPathComponent("Many")
    for i in 0..<2000 { write(src.appendingPathComponent("d\(i % 20)/f\(i).txt"), "file \(i)") }
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)
    let plan = TransferPlanner.plan(name: "many", source: src, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    try runner.saveNew(plan)
    let start = Date()
    let job = runner.run(plan.job)
    check(job.status == .verified && runner.items(job.id).count == 2000, "2000 verified (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
}

test("Two jobs copy at the same time into one drive without clobbering") {
    let (db, paths, root) = try freshEnv("parallel")
    let a = root.appendingPathComponent("CardA"), b = root.appendingPathComponent("CardB")
    for i in 0..<40 { write(a.appendingPathComponent("clips/a\(i).mov"), String(repeating: "A\(i) ", count: 400)) }
    for i in 0..<40 { write(b.appendingPathComponent("clips/b\(i).mov"), String(repeating: "B\(i) ", count: 400)) }
    let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let runner = TransferRunner(db: db, paths: paths)
    let p1 = TransferPlanner.plan(name: "a", source: a, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    let p2 = TransferPlanner.plan(name: "b", source: b, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
    try runner.saveNew(p1); try runner.saveNew(p2)
    var results = [TransferJob?](repeating: nil, count: 2)
    DispatchQueue.concurrentPerform(iterations: 2) { i in
        results[i] = runner.run(i == 0 ? p1.job : p2.job)
    }
    let (j1, j2) = (results[0]!, results[1]!)
    check(j1.status == .verified && j2.status == .verified, "both verified in parallel: \(j1.status) \(j2.status)")
    check(runner.items(j1.id).allSatisfy { $0.state == .verified } && runner.items(j2.id).allSatisfy { $0.state == .verified }, "every file verified in both jobs")
    check(FileManager.default.fileExists(atPath: dest.appendingPathComponent("CardA/clips/a0.mov").path)
            && FileManager.default.fileExists(atPath: dest.appendingPathComponent("CardB/clips/b0.mov").path),
          "both outputs landed side by side on one drive")
}

if ProcessInfo.processInfo.environment["EW_BIG"] == "1" {
    test("Large file (>4 GiB) copies and verifies") {
        let (db, paths, root) = try freshEnv("big")
        let src = root.appendingPathComponent("Big"); try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let f = src.appendingPathComponent("big.mov")
        let h = FileHandle(fileDescriptor: open(f.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644), closeOnDealloc: true)
        let block = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for _ in 0..<520 { h.write(block) } // ~4.06 GiB
        try h.close()
        let dest = root.appendingPathComponent("SSD"); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let runner = TransferRunner(db: db, paths: paths)
        let plan = TransferPlanner.plan(name: "big", source: src, destinationRoot: dest, mode: .cameraCardBackup, filter: nil, policy: .keepBoth)
        try runner.saveNew(plan)
        check(runner.run(plan.job).status == .verified, "big file verified")
    }
}

print("\n\(passed) checks passed, \(failures) failed")
try? fm.removeItem(at: base) // exit() skips defer
exit(failures == 0 ? 0 : 1)
