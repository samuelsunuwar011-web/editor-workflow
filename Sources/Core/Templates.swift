import Foundation

enum TemplateError: Error, CustomStringConvertible {
    case notDrp(String), unreadable(String), copyMismatch, notFound, corrupt(String, String)
    var description: String {
        switch self {
        case .notDrp(let s): return "\(s) is not a DaVinci Resolve project (.drp) file."
        case .unreadable(let s): return "Cannot read \(s)."
        case .copyMismatch: return "The stored master copy did not match the original. Import cancelled."
        case .notFound: return "Template not found."
        case .corrupt(let f, let why): return "\(f) cannot be used: \(why)."
        }
    }
}

/// Template library. Masters are stored read-only and never modified; any change to
/// master, bins, assets or settings produces a new version.
final class TemplateStore {
    let db: Database
    let paths: AppPaths

    init(db: Database, paths: AppPaths) { self.db = db; self.paths = paths }

    var all: [Template] { db.all("template") }
    func get(_ id: UUID) -> Template? { db.get("template", id: id.uuidString) }
    func save(_ t: Template) throws { try db.save("template", id: t.id.uuidString, t) }

    /// .drp files are zip containers: check extension, zip signature and that the archive lists a project.xml.
    static func validate(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "drp" else { throw TemplateError.notDrp(url.lastPathComponent) }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw TemplateError.unreadable(url.path) }
        defer { try? h.close() }
        let magic = (try? h.read(upToCount: 4)) ?? Data()
        guard magic == Data([0x50, 0x4B, 0x03, 0x04]) else { throw TemplateError.notDrp(url.lastPathComponent) }
        let info = DrpInfo.read(url)
        if info.listed && !info.hasProject { throw TemplateError.corrupt(url.lastPathComponent, "no project.xml inside; the file is damaged or not a Resolve project export") }
    }

    private func storeMaster(_ src: URL, templateID: UUID, version: Int) throws -> (path: String, hash: String) {
        try Self.validate(src)
        let dir = paths.masters.appendingPathComponent(templateID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("v\(version).drp")
        let srcHash = try Hashing.sha256(src)
        try FileManager.default.copyItem(at: src, to: dst)
        let dstHash = try Hashing.sha256(dst)
        guard srcHash == dstHash else { try? FileManager.default.removeItem(at: dst); throw TemplateError.copyMismatch }
        try FileManager.default.setAttributes([.posixPermissions: 0o444, .immutable: false], ofItemAtPath: dst.path)
        return (dst.path, dstHash)
    }

    @discardableResult
    func importTemplate(from url: URL, name: String? = nil, category: String = "", tags: [String] = [], resolveVersion: String? = nil) throws -> Template {
        let id = UUID()
        let m = try storeMaster(url, templateID: id, version: 1)
        let info = DrpInfo.read(URL(fileURLWithPath: m.path))
        var v = TemplateVersion(number: 1, masterPath: m.path, masterHash: m.hash, originalFilename: url.lastPathComponent,
                                resolveVersion: info.appVersion ?? resolveVersion, note: "Imported")
        // Bin names come from the archive's folder listing (read-only); source rules are a starting guess.
        v.bins = info.bins.map { BinPlanEntry(binPath: $0, defaultSourceRule: ($0.split(separator: "/").last.map(String.init) ?? "").lowercased()) }
        v.diagnostics = info.diagnostics(installed: ResolveAdapter.installedVersion())
        let t = Template(id: id, name: name ?? url.deletingPathExtension().lastPathComponent, category: category, tags: tags, versions: [v])
        try save(t)
        importPackedCover(for: url, into: id)
        // An exported bundle keeps packaged logos/LUTs/titles in <name>.assets beside the .drp.
        // Never read that side folder when the source is our own stored master (duplicate()).
        let side = url.deletingPathExtension().appendingPathExtension("assets")
        var isDir: ObjCBool = false
        if !url.path.hasPrefix(paths.masters.path),
           FileManager.default.fileExists(atPath: side.path, isDirectory: &isDir), isDir.boolValue,
           let files = try? FileManager.default.contentsOfDirectory(at: side, includingPropertiesForKeys: nil) {
            for f in files where !f.lastPathComponent.hasPrefix(".") { _ = try? packageFile(f, templateID: id) }
        }
        return get(id) ?? t  // includes an imported cover, so callers that save it back keep it
    }

    /// Template from the project open in Resolve Studio: exported .drp plus its real bins and settings.
    @discardableResult
    func importCurrent(_ c: ResolveAdapter.CurrentProject) throws -> Template {
        defer { try? FileManager.default.removeItem(at: c.drp) } // our temporary export, already copied into the library
        var t = try importTemplate(from: c.drp, name: c.name)
        t.versions[0].bins = c.bins.map { BinPlanEntry(binPath: $0, defaultSourceRule: ($0.split(separator: "/").last.map(String.init) ?? "").lowercased()) }
        t.versions[0].settings = c.settings
        t.versions[0].note = "Exported from the project open in Resolve"
        t.versions[0].testStatus = "Opened in Resolve Studio"
        try save(t)
        return t
    }

    /// Copies a reusable asset (logo, title, LUT the editor has rights to) into the template library, read-only.
    /// shortcut: a copy made in an editing session that is then not saved stays in the folder; harmless, cleared on template removal.
    func packageFile(_ url: URL, templateID: UUID) throws -> String {
        let dir = paths.masters.appendingPathComponent(templateID.uuidString).appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = TransferRunner.uniqueNameIfNeeded(dir.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.copyItem(at: url, to: dst)
        guard try Hashing.sha256(url) == Hashing.sha256(dst) else { try? FileManager.default.removeItem(at: dst); throw TemplateError.copyMismatch }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dst.path)
        return dst.path
    }

    /// Merges scanned media references into the asset rules: known locations update status, new ones are added.
    static func merge(_ scanned: [AssetRuleEntry], into assets: [AssetRuleEntry]) -> [AssetRuleEntry] {
        var out = assets
        for a in scanned {
            if let i = out.firstIndex(where: { !$0.location.isEmpty && $0.location == a.location }) { out[i].status = a.status }
            else { out.append(a) }
        }
        return out
    }

    /// Metadata only (name, tags, favorite, thumbnail): no new version.
    func updateMetadata(_ t: Template) throws {
        guard var cur = get(t.id) else { throw TemplateError.notFound }
        cur.name = t.name; cur.summary = t.summary; cur.category = t.category; cur.tags = t.tags
        cur.projectTypes = t.projectTypes; cur.favorite = t.favorite; cur.thumbnailPath = t.thumbnailPath; cur.cover = t.cover; cur.lastUsed = t.lastUsed
        try save(cur)
    }

    /// Bins, assets, settings or folder scheme changed: append a version that reuses the same master file.
    @discardableResult
    func newVersion(of id: UUID, note: String, edit: (inout TemplateVersion) -> Void) throws -> Template {
        guard var t = get(id) else { throw TemplateError.notFound }
        var v = t.current
        edit(&v)
        // No real change: keep the current version instead of adding an identical one.
        if v.bins == t.current.bins && v.assets == t.current.assets && v.settings == t.current.settings && v.folderScheme == t.current.folderScheme {
            return t
        }
        v.number = t.current.number + 1
        v.importedAt = Date()
        v.note = note
        t.versions.append(v)
        try save(t)
        return t
    }

    /// Replace the master .drp: new version with a new immutable file.
    /// Bins come from the new archive, so automation never targets a bin the new master lacks.
    /// Assets and settings stay: logos, LUTs and titles are separate from the project file.
    @discardableResult
    func replaceMaster(of id: UUID, with url: URL, note: String = "Master replaced") throws -> Template {
        guard var t = get(id) else { throw TemplateError.notFound }
        var v = t.current
        v.number += 1
        let m = try storeMaster(url, templateID: id, version: v.number)
        let info = DrpInfo.read(URL(fileURLWithPath: m.path))
        v.masterPath = m.path; v.masterHash = m.hash; v.originalFilename = url.lastPathComponent
        v.bins = info.bins.map { BinPlanEntry(binPath: $0, defaultSourceRule: ($0.split(separator: "/").last.map(String.init) ?? "").lowercased()) }
        v.diagnostics = info.diagnostics(installed: ResolveAdapter.installedVersion())
        v.importedAt = Date(); v.note = note; v.testStatus = "Not tested"
        t.versions.append(v)
        try save(t)
        return t
    }

    func duplicate(_ id: UUID) throws -> Template {
        guard let t = get(id) else { throw TemplateError.notFound }
        let src = URL(fileURLWithPath: t.current.masterPath)
        var copy = try importTemplate(from: src, name: t.name + " copy", category: t.category, tags: t.tags, resolveVersion: t.current.resolveVersion)
        var v = t.current
        v.number = 1; v.masterPath = copy.current.masterPath; v.masterHash = copy.current.masterHash; v.note = "Duplicated from \(t.name)"
        copy.versions = [v]
        copy.summary = t.summary; copy.thumbnailPath = t.thumbnailPath
        copy.favorite = t.favorite; copy.projectTypes = t.projectTypes; copy.cover = t.cover
        try save(copy)
        return copy
    }

    /// Removes the library record and its stored masters. Projects made from it keep their own .drp copies.
    func remove(_ id: UUID) throws {
        let dir = paths.masters.appendingPathComponent(id.uuidString)
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let f as URL in e { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
        }
        try? FileManager.default.removeItem(at: dir)
        try db.delete("template", id: id.uuidString)
    }

    var covers: CoverStore { CoverStore(dir: paths.covers) }

    /// Copies the master's .drp out of the library, with its cover packed beside it (<name>.cover.json)
    /// and any packaged assets in <name>.assets/ so an export is a complete, re-importable bundle.
    func export(_ id: UUID, to folder: URL) throws -> URL {
        guard let t = get(id) else { throw TemplateError.notFound }
        let dst = TransferRunner.uniqueNameIfNeeded(folder.appendingPathComponent("\(t.name).drp"))
        try FileManager.default.copyItem(atPath: t.current.masterPath, toPath: dst.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dst.path)
        if let packed = covers.pack(t.cover) {
            try JSONEncoder().encode(packed).write(to: dst.deletingPathExtension().appendingPathExtension("cover.json"))
        }
        let assets = paths.masters.appendingPathComponent(id.uuidString).appendingPathComponent("assets", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: assets.path, isDirectory: &isDir), isDir.boolValue {
            let side = dst.deletingPathExtension().appendingPathExtension("assets")
            try? FileManager.default.copyItem(at: assets, to: side)
        }
        return dst
    }

    /// Picks up "<name>.cover.json" next to an imported .drp (untrusted: checked by CoverStore.unpack).
    func importPackedCover(for drp: URL, into id: UUID) {
        let side = drp.deletingPathExtension().appendingPathExtension("cover.json")
        guard let d = try? Data(contentsOf: side), d.count < 20_000_000,
              let p = try? JSONDecoder().decode(CoverStore.Packed.self, from: d), let v = covers.unpack(p) else { return }
        try? setCover(id, value: v)
    }

    func setCover(_ id: UUID, value: String?) throws {
        guard var t = get(id) else { throw TemplateError.notFound }
        t.cover = value
        try save(t)
    }

    /// An image file chosen by the user becomes the cover (stored by content, framing centered).
    func setThumbnail(_ id: UUID, image: URL) throws {
        let name = try covers.save(try Data(contentsOf: image))
        try setCover(id, value: CoverStore.value(name))
    }

    /// Checks the stored master against its recorded checksum.
    func verifyMaster(_ v: TemplateVersion) -> Bool { (try? Hashing.sha256(URL(fileURLWithPath: v.masterPath))) == v.masterHash }
}

extension TransferRunner {
    static func uniqueNameIfNeeded(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path) ? uniqueName(for: url) : url
    }
}

// MARK: - Shipped templates (seeds)

/// One template that travels inside the app bundle. `key` is stable across exports, so a Mac
/// imports it exactly once even if the template is later renamed or removed by the user.
struct SeedTemplate: Codable, Hashable {
    var key: String
    var file: String
    var name: String
    var category: String = ""
    var summary: String = ""
    var tags: [String] = []

    init(key: String, file: String, name: String, category: String = "", summary: String = "", tags: [String] = []) {
        self.key = key; self.file = file; self.name = name
        self.category = category; self.summary = summary; self.tags = tags
    }
}

struct SeedManifest: Codable, Hashable { var seeds: [SeedTemplate] }

extension TemplateStore {
    /// Copies the .drp files bundled in <dir> into this library, once each.
    /// `done` holds keys imported on this Mac before; the returned keys are the ones added now,
    /// so the caller can remember them. A template that already carries the seed's name is skipped
    /// (the user made or renamed it themselves), and a broken seed is reported, never fatal.
    @discardableResult
    func importSeeds(from dir: URL, done: Set<String>) -> [String] {
        let fm = FileManager.default
        var imported: [String] = []
        guard fm.fileExists(atPath: dir.path) else { return imported }
        var entries: [SeedTemplate] = []
        if let d = try? Data(contentsOf: dir.appendingPathComponent("seeds.json")),
           let m = try? JSONDecoder().decode(SeedManifest.self, from: d) {
            entries = m.seeds
        } else if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            // No manifest: every .drp is a seed, named after its file.
            entries = files.filter { $0.pathExtension.lowercased() == "drp" }.map {
                let n = $0.deletingPathExtension().lastPathComponent
                let k = n.lowercased().replacingOccurrences(of: " ", with: "-")
                return SeedTemplate(key: k, file: $0.lastPathComponent, name: n)
            }
        }
        for e in entries where !done.contains(e.key) {
            let url = dir.appendingPathComponent(e.file)
            guard fm.fileExists(atPath: url.path) else { continue }
            if all.contains(where: { $0.name == e.name }) {
                imported.append(e.key)   // already here under its own record
                continue
            }
            do {
                _ = try importTemplate(from: url, name: e.name, category: e.category, tags: e.tags)
                imported.append(e.key)
                Log.info("template seeded", ["name": e.name])
            } catch {
                Log.error("seed template skipped", ["file": e.file, "error": "\(error)"])
                imported.append(e.key)   // never retry a seed that cannot import
            }
        }
        return imported
    }
}

/// What can be read from a .drp without Resolve: it is a zip with project.xml (carrying the writing
/// Resolve version) and one folder per media-pool bin under MediaPool/Master. Read-only: bytes are never changed.
struct DrpInfo {
    var listed = false
    var entries: [String] = []
    var appVersion: String?
    var hasProject: Bool { entries.contains("project.xml") }

    /// Nested bins, numeric ordering prefixes ("000_") removed: ["01 Footage", "01 Footage/Camera A", ...].
    var bins: [String] {
        let prefix = "MediaPool/Master/"
        var out: [String] = []
        for e in entries where e.hasPrefix(prefix) && e.hasSuffix("/MpFolder.xml") {
            let parts = e.dropFirst(prefix.count).dropLast("/MpFolder.xml".count).split(separator: "/")
            let clean = parts.map { p -> String in
                let s = String(p)
                if let r = s.range(of: #"^\d{3}_"#, options: .regularExpression) { return String(s[r.upperBound...]) }
                return s
            }
            if !clean.isEmpty { out.append(clean.joined(separator: "/")) }
        }
        return out.sorted()
    }

    static func read(_ url: URL) -> DrpInfo {
        var info = DrpInfo()
        guard let list = run("/usr/bin/unzip", ["-Z1", url.path]) else { return info }
        info.listed = true
        info.entries = list.split(separator: "\n").map(String.init)
        if let head = run("/usr/bin/unzip", ["-p", url.path, "project.xml"], limit: 400),
           let r = head.range(of: #"DbAppVer="([^"]+)""#, options: .regularExpression) {
            info.appVersion = String(head[r]).replacingOccurrences(of: "DbAppVer=", with: "").replacingOccurrences(of: "\"", with: "")
        }
        return info
    }

    func diagnostics(installed: String?) -> [String] {
        var out: [String] = []
        if !listed { out.append("Archive listing unavailable; structure not checked.") }
        if let a = appVersion { out.append("Written by DaVinci Resolve \(a).") } else if listed { out.append("Resolve version not recorded in project.xml.") }
        if let a = appVersion, let i = installed, Self.isNewer(a, than: i) {
            out.append("Made with a newer Resolve (\(a)) than installed (\(i)). It may not open; update Resolve or re-export.")
        }
        out.append("\(bins.count) bin(s) found in the archive.")
        return out
    }

    /// Compares major.minor.patch numerically; build numbers are ignored ("21.1.0.0014" equals "21.1.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").prefix(3).map { Int($0) ?? 0 }, y = b.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func run(_ tool: String, _ args: [String], limit: Int = 2_000_000) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 || !data.isEmpty ? String(decoding: data.prefix(limit), as: UTF8.self) : nil
    }
}
