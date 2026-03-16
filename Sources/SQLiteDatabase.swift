import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .execFailed(let msg): return "SQLite exec failed: \(msg)"
        case .bindFailed(let msg): return "SQLite bind failed: \(msg)"
        }
    }
}

final class SQLiteDatabase {
    private var db: OpaquePointer?

    /// Expose raw pointer for direct sqlite3 C API calls (e.g., custom functions)
    var rawPointer: OpaquePointer? { db }

    /// Open an in-memory database
    init(inMemory: Bool = true) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            inMemory ? ":memory:" : "",
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
            nil
        )
        guard rc == SQLITE_OK, let db = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(msg)
        }
        self.db = db
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    /// Execute a SQL statement with no results
    func execute(_ sql: String, params: [Any?] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params: params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.execFailed(String(cString: sqlite3_errmsg(db!)))
        }
    }

    /// Query returning rows as [[String: Any?]] dictionaries
    func query(_ sql: String, params: [Any?] = []) throws -> [[String: Any?]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params: params)

        var rows: [[String: Any?]] = []
        let colCount = sqlite3_column_count(stmt)
        let colNames = (0..<colCount).map { String(cString: sqlite3_column_name(stmt, $0)) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            for i in 0..<colCount {
                let name = colNames[Int(i)]
                row[name] = columnValue(stmt: stmt, index: i)
            }
            rows.append(row)
        }
        return rows
    }

    /// Query returning a single integer (e.g., COUNT(*))
    func queryScalar(_ sql: String, params: [Any?] = []) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params: params)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Iterate rows without accumulating them (for large result sets)
    func forEach(_ sql: String, params: [Any?] = [], body: ([String: Any?]) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params: params)

        let colCount = sqlite3_column_count(stmt)
        let colNames = (0..<colCount).map { String(cString: sqlite3_column_name(stmt, $0)) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            for i in 0..<colCount {
                let name = colNames[Int(i)]
                row[name] = columnValue(stmt: stmt, index: i)
            }
            try body(row)
        }
    }

    /// Attach an external database read-only
    func attachReadOnly(path: String, as name: String) throws {
        let uri = "file:\(path)?mode=ro"
        try execute("ATTACH DATABASE '\(uri)' AS \(name)")
    }

    // MARK: - Private

    private func columnValue(stmt: OpaquePointer, index: Int32) -> Any? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            return sqlite3_column_int64(stmt, index)
        case SQLITE_TEXT:
            return String(cString: sqlite3_column_text(stmt, index))
        case SQLITE_FLOAT:
            return sqlite3_column_double(stmt, index)
        case SQLITE_BLOB:
            let bytes = sqlite3_column_bytes(stmt, index)
            if let blob = sqlite3_column_blob(stmt, index) {
                return Data(bytes: blob, count: Int(bytes))
            }
            return nil
        default: // SQLITE_NULL
            return nil
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepareFailed(
                "\(String(cString: sqlite3_errmsg(db!)))\nSQL: \(sql)"
            )
        }
        return s
    }

    private func bind(_ stmt: OpaquePointer, params: [Any?]) throws {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch param {
            case nil:
                rc = sqlite3_bind_null(stmt, idx)
            case let v as Int:
                rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as String:
                rc = sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let v as Double:
                rc = sqlite3_bind_double(stmt, idx, v)
            case let v as Data:
                rc = v.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(v.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            default:
                rc = sqlite3_bind_text(stmt, idx, "\(param!)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError.bindFailed("param \(i): \(String(cString: sqlite3_errmsg(db!)))")
            }
        }
    }
}
