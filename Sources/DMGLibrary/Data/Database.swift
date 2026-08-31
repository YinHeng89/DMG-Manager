import Foundation
import CSQLite

/// SQLite 连接薄封装。
///
/// 使用系统自带 libsqlite3，开启 WAL 模式，保证崩溃时不丢数据。
final class Database {
    private var handle: OpaquePointer?
    let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(fileURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.openFailed(code: Int(rc), message: message)
        }
        self.handle = db
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    var pointer: OpaquePointer {
        guard let handle else { fatalError("Database used after close") }
        return handle
    }

    // MARK: - 执行

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(pointer, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw DatabaseError.executionFailed(sql: sql, message: message)
        }
    }

    /// 执行事务。闭包返回 true 提交，false 回滚。
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 查询

    func query(_ sql: String, bindings: [DatabaseValue] = []) throws -> [[String: DatabaseValue]] {
        var statement: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(pointer, sql, -1, &statement, nil)
        guard prepareRC == SQLITE_OK, let statement else {
            throw DatabaseError.executionFailed(sql: sql, message: String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            try value.bind(to: statement, position: Int32(index + 1))
        }

        var rows: [[String: DatabaseValue]] = []
        while true {
            let stepRC = sqlite3_step(statement)
            if stepRC == SQLITE_DONE { break }
            guard stepRC == SQLITE_ROW else {
                throw DatabaseError.executionFailed(sql: sql, message: String(cString: sqlite3_errmsg(pointer)))
            }
            let columnCount = sqlite3_column_count(statement)
            var row: [String: DatabaseValue] = [:]
            for index in 0..<columnCount {
                guard let name = sqlite3_column_name(statement, index) else { continue }
                row[String(cString: name)] = DatabaseValue(statement: statement, column: index)
            }
            rows.append(row)
        }
        return rows
    }

    /// 执行写入并返回最后插入的 rowid。
    @discardableResult
    func run(_ sql: String, bindings: [DatabaseValue] = []) throws -> Int64 {
        var statement: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(pointer, sql, -1, &statement, nil)
        guard prepareRC == SQLITE_OK, let statement else {
            throw DatabaseError.executionFailed(sql: sql, message: String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            try value.bind(to: statement, position: Int32(index + 1))
        }

        let stepRC = sqlite3_step(statement)
        guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
            throw DatabaseError.executionFailed(sql: sql, message: String(cString: sqlite3_errmsg(pointer)))
        }
        return sqlite3_last_insert_rowid(pointer)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(pointer)) }
}

// MARK: - 绑定值

enum DatabaseValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func value(_ value: (some Any)?) -> DatabaseValue {
        switch value {
        case nil: return .null
        case let value as String: return .text(value)
        case let value as Bool: return .integer(value ? 1 : 0)
        case let value as Int: return .integer(Int64(value))
        case let value as Int64: return .integer(value)
        case let value as Double: return .real(value)
        case let value as Data: return .blob(value)
        default: return .null
        }
    }

    init(statement: OpaquePointer, column: Int32) {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: self = .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: self = .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            if let pointer = sqlite3_column_text(statement, column) {
                self = .text(String(cString: pointer))
            } else {
                self = .null
            }
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, column) {
                let count = Int(sqlite3_column_bytes(statement, column))
                self = .blob(Data(bytes: bytes, count: count))
            } else {
                self = .null
            }
        default: self = .null
        }
    }

    func bind(to statement: OpaquePointer, position: Int32) throws {
        let rc: Int32
        switch self {
        case .null:
            rc = sqlite3_bind_null(statement, position)
        case .integer(let value):
            rc = sqlite3_bind_int64(statement, position, value)
        case .real(let value):
            rc = sqlite3_bind_double(statement, position, value)
        case .text(let value):
            rc = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT_PTR)
        case .blob(let data):
            rc = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement,
                    position,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    SQLITE_TRANSIENT_PTR
                )
            }
        }
        guard rc == SQLITE_OK else {
            throw DatabaseError.bindingFailed(code: Int(rc))
        }
    }

    var stringValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .real(let value) = self { return value }
        if case .integer(let value) = self { return Double(value) }
        return nil
    }

    var boolValue: Bool {
        if case .integer(let value) = self { return value != 0 }
        return false
    }
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: LocalizedError {
    case openFailed(code: Int, message: String)
    case executionFailed(sql: String, message: String)
    case bindingFailed(code: Int)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code, let message):
            return "数据库打开失败 (code \(code)): \(message)"
        case .executionFailed(let sql, let message):
            return "SQL 执行失败: \(message)\nSQL: \(sql)"
        case .bindingFailed(let code):
            return "参数绑定失败 (code \(code))"
        }
    }
}
