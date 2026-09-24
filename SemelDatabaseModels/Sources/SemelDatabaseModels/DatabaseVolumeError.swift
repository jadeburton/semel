//
//  DatabaseVolumeError.swift
//  SemelDatabaseModels
//
//  GRDB reports every failure as one `DatabaseError` type. Some of those describe the
//  machine — the disk is full, the file cannot be opened, the volume is read-only, the
//  file is no longer a database — and nothing the engine does next can succeed. Others
//  describe the moment (the file is locked) or the statement (a constraint violation) and
//  belong to the caller. Conformance to `UnrecoverableError` is per type, so the
//  distinction is drawn here, once, and applied at the database layer's boundary.

import Foundation
import GRDB

/// A `SQLITE_READONLY` raised inside a `withReadSnapshot`, which has two causes and cannot
/// tell them apart from the code alone.
///
/// The first is the caller's: something inside the snapshot tried to write, and the read
/// connection refused it. The second is the machine's, and is easy to miss — in WAL mode a
/// *reader* writes too, to the `-shm` and `-wal` siblings, when it is the first to open
/// them after they grow or when it has to recover them after a crash. A volume that cannot
/// take that bookkeeping refuses a plain read with the same code.
///
/// Deliberately not an `UnrecoverableError`. The first cause is a bug in this process and
/// the second is a fact about the disk, and blaming the disk by stopping would be wrong
/// half the time — so this fails the operation and leaves the process running to say both.
public struct WriteInsideReadSnapshotError: Error, CustomStringConvertible {
    public let underlying: GRDB.DatabaseError

    public init(underlying: GRDB.DatabaseError) {
        self.underlying = underlying
    }

    public var description: String {
        "a read snapshot was refused as read-only (\(underlying.extendedResultCode)): "
            + "\(underlying.message ?? "no message"). "
            + "Look first for a write inside the snapshot — that is the cause this process "
            + "can fix, and `withTransaction` is where work that writes belongs. If nothing "
            + "in it writes, the volume holding the database cannot take the write-ahead "
            + "log's own bookkeeping, which a reader does too."
    }
}

/// The database's volume is out of room or out of reach, or the file is damaged. Raised by
/// `DatabaseLayer` in place of the GRDB error it translates; the original is kept.
public struct DatabaseVolumeError: UnrecoverableError {
    /// Where the database lives; nil for an in-memory one.
    public let filePath: String?
    public let underlying: GRDB.DatabaseError

    public init(filePath: String?, underlying: GRDB.DatabaseError) {
        self.filePath   = filePath
        self.underlying = underlying
    }

    /// Whether `error` is the machine's failure rather than the caller's. Judged on the
    /// primary result code, so every `SQLITE_IOERR_*` variant counts as `SQLITE_IOERR`.
    public static func isVolumeFailure(_ error: GRDB.DatabaseError) -> Bool {
        switch error.resultCode {
        case .SQLITE_FULL, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_READONLY, .SQLITE_PERM,
             .SQLITE_NOMEM, .SQLITE_CORRUPT, .SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }

    /// Translates `error` if it is a volume failure; otherwise hands it back untouched.
    public static func translating(_ error: Error, filePath: String?) -> Error {
        guard let databaseError = error as? GRDB.DatabaseError, isVolumeFailure(databaseError) else {
            return error
        }
        return DatabaseVolumeError(filePath: filePath, underlying: databaseError)
    }

    private var isDamaged: Bool {
        underlying.resultCode == .SQLITE_CORRUPT || underlying.resultCode == .SQLITE_NOTADB
    }

    public var unrecoverableDescription: String {
        let location = filePath ?? "(in-memory database)"
        let code     = underlying.extendedResultCode

        if isDamaged {
            return """
                The database at \(location) is damaged (\(code)).

                \(underlying.message ?? "")

                Nothing can repair this from inside the build. Move the file aside, with its
                `-wal` and `-shm` siblings, and push your sources again:

                    mv "\(location)"* <another directory>/

                Those files are the only record of how the graph came to be damaged.
                """
        }
        return """
            The database at \(location) cannot be used (\(code)).

            \(underlying.message ?? "")

            Every node's state lives in this file, so the build cannot proceed.
            Check free space and permissions on the volume holding it.
            """
    }
}
