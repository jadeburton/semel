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

    /// The rebuild deletes what it can, but `reset()` preserves the input file system, the
    /// output root and `ProjectFinder` with their ports — and those ports were written by
    /// another Semel, which spelled one of this version's states as an error carrying a word.
    /// A port still holding that word means "nothing has been produced here", so it is
    /// restated as the state that says so. Every other error is left alone: what a node said
    /// about itself is still what it said.
    ///
    /// Reading the message is what a migration is for, and this is the only place allowed to:
    /// the text below is 0.1.2's encoding, data rather than vocabulary, and nothing outside
    /// this function may compare against it.
    private func restateThePortsOfPreservedNodes() throws {
        let placeholderOfVersion0_1_2 = "initializing"

        for node in try database.node.selectAll() {
            guard let nodeID = node.id else {
                continue
            }
            for port in try database.outputPort.selectAll(nodeID: nodeID) where port.valueKind == .error {
                guard (try? port.dataObjectHash?.resolveAsString()) == placeholderOfVersion0_1_2 else {
                    continue
                }
                var restated = port
                restated.valueKind = .initializing
                restated.dataObjectHash = nil
                try database.outputPort.insertOrUpdate(restated)
            }
        }
    }
}
