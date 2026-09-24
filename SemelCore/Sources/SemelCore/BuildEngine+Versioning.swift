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
/// safe move is a new database, which means pushing the sources again — with the old file
/// moved aside rather than deleted, which is what `reset` does with a graph it discards
/// and for the same reason: it is the evidence for whatever went wrong in it.
public struct DatabaseSchemaChangedError: UnrecoverableError {
    public let filePath: String

    public var unrecoverableDescription: String {
        """
        The database schema changed since \(filePath) was created.
        Move that file aside, with its `-wal` and `-shm` siblings, and push your sources again:

            mv "\(filePath)"* <another directory>/

        Those files are the only record of what that graph held, which is worth keeping if
        the schema is not the whole story.
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
            // Without the cache, on one premise: a key carries the node type's
            // `implementationVersion`, so a type that changed what it emits for equal
            // inputs and *declared* a new version misses on its own key, while the types a
            // release left alone answer the rebuild from their entries rather than
            // building every project in the home cold. The premise is the author's, not
            // the mechanism's — AGENTS.md is where it is asked for — and a release where
            // nobody bumped republishes what the older code computed.
            let archivedGraphPath = try reset()
            try restateThePortsOfPreservedNodes()
            // The one reset nobody asked for, so the one whose copy would otherwise appear
            // in the home unexplained. This runs from `BuildEngine.start()`, before a
            // server installs its reporter and before any client can be listening, so the
            // line goes to `noticeReporter`'s default and lands on the process's own
            // stdout — `semelserv`'s terminal. That default is the channel here, chosen
            // over `Debug.log`, which a release build compiles out.
            if let archivedGraphPath {
                Self.notice("Semel \(recorded ?? "of unknown version") built this graph; "
                          + "it was copied to \(archivedGraphPath), which is yours to delete.")
            }
        }
        try database.metadata.upsert(key: Self.semelVersionKey, value: Semel.version)
    }

    /// The rebuild deletes what it can, but `reset()` preserves the input file system, the
    /// output root and `ProjectFinder` with their ports — and those ports were written by
    /// another Semel, which spelled some of this version's states as an error carrying a
    /// word. A port still holding one of those words is restated as the state that says the
    /// same thing. Every other error is left alone: what a node said about itself is still
    /// what it said.
    ///
    /// Reading the message is what a migration is for, and this is the only place allowed
    /// to: the words below are older encodings, data rather than vocabulary, and nothing
    /// outside this function may compare against them.
    ///
    /// One of them was written for two states at once, which is the defect the states
    /// replace: 0.1.3 wrote "Deleted" both for a source the user removed and for a folder
    /// nobody had ever pushed into, and only the port it sits on tells those apart.
    private func restateThePortsOfPreservedNodes() throws {
        let placeholderOfVersion0_1_2 = "initializing"
        let removedInVersion0_1_3     = "Deleted"
        let unpinnedInVersion0_1_3    = "Deleted/Nonexistent"

        for node in try database.node.selectAll() {
            guard let nodeID = node.id else {
                continue
            }
            for port in try database.outputPort.selectAll(nodeID: nodeID) where port.valueKind == .error {
                let restatedKind: OutputPort.ValueKind

                switch try? port.dataObjectHash?.resolveAsString() {
                case placeholderOfVersion0_1_2:
                    restatedKind = .initializing

                case unpinnedInVersion0_1_3:
                    restatedKind = .deleted

                case removedInVersion0_1_3:
                    // A folder wrote this from its creation, before anyone had pushed into
                    // it; anything else wrote it when what it held was taken away.
                    restatedKind = node.kind == Folder.kind
                                && port.nameSymbolID.resolveSymbol() == Folder.pinnedOutputPort
                                 ? .initializing
                                 : .deleted

                default:
                    continue
                }

                var restated = port
                restated.valueKind = restatedKind
                restated.dataObjectHash = nil
                try database.outputPort.insertOrUpdate(restated)
            }
        }
    }
}
