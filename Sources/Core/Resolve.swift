import Foundation
import CoreText

/// Which automated steps are proven per Resolve major.minor version.
enum Capabilities {
    static let all = ["canImportProject", "canOpenProject", "canCreateBin", "canImportMedia", "canSetSetting"]
    /// Proven live in Gate 0 and later runs (docs/capability-matrix.md).
    static let builtIn: [String: [String: Bool]] = ["21.1": Dictionary(uniqueKeysWithValues: all.map { ($0, true) })]
    static func key(_ version: String?) -> String { (version ?? "").split(separator: ".").prefix(2).joined(separator: ".") }
}

enum ResolveEdition: String, Codable { case studio, free, notInstalled, unknown
    var label: String {
        switch self {
        case .studio: return "Studio"
        case .free: return "Free"
        case .notInstalled: return "Not installed"
        case .unknown: return "Unknown"
        }
    }
}

struct ResolveStatus: Equatable {
    var installed: Bool
    var installedVersion: String?
    var reachable: Bool
    var product: String?
    var liveVersion: String?
    var edition: ResolveEdition
    var projects: [String] = []
    var message: String
    /// Capability -> proven on this version. Empty when the version was never tested.
    var capabilities: [String: Bool] = [:]
    var capabilitySource = "none"

    /// Studio automation only when the bridge works, the live product is Studio, and at least one step is proven on this version.
    var canAutomate: Bool { reachable && edition == .studio && capabilities.values.contains(true) }
    var needsSelfTest: Bool { reachable && edition == .studio && capabilities.isEmpty }
}

/// Talks to Resolve through `resolve_bridge.py`. Only capabilities proven in docs/capability-matrix.md are used.
final class ResolveAdapter {
    /// Where Resolve is installed; the user can choose another location in Settings.
    nonisolated(unsafe) static var appPath = defaultAppPath() ?? "/Applications/DaVinci Resolve/DaVinci Resolve.app"
    static func defaultAppPath() -> String? {
        ["/Applications/DaVinci Resolve/DaVinci Resolve.app", "/Applications/DaVinci Resolve Studio/DaVinci Resolve Studio.app",
         "/Applications/DaVinci Resolve.app"].first { FileManager.default.fileExists(atPath: $0) }
    }
    static let modules = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"

    let bridge: URL
    /// Stored self-test results per version key ("21.2"), supplied by the app's database.
    var storedCapabilities: (String) -> [String: Bool]? = { _ in nil }
    init(bridge: URL) { self.bridge = bridge }

    static func installedVersion() -> String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
    }

    static func python() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the bridge with a JSON command. Returns the decoded JSON object or an error dictionary.
    func call(_ command: [String: Any], timeout: TimeInterval = 120) -> [String: Any] {
        guard let py = Self.python() else { return ["reachable": false, "error": "python_missing", "detail": "python3 not found"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [bridge.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = Self.modules
        env["RESOLVE_SCRIPT_API"] = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
        env["RESOLVE_SCRIPT_LIB"] = Self.appPath + "/Contents/Libraries/Fusion/fusionscript.so"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe
        // Drain stderr to /dev/null: an undrained pipe fills and deadlocks a chatty Python traceback.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ["reachable": false, "error": "launch_failed", "detail": error.localizedDescription] }
        inPipe.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: command)) ?? Data())
        try? inPipe.fileHandleForWriting.close()
        var data = Data()
        let reader = DispatchQueue(label: "bridge.read")
        let group = DispatchGroup(); group.enter()
        reader.async { data = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return ["reachable": false, "error": "timeout", "detail": "Resolve did not answer within \(Int(timeout)) s"]
        }
        p.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            ?? ["reachable": false, "error": "bad_output", "detail": String(line.prefix(300))]
    }

    func status() -> ResolveStatus {
        let installed = Self.installedVersion()
        guard installed != nil else {
            return ResolveStatus(installed: false, reachable: false, edition: .notInstalled, message: "DaVinci Resolve was not found in /Applications.")
        }
        let r = call(["cmd": "probe"], timeout: 20)
        if r["reachable"] as? Bool == true, let product = r["product"] as? String {
            let studio = r["studio"] as? Bool ?? false
            let live = r["version"] as? String
            let key = Capabilities.key(live)
            var st = ResolveStatus(installed: true, installedVersion: installed, reachable: true, product: product,
                                   liveVersion: live, edition: studio ? .studio : .free,
                                   projects: r["projects"] as? [String] ?? [],
                                   message: studio ? "Studio automation available for proven steps." : "Resolve Free: guided manual import.")
            if studio {
                if let stored = storedCapabilities(key) { st.capabilities = stored; st.capabilitySource = "self-test on \(key)" }
                else if let b = Capabilities.builtIn[key] { st.capabilities = b; st.capabilitySource = "tested by the app on \(key)" }
                else { st.message = "Resolve \(key) has not been tested. Run the capability self-test in Settings; until then the guided workflow is used." }
            }
            return st
        }
        // Not reachable: edition cannot be proven (Studio and Free share the app name), so guide manually.
        return ResolveStatus(installed: true, installedVersion: installed, reachable: false, edition: .unknown,
                             message: (r["detail"] as? String) ?? "Resolve scripting is not reachable. Using guided manual import.")
    }

    /// Receipt step name, the same one the bridge writes: one per folder, so a retry skips exactly the folders already in.
    static func importStep(_ m: BinMapping) -> String {
        "Import into \(m.targetBin.isEmpty ? "Master bin" : m.targetBin): \(URL(fileURLWithPath: m.sourcePath).lastPathComponent)"
    }

    /// Builds the bridge plan from a session's mappings.
    /// On a retry, reuses the Resolve project from the earlier run and skips imports that already succeeded.
    static func plan(for s: ProjectSession, version v: TemplateVersion, masterPath: String, allowed: [String] = Capabilities.all) -> [String: Any] {
        let done = Set(s.receipts.filter { $0.status == "ok" && $0.capability == "canImportMedia" }.map(\.step))
        let active = s.mappings.filter { [.importMedia, .createBinAndImport, .replaceBranding, .optionalImport].contains($0.action) && !done.contains(Self.importStep($0)) }
        var bins: [String] = []
        // "" is the Master bin: it always exists, nothing to create.
        for b in v.bins.map(\.binPath) + active.map(\.targetBin) where !b.isEmpty && !bins.contains(b) { bins.append(b) }
        // Import the project's own instance copy, never the library master. After the run the bridge
        // exports the saved project back to this same file, so the folder stays a real project copy.
        let instance = s.instanceDrpPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        // Reuse a Resolve project only when this session actually imported it. A same-named project
        // made by the editor must never receive this project's clips.
        let importedName = s.receipts.last { $0.step == "Import project" && $0.status == "ok" }?.detail
        let existing = (s.resolveProjectName != nil && importedName == s.resolveProjectName) ? s.resolveProjectName! : ""
        // Project settings travel only when the editor chose them. Clip input color space is separate:
        // it applies to the imported clips even when resolution and frame rate stay untouched.
        let settings: [String: Any] = {
            guard s.settings.apply == true else { return [:] }
            return ["width": s.settings.width, "height": s.settings.height, "frameRate": s.settings.frameRate,
                    "extra": s.settings.extra ?? [:]]
        }()
        return [
            "drp": instance ?? masterPath,
            "exportDrp": instance ?? "",
            "projectName": s.name,
            "bins": bins,
            "imports": active.map { ["bin": $0.targetBin, "paths": [$0.sourcePath], "optional": $0.action == .optionalImport] },
            "settings": settings,
            "inputColorSpace": s.settings.inputColorSpace ?? "",
            "existingProject": existing,
            "allowed": allowed,
            "timelineName": s.settings.timelineName,
        ]
    }

    /// Studio: runs proven steps and returns one receipt per step. Imports from the project's own
    /// `.drp` instance; the bridge writes the saved project back to that file after the run.
    func automate(_ s: ProjectSession, version v: TemplateVersion, allowed: [String]) -> (projectName: String?, receipts: [ResolveReceipt]) {
        let r = call(["cmd": "run", "plan": Self.plan(for: s, version: v, masterPath: v.masterPath, allowed: allowed)], timeout: 600)
        guard r["reachable"] as? Bool == true, r["error"] == nil else {
            let code = r["error"] as? String
            // A timeout does not prove failure: Resolve may still be importing. Do not report failed.
            if code == "timeout" {
                return (nil, [ResolveReceipt(step: "Connect to Resolve", capability: "bridge", status: "manual",
                                             errorCode: code,
                                             detail: "Resolve did not answer in time and may still be importing. Wait for it to finish, then retry; the project folder copy is not opened automatically.")])
            }
            return (nil, [ResolveReceipt(step: "Connect to Resolve", capability: "bridge", status: "failed",
                                         errorCode: code, detail: r["detail"] as? String ?? "")])
        }
        var out: [ResolveReceipt] = []
        for d in r["receipts"] as? [[String: Any]] ?? [] {
            out.append(ResolveReceipt(step: d["step"] as? String ?? "?", capability: d["capability"] as? String ?? "?",
                                      status: d["status"] as? String ?? "failed", errorCode: d["errorCode"] as? String,
                                      detail: d["detail"] as? String ?? ""))
        }
        let doneSteps = Set(s.receipts.filter { $0.status == "ok" }.map(\.step))
        for m in s.mappings where m.action == .later && !doneSteps.contains(Self.importStep(m)) {
            out.append(ResolveReceipt(step: Self.importStep(m), capability: "canImportMedia", status: "manual", detail: "Marked for manual import later: \(m.sourcePath)"))
        }
        return (r["projectName"] as? String, out)
    }

    /// Studio: opens an existing Resolve project by name instead of importing a second copy from disk.
    func openProject(named name: String) -> (reachable: Bool, opened: Bool) {
        guard !name.isEmpty else { return (false, false) }
        let r = call(["cmd": "open", "name": name], timeout: 25)
        return (r["reachable"] as? Bool == true, r["opened"] as? Bool == true)
    }

    struct CurrentProject { var name: String; var drp: URL; var bins: [String]; var settings: SettingsProfile }

    /// Studio: exports the project open in Resolve to `folder` and reads its bins and settings.
    func exportCurrent(to folder: URL) -> Result<CurrentProject, Reason> {
        let path = folder.appendingPathComponent("resolve-export-\(UUID().uuidString.prefix(8)).drp")
        let r = call(["cmd": "current", "exportPath": path.path])
        guard r["reachable"] as? Bool == true, r["error"] == nil else { return .failure(Reason(r["detail"] as? String ?? "Resolve is not reachable.")) }
        guard r["exported"] as? Bool == true, FileManager.default.fileExists(atPath: path.path) else { return .failure(Reason("Resolve did not export the project.")) }
        var settings = SettingsProfile()
        settings.width = Int(r["width"] as? String ?? "") ?? settings.width
        settings.height = Int(r["height"] as? String ?? "") ?? settings.height
        settings.frameRate = (r["frameRate"] as? String).map { $0.hasSuffix(".0") ? String($0.dropLast(2)) : $0 } ?? settings.frameRate
        return .success(CurrentProject(name: r["name"] as? String ?? "Resolve project", drp: path, bins: r["bins"] as? [String] ?? [], settings: settings))
    }

    /// Studio: opens a throwaway copy of the master in Resolve and reports each media reference as available or missing.
    func scanDependencies(_ drp: String) -> Result<[AssetRuleEntry], Reason> {
        let r = call(["cmd": "inspect", "drp": drp])
        guard r["reachable"] as? Bool == true, r["error"] == nil else { return .failure(Reason(r["detail"] as? String ?? "Resolve is not reachable.")) }
        return .success(Self.assets(fromScan: r))
    }

    /// Converts a scan result into asset rules. Fonts are checked against installed fonts; LUTs against Resolve's LUT folders;
    /// OFX plugins cannot be verified from outside Resolve and stay "Not checked".
    static func assets(fromScan r: [String: Any]) -> [AssetRuleEntry] {
        let clips = r["clips"] as? [[String: Any]] ?? []
        var out: [AssetRuleEntry] = clips.compactMap { c in
            guard let path = c["path"] as? String, !path.isEmpty else { return nil }
            let type = (c["type"] as? String ?? "").lowercased()
            // Resolve reports "Video + Audio" for most clips: check video before audio.
            let kind: AssetKind = type.contains("video") ? .footage : (type.contains("audio") ? .music : (type.contains("still") || type.contains("image") ? .graphic : .footage))
            return AssetRuleEntry(name: c["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent, kind: kind, location: path,
                                  rule: kind == .footage ? .replace : .keep, status: (c["exists"] as? Bool ?? false) ? .available : .knownMissing)
        }
        let families = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).map { $0.lowercased() })
        for f in r["fonts"] as? [String] ?? [] {
            out.append(AssetRuleEntry(name: f, kind: .font, location: "Text+ font", rule: .keep, essential: true,
                                      status: families.contains(f.lowercased()) ? .available : .knownMissing))
        }
        let lutDirs = ["/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT",
                       NSHomeDirectory() + "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"]
        for l in r["luts"] as? [String] ?? [] {
            let found = l.hasPrefix("/") ? FileManager.default.fileExists(atPath: l) : lutDirs.contains { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(l)) }
            out.append(AssetRuleEntry(name: (l as NSString).lastPathComponent, kind: .lut, location: l, rule: .keep, status: found ? .available : .knownMissing))
        }
        for o in r["ofx"] as? [String] ?? [] {
            out.append(AssetRuleEntry(name: o, kind: .ofx, location: "OFX plugin", rule: .keep, status: .notChecked))
        }
        for t in r["titles"] as? [String] ?? [] {
            out.append(AssetRuleEntry(name: t, kind: .title, location: "Fusion title on timeline", rule: .keep, status: .available))
        }
        return out
    }

    /// Runs every automated capability on throwaway projects; results are stored per version by the caller.
    func selfTest(clip: URL, tmp: URL) -> Result<[String: Bool], Reason> {
        let r = call(["cmd": "selftest", "clip": clip.path, "tmp": tmp.path], timeout: 180)
        guard r["reachable"] as? Bool == true, r["error"] == nil, let res = r["results"] as? [String: Bool] else {
            return .failure(Reason(r["detail"] as? String ?? "Resolve is not reachable."))
        }
        return .success(res)
    }
}
