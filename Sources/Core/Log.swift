import Foundation

/// Local structured log: one JSON object per line in logs/app.log, rotated at 5 MB.
/// Errors get a short ID the user can quote; nothing is sent anywhere.
enum Log {
    nonisolated(unsafe) static var directory: URL?
    private static let lock = NSLock()

    @discardableResult
    static func event(_ level: String, _ message: String, _ context: [String: String] = [:]) -> String {
        let id = "EW-" + String(UUID().uuidString.prefix(6))
        guard let dir = directory else { return id }
        var obj: [String: String] = ["id": id, "level": level, "message": message, "time": ISO8601DateFormatter().string(from: Date())]
        for (k, v) in context { obj[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return id }
        lock.lock(); defer { lock.unlock() }
        let url = dir.appendingPathComponent("app.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 5_000_000 {
            let old = dir.appendingPathComponent("app.1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return id }
        defer { close(fd) }
        (data + Data("\n".utf8)).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        return id
    }

    @discardableResult static func info(_ m: String, _ c: [String: String] = [:]) -> String { event("info", m, c) }
    @discardableResult static func error(_ m: String, _ c: [String: String] = [:]) -> String { event("error", m, c) }
}
