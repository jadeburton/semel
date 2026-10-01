// CachedStatements.swift
// SemelDatabaseModels
//
// The statements the accessors run again and again, prepared once per connection.

import GRDB
import SQLite3

/// GRDB prepares a statement afresh for every query-interface request and every
/// `fetchAll(_:sql:)`, and a cold push runs the same few texts tens of thousands of times:
/// measured on one, a fifth of the database queue's time was SQLite compiling SQL it had
/// compiled a moment before. These run through `Database.cachedStatement(sql:)` instead,
/// which keeps one prepared statement per text in the connection itself. A statement
/// therefore lives exactly as long as the connection that prepared it — the one connection
/// of a `DatabaseLayer`'s `DatabaseQueue`, closed with it — and cannot be run on another:
/// there is no registry here to outlive either.
///
/// Only for statements stepped to their end before the call returns — `fetchAll`,
/// `fetchOne`, `execute`. A cursor left open over a cached statement would be reset under
/// its reader by the next call of the same text, which is why nothing here hands one out.
///
/// What a prepared statement does not survive is GRDB's `PRAGMA query_only`, set and
/// cleared around every `DatabaseQueue.read`: a flag pragma expires every statement on the
/// connection, and each is prepared again on its next step. That costs what an uncached
/// statement costs every time, so it is never worse; and inside a transaction — a push's
/// batch, recorded in one (`withTransactionPerStep`) — no read sets it, and the statements
/// stay prepared from the first file to the last.
///
/// GRDB drops a statement from its cache when a step fails, since SQLite cannot reset one
/// that failed, so a failure here costs a prepare on the next call and nothing else.
extension Database {

    /// Every row of `sql`.
    func cachedRows(_ sql: String, arguments: StatementArguments = StatementArguments()) throws -> [Row] {
        try Row.fetchAll(cachedStatement(sql: sql), arguments: arguments)
    }

    /// Every row of `sql`, as records.
    func cachedRecords<Record: FetchableRecord>(_ sql: String,
                                                arguments: StatementArguments = StatementArguments()) throws -> [Record] {
        try Record.fetchAll(cachedStatement(sql: sql), arguments: arguments)
    }

    /// The first row of `sql`, as a record, or nil.
    func cachedRecord<Record: FetchableRecord>(_ sql: String,
                                               arguments: StatementArguments = StatementArguments()) throws -> Record? {
        try Record.fetchOne(cachedStatement(sql: sql), arguments: arguments)
    }

    /// The first column of the first row of `sql`, or nil.
    func cachedValue<Value: DatabaseValueConvertible & StatementColumnConvertible>(
        _ sql: String, arguments: StatementArguments = StatementArguments()) throws -> Value? {
        try Value.fetchOne(cachedStatement(sql: sql), arguments: arguments)
    }

    /// The first column of every row of `sql`.
    func cachedValues<Value: DatabaseValueConvertible & StatementColumnConvertible>(
        _ sql: String, arguments: StatementArguments = StatementArguments()) throws -> [Value] {
        try Value.fetchAll(cachedStatement(sql: sql), arguments: arguments)
    }

    /// Runs `sql`, which changes rows and returns none.
    func cachedExecute(_ sql: String, arguments: StatementArguments = StatementArguments()) throws {
        try cachedStatement(sql: sql).execute(arguments: arguments)
    }
}

extension DatabaseLayer {

    /// The text of every statement this layer's connection holds prepared, in no order. A
    /// test observable, of a piece with `NodeDataAccess.selectCount`: that an accessor
    /// prepares its statement once rather than once per call is a count of statements
    /// alive on the connection, which a stopwatch cannot tell. Not read by the engine.
    public func preparedStatementTexts() -> [String] {
        func texts(of db: Database) -> [String] {
            var texts: [String] = []
            var statement = sqlite3_next_stmt(db.sqliteConnection, nil)
            while let current = statement {
                if let text = sqlite3_sql(current) {
                    texts.append(String(cString: text))
                }
                statement = sqlite3_next_stmt(db.sqliteConnection, current)
            }
            return texts
        }
        if let wrapper = DatabaseLayer.currentDB {
            return texts(of: wrapper.db)
        }
        return dbQueue.inDatabase(texts)
    }
}
