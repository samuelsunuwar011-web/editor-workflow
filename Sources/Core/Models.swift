import Foundation

// MARK: - App storage

struct AppPaths {
    let root: URL
    var database: URL { root.appendingPathComponent("db.sqlite") }
    var masters: URL { root.appendingPathComponent("masters", isDirectory: true) }
    var thumbnails: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }
    var covers: URL { root.appendingPathComponent("covers", isDirectory: true) }
    var manifests: URL { root.appendingPathComponent("manifests", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appendingPathComponent("EditorWorkflow", isDirectory: true))
    }

    func create() throws {
        for d in [root, masters, thumbnails, manifests, logs] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Volumes

struct VolumeIdentity: Codable, Hashable {
    var uuid: String?
    var name: String
    var mountPath: String
    var capacity: Int64
    var available: Int64
    var fileSystem: String
    var isInternal: Bool
    var isRemovable: Bool
    var isReadOnly: Bool
    var isLocal: Bool
    var caseSensitive: Bool

    /// Same physical volume. Without a UUID we cannot prove identity, so the answer is no:
    /// a same-name card must never be treated as the original.
    func sameDevice(as other: VolumeIdentity) -> Bool {
        guard let a = uuid, let b = other.uuid else { return false }
        return a == b
    }

    var shortID: String { uuid.map { String($0.prefix(8)) } ?? "no-uuid" }
    /// Largest single file the filesystem accepts.
    var maxFileSize: Int64? { fileSystem.lowercased() == "msdos" ? 4_294_967_295 : nil }
}

// MARK: - Transfers

enum TransferMode: String, Codable, CaseIterable {
    case cameraCardBackup, selectiveCopy
    var label: String { self == .cameraCardBackup ? "Camera Card Backup" : "Selective Media Copy" }
}

enum ConflictPolicy: String, Codable, CaseIterable {
    /// Same content: skip. Different content: copy under a new name. Never overwrites.
    case skipIdenticalElseKeepBoth
    case keepBoth
    case skipExisting
    /// Overwrite. Allowed only after explicit confirmation in the review screen.
    case replace
    var label: String {
        switch self {
        case .skipIdenticalElseKeepBoth: return "Smart: skip identical, number the rest (23879 → 23880)"
        case .keepBoth: return "Always keep both (add a number)"
        case .skipExisting: return "Skip any file that already exists"
        case .replace: return "Replace existing files (confirm)"
        }
    }
}

/// How much of a plan is copied when the destination already holds files.
enum CopyScope: String, Codable, CaseIterable {
    /// Copy every selected file; existing names follow the conflict rule.
    case all
    /// Continue after an interruption: files already at the destination with the same content are skipped.
    case continueCopy
    /// Sync-style: only files missing at the destination (or with a different size) are copied.
    case missingOnly
    var label: String {
        switch self {
        case .all: return "Copy everything"
        case .continueCopy: return "Continue: skip files already copied"
        case .missingOnly: return "Only files missing at the destination"
        }
    }
}

enum MediaCategory: String, Codable, CaseIterable {
    case video, audio, photo, raw, sidecar, other
    static func of(_ url: URL) -> MediaCategory {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "mkv", "insv", "lrv": return .video
        case "braw", "r3d", "ari", "crm", "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf": return .raw
        case "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "bwf": return .audio
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "psd", "webp": return .photo
        case "xml", "xmp", "sidecar", "thm", "bim", "cpi", "mpl", "bdm", "smi", "ppn", "rtmd", "bin", "srt": return .sidecar
        default: return .other
        }
    }
}

struct SelectiveFilter: Codable, Hashable {
    var categories: Set<MediaCategory> = [.video, .raw, .audio]
    var extraExtensions: [String] = []
    var excludedExtensions: [String] = []
    var includeHidden = false

    func includes(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if excludedExtensions.map({ $0.lowercased() }).contains(ext) { return false }
        if !includeHidden && url.lastPathComponent.hasPrefix(".") { return false }
        if extraExtensions.map({ $0.lowercased() }).contains(ext) { return true }
        return categories.contains(MediaCategory.of(url))
    }
}

enum ItemState: String, Codable {
    case pending, copying, verified, skippedIdentical, skippedExisting, failed, unverified
    /// Copied and size-matched under the size-only policy; content not checksum-verified.
    case copiedUnverified
    var isDone: Bool { [.verified, .skippedIdentical, .skippedExisting, .copiedUnverified].contains(self) }
}

enum VerificationPolicy: String, Codable, CaseIterable {
    case sha256, sizeOnly
    var label: String { self == .sha256 ? "SHA-256 every file (source and destination)" : "Size only (faster; reported as not verified)" }
}

enum JobStatus: String, Codable {
    case planned, running, paused, interrupted, verified, partiallyVerified, failed, cancelled, copiedUnverified
    var label: String {
        switch self {
        case .planned: return "Planned"
        case .running: return "Running"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .verified: return "Verified"
        case .partiallyVerified: return "Partially verified"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .copiedUnverified: return "Copied, not verified"
        }
    }
}

struct TransferItem: Codable, Identifiable {
    var id: String { relativePath }
    var relativePath: String
    var bytes: Int64
    var state: ItemState = .pending
    var destinationRelativePath: String?
    /// Per-file conflict decision from the review screen; nil uses the job's rule.
    var policy: ConflictPolicy?
    var sourceHash: String?
    var destinationHash: String?
    var message: String?
}

struct TransferJob: Codable, Identifiable {
    var id = UUID()
    var name: String
    var mode: TransferMode
    var filter: SelectiveFilter?
    var conflictPolicy: ConflictPolicy
    /// nil means SHA-256. Camera Card Backup is always SHA-256.
    var verification: VerificationPolicy?
    var sourcePath: String
    var sourceVolume: VolumeIdentity?
    var destinationRoot: String
    /// Folder created inside the destination that mirrors the source.
    var outputPath: String
    var destinationVolume: VolumeIdentity?
    var status: JobStatus = .planned
    var totalBytes: Int64 = 0
    var totalFiles: Int = 0
    /// Files seen while scanning (selected + excluded), for the completion report.
    var scannedFiles: Int?
    var copiedBytes: Int64 = 0
    var doneFiles: Int?
    var created = Date()
    var started: Date?
    var finished: Date?
    var warnings: [String] = []
    var manifestPath: String?
    var projectSessionID: UUID?
    var metadataNotPreserved: [String] = []
    /// Source directories (relative), recreated so empty camera folders survive.
    var directories: [String] = []
    /// nil (old jobs, or "copy everything") means the conflict rule decides for every file.
    var scope: CopyScope?
}

// MARK: - Templates

enum AssetRule: String, Codable, CaseIterable { case keep, replace, optional }
enum AssetKind: String, Codable, CaseIterable { case footage, logo, music, font, lut, fusion, ofx, title, graphic, sfx, other }
enum DependencyStatus: String, Codable, CaseIterable {
    case available, knownMissing, notChecked, incompatible
    var label: String {
        switch self {
        case .available: return "Available"
        case .knownMissing: return "Known missing"
        case .notChecked: return "Not checked"
        case .incompatible: return "Incompatible with this edition"
        }
    }
}

struct AssetRuleEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: AssetKind = .other
    var location: String = ""
    var rule: AssetRule = .keep
    var essential = false
    var status: DependencyStatus = .notChecked
    /// Copy stored with the template (reusable logos, titles, LUTs the editor has rights to).
    var packagedPath: String?
}

struct BinPlanEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Slash-separated nested bin path, e.g. "01 Footage/Camera A".
    var binPath: String
    /// Case-insensitive substring matched against source folder names to suggest this bin.
    var defaultSourceRule: String = ""
    var required = false
}

struct SettingsProfile: Codable, Hashable {
    var width = 3840
    var height = 2160
    var frameRate = "25"
    var timelineName = ""
    /// True only once the editor chose these values. Untouched defaults are a guess, never sent to Resolve.
    /// Optional so records saved before this field still decode.
    var apply: Bool?
    /// Extra Resolve project settings (key -> value), e.g. proxy, color, monitoring, audio. Sent only when `apply`.
    var extra: [String: String]?
    /// Clip-level Input Color Space applied to every video clip this project imports, e.g.
    /// "S-Gamut3.Cine/S-Log3" or "Rec.2100 HLG". Empty/nil keeps what Resolve reads from the file.
    var inputColorSpace: String?
    var orientation: String { width == height ? "Square" : (width > height ? "Horizontal" : "Vertical") }

    /// Clip Input Color Space choices. The value is exactly what Resolve's Clip Attributes accept.
    static let inputColorSpaces: [(label: String, value: String)] = [
        ("Auto (from clip)", ""),
        ("Sony S-Log3 → Rec.709", "S-Gamut3.Cine/S-Log3"),
        ("Sony S-Log2 → Rec.709", "S-Gamut/S-Log2"),
        ("HLG → Rec.709", "Rec.2100 HLG"),
        ("Rec.709 (no conversion)", "Rec.709"),
    ]
    static func inputColorSpaceLabel(_ value: String?) -> String {
        let v = value ?? ""
        return inputColorSpaces.first { $0.value == v }?.label ?? (v.isEmpty ? "Auto (from clip)" : v)
    }

    static let presets: [(String, SettingsProfile)] = [
        ("YouTube 4K landscape", SettingsProfile(width: 3840, height: 2160, frameRate: "25")),
        ("Vertical social", SettingsProfile(width: 1080, height: 1920, frameRate: "30")),
        ("1080p interview", SettingsProfile(width: 1920, height: 1080, frameRate: "25")),
        ("Documentary", SettingsProfile(width: 3840, height: 2160, frameRate: "23.976")),
        ("Commercial", SettingsProfile(width: 3840, height: 2160, frameRate: "24")),
        ("Multicamera event", SettingsProfile(width: 1920, height: 1080, frameRate: "50")),
        ("Wedding long-form", SettingsProfile(width: 3840, height: 2160, frameRate: "25")),
        ("Music video", SettingsProfile(width: 3840, height: 2160, frameRate: "24")),
        ("Square", SettingsProfile(width: 1080, height: 1080, frameRate: "30")),
        // Color managed: every clip is read as Sony S-Log3 and shown as Rec.709, including clips added to the timeline later.
        ("Sony S-Log3 to Rec.709 (4K 25p)", SettingsProfile(width: 3840, height: 2160, frameRate: "25", extra: slog3)),
        ("Sony S-Log3 to Rec.709 (1080p 25p)", SettingsProfile(width: 1920, height: 1080, frameRate: "25", extra: slog3)),
    ]
    /// Resolve Color Management v2: S-Gamut3.Cine/S-Log3 in, DaVinci Wide Gamut timeline, Rec.709 Gamma 2.4 out.
    static let slog3: [String: String] = [
        "colorScienceMode": "davinciYRGBColorManagedv2",
        "separateColorSpaceAndGamma": "0",
        "colorSpaceInput": "S-Gamut3.Cine/S-Log3",
        "colorSpaceTimeline": "DaVinci WG/Intermediate",
        "colorSpaceOutput": "Rec.709 Gamma 2.4",
    ]
    static let frameRates = ["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"]
}

struct TemplateVersion: Codable, Identifiable, Hashable {
    var id: Int { number }
    var number: Int
    var masterPath: String
    var masterHash: String
    var originalFilename: String
    var importedAt = Date()
    var resolveVersion: String?
    var note: String = ""
    var bins: [BinPlanEntry] = []
    var assets: [AssetRuleEntry] = []
    var settings = SettingsProfile()
    var folderScheme: [String] = ["01 Raw Footage", "02 Audio", "03 Graphics", "04 Music", "05 Exports", "Resolve"]
    var testStatus: String = "Not tested"
    /// Diagnostics from reading the .drp (version, structure). Optional so older records decode.
    var diagnostics: [String]?
}

struct Template: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var summary: String = ""
    var category: String = ""
    var tags: [String] = []
    var projectTypes: [String] = []
    var favorite = false
    var thumbnailPath: String?
    /// Cover photo: "<sha1-16>.<ext>#x,y" in AppPaths.covers (see CoverStore). Optional so older records load.
    var cover: String?
    var created = Date()
    var lastUsed: Date?
    var versions: [TemplateVersion]
    var current: TemplateVersion { versions.max { $0.number < $1.number }! }
    func version(_ n: Int) -> TemplateVersion? { versions.first { $0.number == n } }
}

// MARK: - Projects

enum SessionState: String, Codable {
    case draft, manualStepRequired, ready, partiallyCompleted, failed
    var label: String {
        switch self {
        case .draft: return "Draft"
        case .manualStepRequired: return "Manual Step Required"
        case .ready: return "Ready"
        case .partiallyCompleted: return "Partially Completed"
        case .failed: return "Failed"
        }
    }
}

enum MappingAction: String, Codable, CaseIterable {
    case importMedia, createBinAndImport, replaceBranding, optionalImport, later, omit
    var label: String {
        switch self {
        case .importMedia: return "Import"
        case .createBinAndImport: return "Create bin + import"
        case .replaceBranding: return "Replace template branding"
        case .optionalImport: return "Optional import"
        case .later: return "Manual import later"
        case .omit: return "Omit"
        }
    }
}

struct MediaSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var label: String
    var volume: VolumeIdentity?
    var transferJobID: UUID?
}

struct BinMapping: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourcePath: String
    var targetBin: String
    var action: MappingAction = .importMedia
}

struct ResolveReceipt: Codable, Identifiable, Hashable {
    var id = UUID()
    var step: String
    var capability: String
    var status: String // "ok", "failed", "manual", "skipped"
    var errorCode: String?
    var detail: String = ""
    var at = Date()
}

struct ProjectSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var templateID: UUID
    var templateVersion: Int
    var templateName: String
    var projectFolder: String
    var instanceDrpPath: String?
    var sources: [MediaSource] = []
    var mappings: [BinMapping] = []
    var settings = SettingsProfile()
    var state: SessionState = .draft
    var resolveEdition: String = "unknown"
    var resolveProjectName: String?
    var created = Date()
    var receipts: [ResolveReceipt] = []
    var checklistPath: String?
    /// Wizard timing and effort, for local metrics.
    var wizardSeconds: Double?
    var wizardEdits: Int?
}

// MARK: - Helpers

extension Int64 {
    var bytesText: String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false  // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: self)
    }
}

extension String {
    /// NFC + case-folded key for collision checks.
    var collisionKey: String { precomposedStringWithCanonicalMapping.lowercased() }
}

/// Plain-text error used where a reason is shown to the user as-is.
struct Reason: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
