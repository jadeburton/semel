// UnrecoverableError.swift
// SemelDatabaseModels
//
// Most build failures belong to one node: a compile fails, a formula is malformed, an
// input is missing.  Those are reported against the node and the build carries on.
//
// A few failures are not like that.  If the object store cannot be written, nothing the
// engine does next means anything — every subsequent node would fail for the same reason,
// and reporting "node 47 failed" hides the fact that the disk is full.  Those are
// unrecoverable, and the process should say so plainly and stop.
//
// What is classified: `ObjectStoreError` (a build output that cannot be stored, an input
// that cannot be placed in a sandbox), `SandboxCreationError` (nowhere to run a tool at
// all), `DatabaseVolumeError` (the graph's own file cannot be written, opened or read, or
// is damaged) and `DatabaseSchemaChangedError` (the file predates this Semel's tables).
// The first three are one thing said three ways — the volume is out of room or out of
// reach.
//
// Database failures need a word on how they get here.  GRDB reports every one as
// `DatabaseError`, mixing SQLITE_FULL and SQLITE_IOERR with SQLITE_BUSY, which is
// transient, and SQLITE_CONSTRAINT, which is a bug in the caller.  Telling them apart is a
// per-*instance* decision and conformance here is per *type*, so the GRDB type does not
// conform; instead `DatabaseLayer`'s read, write and transaction boundary translates the
// machine's result codes into `DatabaseVolumeError` and lets the rest through untouched.

import Foundation

/// Marks an error as one the build cannot continue past.
///
/// Conformance is per type, not per case: `check` asks `error as? any UnrecoverableError`,
/// so every case of a conforming enum becomes fatal.  An error type that mixes the two —
/// `LocalFileSystemToolError` holds both "the machine has nowhere to run tools" and "that
/// tool is not installed" — has to be split rather than conformed, which is why
/// `SandboxCreationError` stands alone.  Take that as the signal it is: a type whose cases
/// disagree about whether the build can continue is describing two different failures.
public protocol UnrecoverableError: Error {
    /// What went wrong, in terms the person running the build can act on.
    var unrecoverableDescription: String { get }
}

public enum FatalErrors {

    /// What to do when an unrecoverable error reaches a boundary.
    ///
    /// Swappable — a test installs a recording handler so it can assert that something
    /// was classified as unrecoverable without terminating the test process.  The
    /// default writes to stderr and exits.
    public static var handler: (any UnrecoverableError) -> Void = defaultHandler

    /// Terminates the process after reporting `error`.
    public static func defaultHandler(_ error: any UnrecoverableError) {
        let message = """

            The build cannot continue.

            \(error.unrecoverableDescription)

            """
        FileHandle.standardError.write(Data(message.utf8))
        exit(70) // EX_SOFTWARE
    }

    /// Reports `error` and does not return.
    ///
    /// For the call sites that cannot throw and cannot produce a value either — infrastructure
    /// so low that everything above assumes it works. Going through here rather than calling
    /// `fatalError` directly is what keeps the message the same one every other unrecoverable
    /// failure prints.
    ///
    /// The `fatalError` is a backstop, not the normal path: the default handler exits first.
    /// It exists because `handler` is swappable, and a handler that records and returns still
    /// leaves the caller with nothing to give back. That does make these call sites
    /// untestable in process — asserting the classification would kill the test.
    public static func fail(_ error: any UnrecoverableError) -> Never {
        handler(error)
        fatalError(error.unrecoverableDescription)
    }

    /// If `error` is unrecoverable, hand it to the handler. Otherwise do nothing, so the
    /// caller can carry on reporting it against whichever node produced it.
    ///
    /// Call this at every boundary that turns a thrown error into a recorded one —
    /// otherwise an unrecoverable failure gets filed as a per-node build error.
    public static func check(_ error: Error) {
        guard let unrecoverable = error as? any UnrecoverableError else {
            return
        }
        handler(unrecoverable)
    }

    /// Runs best-effort work: a debug listing, a cache touch, a label for an error report —
    /// things whose failure must not fail the build. An ordinary failure yields nil and
    /// nothing else happens; a machine failure still reaches the handler. This is what
    /// `try?` on a database call meant to say, minus the part where it also dropped the
    /// one error that matters.
    @discardableResult
    public static func attempt<T>(_ work: () throws -> T) -> T? {
        do {
            return try work()
        } catch {
            check(error)
            return nil
        }
    }
}
