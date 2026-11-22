import Foundation
import SQLite3

enum DBError: Error, CustomStringConvertible {
    case open(String), sql(String)
    var description: String {
        switch self { case .open(let s): return "Cannot open database: \(s)"; case .sql(let s): return "SQL error: \(s)" }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local store: one document table of Codable JSON records.
/// shortcut: JSON documents instead of normalized tables; switch to columns if querying by field gets slow.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DBError.open(path)
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS docs(
              kind TEXT NOT NULL, id TEXT NOT NULL, parent TEXT, json TEXT NOT NULL, updated REAL NOT NULL,
              PRIMARY KEY(kind, id));
            CREATE INDEX IF NOT EXISTS docs_parent ON docs(kind, parent);
            """)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.sql(msg)
        }
    }

    private func prepare(_ sql: String, _ args: [String?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError.sql(String(cString: sqlite3_errmsg(db))) }
        for (i, a) in args.enumerated() {
            if let a { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
        }
        return stmt
    }

    func save<T: Encodable>(_ kind: String, id: String, parent: String? = nil, _ value: T) throws {
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("INSERT OR REPLACE INTO docs(kind,id,parent,json,updated) VALUES(?,?,?,?,\(Date().timeIntervalSince1970))", [kind, id, parent, json])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    func get<T: Decodable>(_ kind: String, id: String, as: T.Type = T.self) -> T? {
        guard let json = rows("SELECT json FROM docs WHERE kind=? AND id=?", [kind, id]).first else { return nil }
        do { return try decoder.decode(T.self, from: Data(json.utf8)) }
        catch { Log.error("database decode", ["kind": kind, "id": id, "detail": error.localizedDescription]); return nil }
    }

    func all<T: Decodable>(_ kind: String, parent: String? = nil, as: T.Type = T.self) -> [T] {
        let r = parent == nil
            ? rows("SELECT json FROM docs WHERE kind=? ORDER BY updated DESC", [kind])
            : rows("SELECT json FROM docs WHERE kind=? AND parent=? ORDER BY rowid", [kind, parent])
        return r.compactMap { json in
            do { return try decoder.decode(T.self, from: Data(json.utf8)) }
            catch { Log.error("database decode", ["kind": kind, "detail": error.localizedDescription]); return nil }
        }
    }

    func delete(_ kind: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM docs WHERE kind=? AND id=?", [kind, id])
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
    }

    func deleteChildren(_ kind: String, parent: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM docs WHERE kind=? AND parent=?", [kind, parent])
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
    }

    func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    private func rows(_ sql: String, _ args: [String?]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? prepare(sql, args) else {
            Log.error("database query", ["detail": String(cString: sqlite3_errmsg(db))])
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }
}
