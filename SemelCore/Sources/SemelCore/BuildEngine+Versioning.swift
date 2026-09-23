//
//  BuildEngine+Versioning.swift
//  SemelCore
//
//  A cache key can prevent a wrong reuse; it cannot cause a recomputation. Nodes are
//  scheduled only on creation, on a wire change, on `nudge()` or after `reset`, so a new
//  Semel that computes different outputs from the same inputs would leave the old
//  artifacts published indefinitely, whatever the key says. The marker below has to
//  trigger, not merely compare.

import SemelDatabaseModels

/// The database was created by a Semel whose tables looked different. `reset` cannot help:
/// it preserves the input file system, and those rows live in the old tables. The only
/// safe move is a new database, which means pushing the sources again.
public struct DatabaseSchemaChangedError: UnrecoverableError {
    public let filePath: String

    public var unrecoverableDescription: String {
        """
        The database schema changed since \(filePath) was created.
        Delete that file and push your sources again.
        """
    }
}

extension BuildEngine {

    static let semelVersionKey = "semelVersion"

    /// Compares the database against the running Semel and reacts to a mismatch. Called
    /// once by `start()`, before the processing loop — not by the initialiser, which tests
    /// run over databases they prepared first and must not see wiped.
    ///
    /// - A schema mismatch throws `DatabaseSchemaChangedError`.
    /// - A version mismatch — a different recorded version, or none on a database that
    ///   already holds nodes — runs `reset()` and records the current version.
    /// - A fresh database is just stamped.
    func reconcileVersionMarkers() throws {
        guard try database.schemaFingerprint() == DatabaseLayer.expectedSchemaFingerprint() else {
            throw DatabaseSchemaChangedError(filePath: database.filePath ?? "(in-memory database)")
        }

        let recorded = try database.metadata.select(key: Self.semelVersionKey)
        guard recorded != Semel.version else {
            return
        }

        let isFresh = try recorded == nil && database.node.selectAll().isEmpty
        if !isFresh {
            Debug.log("Semel \(recorded ?? "of unknown version") built this graph; now \(Semel.version). Rebuilding.")
            try reset()
            try restateThePortsOfPreservedNodes()
        }
        try database.metadata.upsert(key: Self.semelVersionKey, value: Semel.version)
    }

    /// The rebuild deletes what it can, but `reset()` preserves the input file system with
    /// its ports, and those ports were written by another Semel — which may have spelled a
    /// reason differently from this one. A preserved node is a file: it either holds its
    /// content or has never had any, so a port holding an error is restated as the one thing
    /// such a port can truthfully be. A file that was pushed keeps its content and is not
    /// touched; one that was not is waiting to be, which is what the state says.
    private func restateThePortsOfPreservedNodes() throws {
        for node in try database.node.selectAll() {
            guard let nodeID = node.id else {
                continue
            }
            for port in try database.outputPort.selectAll(nodeID: nodeID) where port.valueKind == .error {
                var restated = port
                restated.valueKind = .initializing
                restated.dataObjectHash = nil
                try database.outputPort.insertOrUpdate(restated)
            }
        }
    }
}
