import Foundation
import SQLite3

/// Thread-safe metadata cache backed by SQLite with TTL expiration.
public actor MetadataCache {

    private var db: OpaquePointer?
    private let dbPath: String
    private let ttl: TimeInterval
    private var writeCount: Int = 0
    private let pruneInterval: Int = 50

    public init(path: String, ttl: TimeInterval = 300) {
        self.dbPath = path
        self.ttl = ttl
    }

    // MARK: - Lifecycle

    public func open() throws {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw RemoteFileSystemError.operationFailed("Cache open failed: \(msg)")
        }
        // Enable WAL mode for better concurrent read/write performance
        try execute("PRAGMA journal_mode=WAL;")
        // Set busy timeout to avoid SQLITE_BUSY errors under contention
        sqlite3_busy_timeout(db, 5000)
        try execute("""
            CREATE TABLE IF NOT EXISTS items (
                path TEXT PRIMARY KEY,
                parent TEXT NOT NULL,
                data BLOB NOT NULL,
                expires REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_parent ON items(parent);
            CREATE INDEX IF NOT EXISTS idx_expires ON items(expires);
        """)
        pruneExpired()
    }

    public func close() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Get

    public func get(path: RemotePath) -> RemoteItem? {
        guard let db = db else { return nil }
        let sql = "SELECT data FROM items WHERE path = ?1 AND expires > ?2"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path.absoluteString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let len = sqlite3_column_bytes(stmt, 0)
        let data = Data(bytes: blob, count: Int(len))
        return try? JSONDecoder().decode(RemoteItem.self, from: data)
    }

    /// Get all cached children of a directory.
    public func children(of parent: RemotePath) -> [RemoteItem]? {
        guard let db = db else { return nil }
        let sql = "SELECT data FROM items WHERE parent = ?1 AND expires > ?2"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, parent.absoluteString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)

        let decoder = JSONDecoder()
        var items: [RemoteItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = sqlite3_column_bytes(stmt, 0)
            let data = Data(bytes: blob, count: Int(len))
            if let item = try? decoder.decode(RemoteItem.self, from: data) {
                items.append(item)
            }
        }
        return items.isEmpty ? nil : items
    }

    // MARK: - Put

    public func put(item: RemoteItem) {
        try? putInternal(item: item)
    }

    public func putAll(items: [RemoteItem], parent: RemotePath) throws {
        try withTransaction {
            try invalidateChildrenInternal(of: parent)
            for item in items {
                try putInternal(item: item)
            }
        }
    }

    // MARK: - Invalidation

    public func invalidate(path: RemotePath) {
        guard let db = db else { return }
        let sql = "DELETE FROM items WHERE path = ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path.absoluteString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    public func invalidateChildren(of parent: RemotePath) {
        try? invalidateChildrenInternal(of: parent)
    }

    public func invalidateAll() {
        try? execute("DELETE FROM items")
    }

    // MARK: - Maintenance

    public func pruneExpired() {
        guard let db = db else { return }
        let sql = "DELETE FROM items WHERE expires < ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    // MARK: - Helpers

    private func execute(_ sql: String) throws {
        guard let db = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw RemoteFileSystemError.operationFailed("SQL error: \(msg)")
        }
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT TRANSACTION")
        } catch {
            try? execute("ROLLBACK TRANSACTION")
            throw error
        }
    }

    private func putInternal(item: RemoteItem) throws {
        guard let db = db else {
            throw databaseUnavailableError()
        }
        let data = try JSONEncoder().encode(item)
        let sql = "INSERT OR REPLACE INTO items (path, parent, data, expires) VALUES (?1, ?2, ?3, ?4)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db, message: "MetadataCache put prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        let parentPath = item.path.parent?.absoluteString ?? "/"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, item.path.absoluteString, -1, transient)
        sqlite3_bind_text(stmt, 2, parentPath, -1, transient)
        _ = data.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(data.count), transient)
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970 + ttl)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db: db, message: "MetadataCache put failed")
        }

        writeCount += 1
        if writeCount >= pruneInterval {
            writeCount = 0
            pruneExpired()
        }
    }

    private func invalidateChildrenInternal(of parent: RemotePath) throws {
        guard let db = db else {
            throw databaseUnavailableError()
        }
        let sql = "DELETE FROM items WHERE parent = ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db, message: "MetadataCache invalidateChildren prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, parent.absoluteString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db: db, message: "MetadataCache invalidateChildren failed")
        }
    }

    private func databaseUnavailableError() -> Error {
        RemoteFileSystemError.operationFailed("MetadataCache operation failed: database is not open")
    }

    private func sqliteError(db: OpaquePointer, message: String) -> Error {
        let detail = String(cString: sqlite3_errmsg(db))
        return RemoteFileSystemError.operationFailed("\(message): \(detail)")
    }
}
