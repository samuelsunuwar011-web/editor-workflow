import Foundation
import CryptoKit

/// Template cover photos (Folder Photo Feature Guide): one local copy per image, named by content,
/// stored as "<sha1-16>.<ext>#x,y" where x,y is the framing in percent (omitted when centered).
struct CoverStore {
    let dir: URL
    static let maxBytes = 12 * 1024 * 1024

    enum CoverError: Error, CustomStringConvertible {
        case notImage, tooLarge, badResponse
        var description: String {
            switch self {
            case .notImage: return "That file is not a JPEG, PNG, GIF or WebP image."
            case .tooLarge: return "That image is larger than 12 MB."
            case .badResponse: return "The image could not be downloaded."
            }
        }
    }

    /// Real image type from the first bytes; names and extensions are never trusted.
    static func imageExtension(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return nil
    }

    /// Stores the image once (same content, same name) and returns its file name.
    func save(_ data: Data) throws -> String {
        guard data.count <= Self.maxBytes else { throw CoverError.tooLarge }
        guard let ext = Self.imageExtension(data) else { throw CoverError.notImage }
        let name = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16) + "." + ext
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(name))
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        return String(name)
    }

    /// Downloads an https image: redirects followed, image/* only, 12 MB cap, 15 s timeout.
    static func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw CoverError.badResponse }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode),
              (h.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/") else { throw CoverError.badResponse }
        guard data.count <= maxBytes else { throw CoverError.tooLarge }
        return data
    }

    /// An image address, or a web page (a Pinterest pin, say) whose og:image is used.
    static func downloadImageOrPage(_ url: URL) async throws -> Data {
        do { return try await download(url) } catch CoverError.badResponse {
            guard url.scheme == "https" else { throw CoverError.badResponse }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let s = ogImage(String(decoding: data.prefix(3_000_000), as: UTF8.self)),
                  let img = URL(string: s), img.scheme == "https" else { throw CoverError.badResponse }
            return try await download(img)
        }
    }

    /// The page's share image: <meta property="og:image" content="…"> in either attribute order.
    static func ogImage(_ html: String) -> String? {
        let patterns = [#"<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]*content=["']([^"']+)["']"#,
                        #"<meta[^>]+content=["']([^"']+)["'][^>]*property=["']og:image(?::secure_url)?["']"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            return html[r].replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// "file.jpg#30,60" -> (file URL, 30, 60). Anything not in exactly this shape is rejected.
    func parse(_ value: String?) -> (url: URL, x: Double, y: Double)? {
        guard let value else { return nil }
        let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
        let name = parts[0]
        guard name.range(of: #"^[0-9a-f]{16}\.(jpg|png|gif|webp)$"#, options: .regularExpression) != nil else { return nil }
        var x = 50.0, y = 50.0
        if parts.count == 2 {
            let p = parts[1].split(separator: ",").compactMap { Double($0) }
            guard p.count == 2 else { return nil }
            x = min(100, max(0, p[0])); y = min(100, max(0, p[1]))
        }
        return (dir.appendingPathComponent(name), x, y)
    }

    static func value(_ name: String, x: Double = 50, y: Double = 50) -> String {
        let rx = Int(x.rounded()), ry = Int(y.rounded())
        return rx == 50 && ry == 50 ? name : "\(name)#\(rx),\(ry)"
    }

    // MARK: Export / import (image packed into the file; local paths never travel)

    struct Packed: Codable { var pos: String?; var base64: String }

    func pack(_ value: String?) -> Packed? {
        guard let p = parse(value), let d = try? Data(contentsOf: p.url) else { return nil }
        let pos = value?.split(separator: "#", maxSplits: 1).dropFirst().first.map { "#" + $0 }
        return Packed(pos: pos, base64: d.base64EncodedString())
    }

    /// Untrusted input: decoded, size-limited, magic bytes checked, stored under a new content name.
    func unpack(_ p: Packed) -> String? {
        guard let d = Data(base64Encoded: p.base64), let name = try? save(d) else { return nil }
        if let pos = p.pos, parse(name + pos) != nil { return name + pos }
        return name
    }
}

/// Finds a photo for a name: Unsplash (with the user's key), else Openverse (openly licensed, no key).
enum CoverFinder {
    /// The full name first, then its meaningful words, longest first: "Mehndi Long Video" → ["Mehndi Long Video", "Mehndi"].
    static func queries(_ name: String) -> [String] {
        let filler: Set<String> = ["video", "long", "short", "template", "project", "edit", "final", "the", "and", "of", "for", "new", "copy", "v1", "v2", "v3"]
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count > 2 && !filler.contains($0.lowercased()) && Int($0) == nil }
        var out = [name.trimmingCharacters(in: .whitespaces)]
        for w in words.sorted(by: { $0.count > $1.count }) where !out.contains(w) { out.append(w) }
        return out.filter { !$0.isEmpty }
    }

    /// The word a person would actually search. Drops brackets and camera/colour jargon, then keeps the
    /// last meaningful word: "ram engagement" → "engagement", "wedding long (slog)" → "wedding".
    static func searchTerm(_ name: String) -> String {
        var s = name
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#] {
            while let r = s.range(of: pattern, options: .regularExpression) { s.removeSubrange(r) }
        }
        let junk: Set<String> = ["video", "long", "short", "template", "project", "edit", "final", "the", "and", "of", "for",
                                 "new", "copy", "part", "full", "main", "test", "draft", "vertical", "horizontal", "landscape",
                                 "portrait", "slog", "slog2", "slog3", "hlg", "log", "raw", "rec709", "rec2020", "4k", "6k", "8k",
                                 "hd", "uhd", "fhd", "v1", "v2", "v3", "v4", "a", "an", "with", "without"]
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { w in
                let l = w.lowercased()
                return w.count > 2 && !junk.contains(l) && Int(w) == nil
                    && l.range(of: #"^[sh]?log\d*$"#, options: .regularExpression) == nil
            }
        return words.last ?? s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One search result: a small preview for the picker grid and the full image to store.
    struct Photo: Identifiable, Hashable { let id: String; let thumb: URL; let full: URL; let credit: String }

    /// Picker grid: Unsplash with the user's key, else Openverse. The query is used as typed.
    static func search(_ query: String, unsplashKey: String?) async -> [Photo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if let key = unsplashKey, !key.isEmpty {
            let u = await unsplashPhotos(q, key: key, count: 24)
            if !u.isEmpty { return u }
        }
        return await openversePhotos(q, count: 20)
    }

    static func openverse(_ name: String) async -> URL? {
        for q in queries(name) {
            if let p = await openversePhotos(q, count: 5).first { return p.full }
        }
        return nil
    }

    static func unsplash(_ query: String, key: String) async -> URL? {
        await unsplashPhotos(query, key: key, count: 1).first?.full
    }

    static func openversePhotos(_ q: String, count: Int) async -> [Photo] {
        var c = URLComponents(string: "https://api.openverse.org/v1/images/")!
        // Openverse refuses anonymous requests above 20 results with 401.
        c.queryItems = [.init(name: "q", value: q), .init(name: "page_size", value: String(min(count, 20))), .init(name: "mature", value: "false")]
        let r = try? await URLSession.shared.data(for: URLRequest(url: c.url!, timeoutInterval: 12))
        guard let (data, resp) = r, (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            Log.info("openverse no result", ["query": q, "status": String((r?.1 as? HTTPURLResponse)?.statusCode ?? -1)]); return []
        }
        return results.compactMap { o in
            guard let id = o["id"] as? String, let s = o["url"] as? String, s.hasPrefix("https://"), let full = URL(string: s) else { return nil }
            let thumb = (o["thumbnail"] as? String).flatMap(URL.init(string:)) ?? full
            return Photo(id: id, thumb: thumb, full: full, credit: (o["creator"] as? String) ?? "Openverse")
        }
    }

    static func unsplashPhotos(_ q: String, key: String, count: Int) async -> [Photo] {
        var c = URLComponents(string: "https://api.unsplash.com/search/photos")!
        c.queryItems = [.init(name: "query", value: q), .init(name: "per_page", value: String(count)), .init(name: "orientation", value: "landscape")]
        var req = URLRequest(url: c.url!, timeoutInterval: 12)
        req.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("v1", forHTTPHeaderField: "Accept-Version")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { o in
            guard let id = o["id"] as? String, let urls = o["urls"] as? [String: Any],
                  let full = (urls["regular"] as? String).flatMap(URL.init(string:)) else { return nil }
            let thumb = (urls["small"] as? String).flatMap(URL.init(string:)) ?? full
            return Photo(id: id, thumb: thumb, full: full, credit: ((o["user"] as? [String: Any])?["name"] as? String) ?? "Unsplash")
        }
    }
}
