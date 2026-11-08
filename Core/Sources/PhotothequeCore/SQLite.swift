import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Erreur SQLite avec le message du moteur.
public struct SQLiteError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Valeur liée à une requête ou lue dans un résultat.
public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func of(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
    public static func of(_ v: Int64?) -> SQLValue { v.map { .int($0) } ?? .null }
    public static func of(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
    public static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    public static func of(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// Ligne de résultat : accès par nom de colonne.
public struct Row: Sendable {
    public let values: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { values[name] ?? .null }

    public func int(_ name: String) -> Int? {
        switch self[name] {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        case .text(let s): return Int(s)
        default: return nil
        }
    }
    public func int64(_ name: String) -> Int64? {
        switch self[name] {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }
    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s)
        default: return nil
        }
    }
    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return nil
        }
    }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Connexion SQLite minimale (requêtes préparées, transactions imbriquées).
/// Une instance n'est utilisée que depuis un seul fil à la fois.
public final class Database {
    private var handle: OpaquePointer?
    public let path: String
    private var savepointDepth = 0

    public init(path: String) throws {
        self.path = path
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &h, flags, nil) != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            sqlite3_close_v2(h)
            throw SQLiteError("Base \(path) : \(msg)")
        }
        handle = h
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
        if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
    }

    deinit { close() }

    public func close() {
        if let h = handle { sqlite3_close_v2(h) }
        handle = nil
    }

    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }

    private var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "base fermée" }

    /// Exécute une ou plusieurs instructions sans paramètre.
    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(msg)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK || stmt == nil {
            throw SQLiteError("\(lastError) — \(sql)")
        }
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        if expected != params.count {
            sqlite3_finalize(stmt)
            throw SQLiteError("\(params.count) paramètre(s) pour \(expected) attendu(s) — \(sql)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let d):
                rc = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buf.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            if rc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw SQLiteError("\(lastError) — paramètre \(idx)")
            }
        }
        return stmt!
    }

    /// Exécute une instruction ; renvoie le nombre de lignes modifiées.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw SQLiteError("\(lastError) — \(sql)") }
        }
        return Int(sqlite3_changes(handle))
    }

    /// Lignes de résultat d'une requête.
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw SQLiteError("\(lastError) — \(sql)") }
            var values: [String: SQLValue] = [:]
            for i in 0..<n {
                let v: SQLValue
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: v = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: v = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: v = .text(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), count > 0 { v = .blob(Data(bytes: p, count: count)) } else { v = .blob(Data()) }
                default: v = .null
                }
                values[names[Int(i)]] = v
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func first(_ sql: String, _ params: [SQLValue] = []) throws -> Row? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        guard let row = try query(sql, params).first, let key = row.values.keys.first else { return 0 }
        return row.int(key) ?? 0
    }

    public var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Transaction (imbriquable grâce aux points de sauvegarde) : annulée si le bloc lève une erreur.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        savepointDepth += 1
        let name = "sp\(savepointDepth)"
        defer { savepointDepth -= 1 }
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    /// Vrai si le moteur SQLite dispose de FTS5.
    public func hasFTS5() -> Bool {
        do {
            try execute("CREATE VIRTUAL TABLE temp.__fts5_probe USING fts5(x)")
            try execute("DROP TABLE temp.__fts5_probe")
            return true
        } catch { return false }
    }
}
