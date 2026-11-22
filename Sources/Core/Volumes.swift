import Foundation
import DiskArbitration

enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeTypeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeSupportsCaseSensitiveNamesKey, .volumeURLKey,
    ]

    /// Identity of the volume that contains `url`.
    static func identity(of url: URL) -> VolumeIdentity? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // ImportantUsage can report 0 (e.g. on some volumes or sandboxes); fall back to the plain value.
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        let avail = important > 0 ? important : Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeIdentity(
            uuid: v.volumeUUIDString,
            name: v.volumeName ?? url.lastPathComponent,
            mountPath: v.volume?.path ?? "/",
            capacity: Int64(v.volumeTotalCapacity ?? 0),
            available: avail,
            fileSystem: v.volumeTypeName ?? "unknown",
            // A card in the Mac's built-in SD slot reports "internal"; anything removable/ejectable counts as external.
            isInternal: (v.volumeIsInternal ?? false) && !((v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)),
            isRemovable: (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false),
            isReadOnly: v.volumeIsReadOnly ?? false,
            isLocal: v.volumeIsLocal ?? true,
            caseSensitive: v.volumeSupportsCaseSensitiveNames ?? false)
    }

    /// User-visible mounted volumes (internal disk, external drives, cards, network shares).
    static func mounted() -> [VolumeIdentity] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        // Mounted .dmg installers are never footage or a copy target: leave them out.
        return urls.compactMap(identity(of:)).filter { !isDiskImage($0.mountPath) }
    }

    /// True for a mounted disk image (.dmg, .sparsebundle), per Disk Arbitration's device description.
    static func isDiskImage(_ mountPath: String) -> Bool {
        guard mountPath != "/", let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: mountPath) as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        let model = (desc[kDADiskDescriptionDeviceModelKey] as? String) ?? ""
        let proto = (desc[kDADiskDescriptionDeviceProtocolKey] as? String) ?? ""
        return model.localizedCaseInsensitiveContains("disk image") || proto == "Virtual Interface"
    }

    /// Volume whose UUID matches, wherever it is mounted now.
    static func find(_ id: VolumeIdentity) -> VolumeIdentity? {
        mounted().first { $0.sameDevice(as: id) }
    }

    /// Re-anchor a path recorded on `old` to where that same device is mounted now.
    static func remap(_ path: String, from old: VolumeIdentity) -> String? {
        guard let now = find(old) else { return nil }
        guard path.hasPrefix(old.mountPath) else { return path }
        let rel = String(path.dropFirst(old.mountPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? now.mountPath : (now.mountPath as NSString).appendingPathComponent(rel)
    }
}

struct FolderHit: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var volumeName: String
    var volumeShortID: String
    var isFolder = true
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

enum FolderSearch {
    /// Folder-name search inside explicit roots only. No system-wide index is used or promised.
    static func search(_ query: String, in roots: [URL], limit: Int = 300, maxDepth: Int = 6, includeFiles: Bool = false, isCancelled: () -> Bool = { false }) -> [FolderHit] {
        let q = query.collisionKey
        guard !q.isEmpty else { return [] }
        var hits: [FolderHit] = []
        for root in roots {
            let vol = Volumes.identity(of: root)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if isCancelled() || hits.count >= limit { return hits }
                if e.level > maxDepth { e.skipDescendants(); continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                guard isDir || includeFiles else { continue }
                if url.lastPathComponent.collisionKey.contains(q) {
                    hits.append(FolderHit(path: url.path, name: url.lastPathComponent, volumeName: vol?.name ?? "?", volumeShortID: vol?.shortID ?? "?", isFolder: isDir))
                }
            }
        }
        return hits
    }
}

extension URL {
    /// Canonical path via realpath(3): resolves /tmp -> /private/tmp and every symlink, so prefix checks are reliable.
    var canonical: URL {
        guard let p = realpath(path, nil) else { return standardizedFileURL }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p))
    }
}
