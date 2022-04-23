//
//  Database.swift
//  SQLiteWapper
//
//  Created by keiji0 on 2020/12/26.
//

import Foundation
import SQLite3
import os

public final class Database {
    
    public init(fileURL: URL, options: OpenOptions = .default) {
        self.fileURL = fileURL
        self.options = options
    }
    
    deinit {
        try? close()
    }
    
    public func open() throws {
        do {
            Logger.main.info("Opening: version=\(Self.version ?? "<nil>"), path=\(self.fileURL.path)")
            try call { sqlite3_open_v2(fileURL.path, &handle, options.rawValue, nil) }
            Logger.main.info("Open success: path=\(self.fileURL.path)")
        } catch {
            try? close()
            throw error
        }
    }
    
    public func isOpen() -> Bool {
        return handle != nil
    }
    
    public func close() throws {
        defer { handle = nil }
        Logger.main.info("close \(self.fileURL.path)")
        statements.removeAll()
        try call { return sqlite3_close(handle) }
    }
    
    public func setBusyTimeout(_ ms: Int32) {
        assert(isOpen())
        try! call { sqlite3_busy_timeout(handle, ms) }
    }
    
    public func changes() -> Int32 {
        assert(isOpen())
        return sqlite3_changes(handle)
    }
    
    public func totalChanges() -> Int32 {
        assert(isOpen())
        return sqlite3_total_changes(handle)
    }
    
    public func exec(_ sql: String, _ params: [StatementParameter] = []) throws {
        assert(isOpen())
        if params.isEmpty {
            try call {
                sqlite3_exec(handle, sql, nil, nil, nil)
            }
        } else {
            try prepare(sql).bind(params).step()
        }
    }
    
    public func prepare(_ sql: String) throws -> Statement {
        assert(isOpen())
        return try Statement(self, sql: sql)
    }
    
    /// DBにクエリを投げる。クエリのステートメントはキャッシュされる
    @discardableResult
    public func query<T>(_ sql: String, _ params: [StatementParameter], _ block: (Statement) throws -> T) throws -> T {
        let statement = prepareSql(sql)
        defer { try! statement.reset() }
        try statement.bind(params)
        return try block(statement)
    }
    
    public func query(_ sql: String, _ params: [StatementParameter]) throws {
        try query(sql, params, { statement in
            try statement.step()
        })
    }
    
    public func count(_ sql: String, _ params: [StatementParameter] = []) throws -> Int {
        try query(sql, params) { statment in
            try statment.fetchRow { row in
                row.column(0)
            } ?? 0
        }
    }
    
    public func begin() {
        defer { transactionNestLevel += 1 }
        guard transactionNestLevel == 0 else { return }
        try! exec("BEGIN;")
    }
    
    public func end() {
        defer { transactionNestLevel -= 1 }
        guard transactionNestLevel == 1 else { return }
        try! exec("COMMIT;")
    }
    
    /// 定義されている全てのテーブル名を取得
    public var tableNames: [String] {
        let sql = "SELECT tbl_name FROM sqlite_master WHERE type='table'"
        return try! prepare(sql).fetchRows {
            $0.column(String.self, 0)
        }
    }
    
    // MARK: - Static
    
    public static var version: String? {
        guard let cString = sqlite3_libversion() else { return nil }
        return String(cString: cString)
    }
    
    // MARK: - Internal
    
    var handle: OpaquePointer?
    
    /// sqliteのAPIをコールする
    /// 適切なエラーコードに変換してくれる
    @discardableResult
    func call(block: () -> (Int32)) throws -> DatabaseResponse {
        let result = DatabaseResponse.code(for: block())
        switch result {
        case .ok, .done, .row:
            return result
        case .error(let code):
            throw DatabaseError.api( code, String(cString: sqlite3_errmsg(handle)))
        }
    }
    
    // MARK: - Private
    
    private let fileURL: URL
    private let options: OpenOptions
    private var transactionNestLevel: Int = 0
    private var statements = [String: Statement]()
    
    /// 同一SQL文のステートメントはキャッシュする。これによって10-20%ほど早くなった
    private func prepareSql(_ sql: String) -> Statement {
        if let statement = statements[sql] {
            return statement
        } else {
            let statement = try! prepare(sql)
            statements[sql] = statement
            return statement
        }
    }
}
