import CSQLite
import Foundation

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct DatabaseError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        if let sql { return "SQLite error \(code): \(message) (in: \(sql))" }
        return "SQLite error \(code): \(message)"
    }
}

public struct Row {
    public let columns: [String: SQLValue]

    public func int(_ name: String) -> Int64? {
        switch columns[name] {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch columns[name] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    public func string(_ name: String) -> String? {
        if case .text(let v) = columns[name] { return v }
        return nil
    }

    public func date(_ name: String) -> Date? {
        double(name).map(Date.init(timeIntervalSince1970:))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the SQLite C API. The connection is opened in serialized
/// mode so a single instance can be shared, and in WAL mode so the daemon and
/// MCP server processes can read and write concurrently.
public final class Database {
    private let handle: OpaquePointer

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(db)
            throw DatabaseError(code: rc, message: "\(message) at \(path)", sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw DatabaseError(code: rc, message: message, sql: sql)
        }
    }

    /// Runs a statement that returns no rows; returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLBindable] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLBindable] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            var columns: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: columns[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: columns[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: columns[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: columns[name] = .null
                }
            }
            rows.append(Row(columns: columns))
        }
        return rows
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            let bindRC: Int32
            switch param.sqlValue {
            case .null: bindRC = sqlite3_bind_null(stmt, index)
            case .int(let v): bindRC = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): bindRC = sqlite3_bind_double(stmt, index, v)
            case .text(let v): bindRC = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            }
            if bindRC != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw error(bindRC, sql)
            }
        }
        return stmt
    }

    private func error(_ rc: Int32, _ sql: String) -> DatabaseError {
        DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}
