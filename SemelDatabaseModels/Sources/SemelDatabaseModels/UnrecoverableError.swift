// UnrecoverableError.swift
// SemelDatabaseModels
//
// Most build failures belong to one node: a compile fails, a formula is malformed, an
// input is missing.  Those are reported against the node and the build carries on.
//
// A few failures are not like that.  If the object store cannot be written or the
// database rejects a write, nothing the engine does next means anything — every
// subsequent node would fail for the same reason, and reporting "node 47 failed" hides
// the fact that the disk is full.  Those are unrecoverable, and the process should say
// so plainly and stop.

import Foundation

/// Marks an error as one the build cannot continue past.
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

    /// If `error` is unrecoverable, hand it to the handler. Otherwise do nothing, so the
    /// caller can carry on reporting it against whichever node produced it.
    ///
    /// Call this at every boundary that turns a thrown error into a recorded one —
    /// otherwise an unrecoverable failure gets filed as a per-node build error.
    public static func check(_ error: Error) {
        guard let unrecoverable = error as? any UnrecoverableError else { return }
        handler(unrecoverable)
    }
}
