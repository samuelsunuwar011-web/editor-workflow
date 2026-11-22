import Foundation

/// Exports every template of this Mac's library into a seed folder for bundling into the app:
/// <name>.drp + <name>.cover.json (photo) + seeds.json (name, category, tags, summary).
/// Run from scripts/seed.sh before packaging, so a fresh install gets these templates.
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: export_seeds <out-dir>\n".data(using: .utf8)!)
    exit(2)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let paths = AppPaths.standard

let db = try Database(path: paths.database.path)
let store = TemplateStore(db: db, paths: paths)
let all = store.all.sorted { $0.name.lowercased() < $1.name.lowercased() }
guard !all.isEmpty else {
    FileHandle.standardError.write("No templates in \(paths.root.path)\n".data(using: .utf8)!)
    exit(1)
}

try? fm.removeItem(at: out)
try fm.createDirectory(at: out, withIntermediateDirectories: true)

var seeds: [SeedTemplate] = []
var seen = Set<String>()
for t in all {
    let drp = try store.export(t.id, to: out)
    var key = drp.deletingPathExtension().lastPathComponent.lowercased()
    key = key.replacingOccurrences(of: " ", with: "-")
    if !seen.insert(key).inserted { continue }   // two names that sanitize alike: keep the first
    seeds.append(SeedTemplate(key: key, file: drp.lastPathComponent, name: t.name,
                              category: t.category, summary: t.summary, tags: t.tags))
}

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(SeedManifest(seeds: seeds)).write(to: out.appendingPathComponent("seeds.json"))
print("Exported \(seeds.count) templates into \(out.path)")
