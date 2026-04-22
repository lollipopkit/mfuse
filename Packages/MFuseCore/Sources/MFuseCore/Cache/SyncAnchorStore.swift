import Foundation
import SQLite3
import os.log

/// Stores sync anchors for File Provider incremental enumeration.
/// Each domain gets its own monotonically increasing anchor.
public actor SyncAnchorStore {

    private static let logger = Logger(
        subsystem: "com.mfuse.core",
        category: "SyncAnchorStore"
    )

    private var db: OpaquePointer?
    private let dbPath: String

    public init(path: String) {
        self.dbPath = path
    }

    public func open() throws {
        if let db {
            let closeResult = sqlite3_close(db)
            guard closeResult == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw RemoteFileSystemError.operationFailed("SyncAnchorStore close before reopen failed: \(msg)")
            }
            self.db = nil
        }

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore open failed: \(msg)")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let sql = "CREATE TABLE IF NOT EXISTS anchors (domain TEXT PRIMARY KEY, anchor INTEGER NOT NULL DEFAULT 0)"
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) }
                ?? db.flatMap { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            if let errMsg {
                sqlite3_free(errMsg)
            }
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore schema setup failed: \(msg)")
        }
        if let errMsg {
            sqlite3_free(errMsg)
        }
    }

    public func close() {
        if let db = db { sqlite3_close(db) }
        db = nil
    }

    public func currentAnchor(for domain: String) -> UInt64 {
        guard let db = db else { return 0 }
        let sql = "SELECT anchor FROM anchors WHERE domain = ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, domain, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        let value = sqlite3_column_int64(stmt, 0)
        guard value >= 0 else {
            Self.logger.error(
                "Ignoring negative sync anchor for domain \(domain, privacy: .public): \(value)"
            )
            return 0
        }
        return UInt64(value)
    }

    @discardableResult
    public func incrementAnchor(for domain: String) throws -> UInt64 {
        let current = currentAnchor(for: domain)
        guard current < UInt64(Int64.max) else {
            Self.logger.error(
                "Sync anchor overflow while incrementing domain \(domain, privacy: .public): \(current)"
            )
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore increment failed: anchor overflow")
        }
        let next = current + 1
        try setAnchor(next, for: domain)
        return next
    }

    public func setAnchor(_ anchor: UInt64, for domain: String) throws {
        guard let db = db else {
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore setAnchor failed: database is not open")
        }
        let sql = "INSERT OR REPLACE INTO anchors (domain, anchor) VALUES (?1, ?2)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        guard anchor <= UInt64(Int64.max) else {
            Self.logger.error(
                "Refusing out-of-range sync anchor write for domain \(domain, privacy: .public): \(anchor)"
            )
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore write failed: anchor overflow")
        }
        sqlite3_bind_text(stmt, 1, domain, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(anchor))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw RemoteFileSystemError.operationFailed("SyncAnchorStore write failed: \(msg)")
        }
    }
}
