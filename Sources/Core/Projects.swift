import Foundation

enum ProjectError: Error, CustomStringConvertible {
    case masterChanged, destinationMissing(String), destinationInsideSource(String)
    var description: String {
        switch self {
        case .masterChanged: return "The template master no longer matches its checksum. Nothing was created."
        case .destinationMissing(let p): return "Destination folder is not available: \(p)"
        case .destinationInsideSource(let p): return "The project folder would be inside the footage folder (\(p)). Choose a project folder outside the footage, or the project would copy itself."
        }
    }
}

/// Wizard progress, saved after every change so an accidental close loses nothing.
struct WizardDraft: Codable, Equatable {
    var step = 0
    var templateID: UUID?
    var projectName = ""
    var destinationRoot = ""
    var createFolders = true
    var sources: [MediaSource] = []
    var mappings: [BinMapping] = []
    var settings: SettingsProfile?
    var startedAt: Date?
    var edits: Int?
}

final class ProjectStore {
    let db: Database
    let templates: TemplateStore

    init(db: Database, templates: TemplateStore) { self.db = db; self.templates = templates }

    var all: [ProjectSession] { db.all("session") }
    func get(_ id: UUID) -> ProjectSession? { db.get("session", id: id.uuidString) }
    func save(_ s: ProjectSession) throws { try db.save("session", id: s.id.uuidString, s) }
    func delete(_ id: UUID) throws { try db.delete("session", id: id.uuidString) }

    var draft: WizardDraft? { db.get("draft", id: "wizard") }
    func saveDraft(_ d: WizardDraft) { try? db.save("draft", id: "wizard", d) }
    func clearDraft() { try? db.delete("draft", id: "wizard") }

    /// Remembered mappings per template (source label -> bin).
    func rememberedMappings(_ templateID: UUID) -> [String: String] { db.get("mapmemory", id: templateID.uuidString) ?? [:] }
    func remember(_ mappings: [BinMapping], for templateID: UUID) {
        var m = rememberedMappings(templateID)
        for x in mappings where x.action != .omit { m[URL(fileURLWithPath: x.sourcePath).lastPathComponent.collisionKey] = x.targetBin }
        try? db.save("mapmemory", id: templateID.uuidString, m)
    }

    /// Fills a naming preset: {template}, {category}, {date} (yyyy-MM-dd), {year}. Unknown tokens stay as typed.
    static func applyPattern(_ pattern: String, template: Template?, date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return pattern
            .replacingOccurrences(of: "{template}", with: template?.name ?? "")
            .replacingOccurrences(of: "{category}", with: template?.category ?? "")
            .replacingOccurrences(of: "{date}", with: f.string(from: date))
            .replacingOccurrences(of: "{year}", with: String(Calendar.current.component(.year, from: date)))
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Name", then "Name (2)", "Name (3)"… avoiding every name in `taken` (case-insensitive).
    static func uniqueName(_ name: String, taken: [String]) -> String {
        let t = Set(taken.map(\.collisionKey))
        if !t.contains(name.collisionKey) { return name }
        for n in 2... { let c = "\(name) (\(n))"; if !t.contains(c.collisionKey) { return c } }
        return name
    }

    /// One mapping row per immediate sub-folder of each source (or the source itself when it holds files directly).
    /// After the footage is copied into the project: point every mapping at the copy instead of the original.
    static func remap(_ mappings: [BinMapping], from original: String, to copy: String) -> [BinMapping] {
        mappings.map { m in
            var n = m
            if m.sourcePath == original { n.sourcePath = copy }
            else if m.sourcePath.hasPrefix(original + "/") { n.sourcePath = copy + m.sourcePath.dropFirst(original.count) }
            return n
        }
    }

    /// Folders holding files Resolve can import. Sidecar-only folders are not rows.
    static func isImportable(_ url: URL) -> Bool {
        switch MediaCategory.of(url) {
        case .video, .audio, .raw, .photo: return true
        default: return false
        }
    }

    /// A project created by this app: it has a Resolve folder with a .drp inside.
    static func isProjectFolder(_ url: URL) -> Bool {
        let resolveDir = url.appendingPathComponent("Resolve", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resolveDir.path) else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resolveDir.path)) ?? []
        return names.contains { $0.lowercased().hasSuffix(".drp") }
    }

    /// Adds `m` when its folder holds files directly (or is a file), then one nested bin per subfolder, up to 6 levels.
    static func mirror(_ m: BinMapping, into out: inout [BinMapping], depth: Int) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: m.sourcePath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else { out.append(m); return }
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let subs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !Self.isProjectFolder($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if items.contains(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && Self.isImportable($0) }) { out.append(m) }
        guard depth < 6 else { return }
        for sub in subs {
            // Under a real bin, subfolders nest as bins; under the Master bin they stay at the top level too.
            let bin = m.targetBin.isEmpty ? "" : "\(m.targetBin)/\(sub.lastPathComponent)"
            mirror(BinMapping(sourcePath: sub.path, targetBin: bin, action: m.targetBin.isEmpty ? .importMedia : .createBinAndImport), into: &out, depth: depth + 1)
        }
    }

    func suggestMappings(sources: [MediaSource], bins: [BinPlanEntry], templateID: UUID?) -> [BinMapping] {
        let memory = templateID.map(rememberedMappings) ?? [:]
        var out: [BinMapping] = []
        for s in sources {
            let url = URL(fileURLWithPath: s.path)
            let subs = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !Self.isProjectFolder($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let hasFiles = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? [])
                .contains { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && Self.isImportable($0) }
            let folders = subs.isEmpty || hasFiles ? [url] : subs
            for f in folders {
                let label = f.lastPathComponent
                let base: BinMapping
                if let bin = memory[label.collisionKey] {
                    base = BinMapping(sourcePath: f.path, targetBin: bin, action: bins.contains { $0.binPath == bin } ? .importMedia : .createBinAndImport)
                } else if let bin = bins.first(where: { !$0.defaultSourceRule.isEmpty && label.collisionKey.contains($0.defaultSourceRule.collisionKey) }) {
                    base = BinMapping(sourcePath: f.path, targetBin: bin.binPath, action: .importMedia)
                } else {
                    // No bin chosen or matched: the clips go in the Master bin (top level), not into a new bin.
                    base = BinMapping(sourcePath: f.path, targetBin: "", action: .importMedia)
                }
                // The folder's own files go in its bin; every subfolder becomes a bin inside it, nested like on disk.
                Self.mirror(base, into: &out, depth: 0)
            }
        }
        return out
    }

    /// Creates the project folder, a distinct .drp instance and a guided checklist.
    /// The session starts as "Manual Step Required"; Studio automation may upgrade it after real receipts.
    func create(name: String, template: Template, destinationRoot: URL, createFolders: Bool, sources: [MediaSource],
                mappings: [BinMapping], settings: SettingsProfile, wizardSeconds: Double? = nil, wizardEdits: Int? = nil) throws -> ProjectSession {
        let v = template.current
        guard templates.verifyMaster(v) else { throw ProjectError.masterChanged }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationRoot.path, isDirectory: &isDir), isDir.boolValue else { throw ProjectError.destinationMissing(destinationRoot.path) }

        let existing = (try? fm.contentsOfDirectory(atPath: destinationRoot.path)) ?? []
        let folderName = Self.uniqueName(name.replacingOccurrences(of: "/", with: "-"), taken: existing)
        let folder = destinationRoot.appendingPathComponent(folderName, isDirectory: true)
        // A project made inside its own footage would appear as a source folder on the next scan.
        for src in sources {
            let source = URL(fileURLWithPath: src.path).standardizedFileURL.path
            let dest = folder.standardizedFileURL.path
            if dest == source || dest.hasPrefix(source + "/") { throw ProjectError.destinationInsideSource(source) }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        if createFolders { for sub in v.folderScheme { try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true) } }

        let resolveDir = folder.appendingPathComponent("Resolve", isDirectory: true)
        try fm.createDirectory(at: resolveDir, withIntermediateDirectories: true)
        let instance = resolveDir.appendingPathComponent("\(folderName).drp")
        try fm.copyItem(atPath: v.masterPath, toPath: instance.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: instance.path)
        guard templates.verifyMaster(v) else { throw ProjectError.masterChanged }

        var s = ProjectSession(name: folderName, templateID: template.id, templateVersion: v.number, templateName: template.name,
                               projectFolder: folder.path, instanceDrpPath: instance.path, sources: sources, mappings: mappings, settings: settings)
        s.state = .manualStepRequired
        s.wizardSeconds = wizardSeconds; s.wizardEdits = wizardEdits
        s.receipts = [ResolveReceipt(step: "Prepare template instance", capability: "local", status: "ok", detail: instance.path)]
        let checklist = resolveDir.appendingPathComponent("IMPORT CHECKLIST.txt")
        try Self.checklist(for: s, version: v).write(to: checklist, atomically: false, encoding: .utf8)
        s.checklistPath = checklist.path
        try save(s)

        var t = template; t.lastUsed = Date(); try? templates.updateMetadata(t)
        remember(mappings, for: template.id)
        return s
    }

    static func checklist(for s: ProjectSession, version v: TemplateVersion) -> String {
        var lines = [
            "PROJECT: \(s.name)",
            "Template: \(s.templateName) v\(s.templateVersion)",
            "Created: \(ISO8601DateFormatter().string(from: s.created))",
            "",
            "These steps are manual. The app has not imported anything into Resolve.",
            "",
            "1. In DaVinci Resolve, open the Project Manager and choose Import Project.",
            "   File: \(s.instanceDrpPath ?? "?")",
            "   Name it: \(s.name)",
            "2. Open the project. In the Media Pool, create or confirm these bins and import media:",
        ]
        for m in s.mappings {
            switch m.action {
            case .omit: continue
            case .later: lines.append("   [later]  \(m.targetBin)  <-  \(m.sourcePath)")
            case .optionalImport: lines.append("   [optional]  \(m.targetBin)  <-  \(m.sourcePath)")
            case .replaceBranding:
                lines.append("   [ ] Replace template branding in \(m.targetBin) with  \(m.sourcePath)  (remove the old client's logo)")
            case .importMedia, .createBinAndImport:
                lines.append("   [ ] \(m.action == .createBinAndImport ? "Create bin " : "")\(m.targetBin)  <-  import folder \(m.sourcePath)")
            }
        }
        if let cs = s.settings.inputColorSpace, !cs.isEmpty {
            lines.append("   [ ] Select the imported video clips in the Media Pool, right-click > Input Color Space > \(SettingsProfile.inputColorSpaceLabel(cs)).")
        }
        lines += [s.settings.apply == true ? "3. Check project settings: \(s.settings.width)x\(s.settings.height) at \(s.settings.frameRate) fps." : "3. Project settings: keep the template's own resolution and frame rate.",
                  "   Do not change the frame rate of a timeline that already contains clips."]
        let replace = v.assets.filter { $0.rule == .replace }
        if !replace.isEmpty {
            lines.append("4. Replace template assets:")
            lines += replace.map { "   [ ] \($0.name) (\($0.kind.rawValue))\($0.location.isEmpty ? "" : " at \($0.location)")" }
        }
        let optional = v.assets.filter { $0.rule == .optional }
        if !optional.isEmpty {
            lines.append("5. Optional assets to choose for this job:")
            lines += optional.map { "   [ ] \($0.name) (\($0.kind.rawValue))" }
        }
        let missing = v.assets.filter { $0.status == .knownMissing || $0.status == .incompatible }
        if !missing.isEmpty {
            lines.append("Warnings - dependencies to locate, replace or omit:")
            lines += missing.map { "   ! \($0.name): \($0.status.label)\($0.essential ? " (essential)" : "")" }
        }
        lines += ["", "When done, mark the project as imported in the app's Projects screen."]
        return lines.joined(separator: "\n")
    }

    /// Derives the truthful session state from Resolve receipts.
    static func state(from receipts: [ResolveReceipt]) -> SessionState {
        // A retry appends receipts; only the latest result of each step counts.
        var latest: [String: ResolveReceipt] = [:], order: [String] = []
        for r in receipts where r.capability != "local" {
            if latest[r.step] == nil { order.append(r.step) }
            latest[r.step] = r
        }
        let resolveSteps = order.compactMap { latest[$0] }
        if resolveSteps.isEmpty { return .manualStepRequired }
        if resolveSteps.contains(where: { $0.status == "failed" && ["canImportProject", "canOpenProject", "bridge"].contains($0.capability) }) { return .failed }
        if resolveSteps.allSatisfy({ $0.status == "manual" }) { return .manualStepRequired }
        if resolveSteps.contains(where: { $0.status != "ok" }) { return .partiallyCompleted }
        return .ready
    }
}
