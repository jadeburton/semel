//
//  BuildEngine+Artifacts.swift
//  SemelCore
//
//  The artifact half of the settle report. `reportIdleTimeErrors` says what is wrong with
//  the graph; this says what the graph produced — and both are answered once the engine
//  has gone quiet, because a functional system's intermediate states are not news.
//

import SemelDatabaseModels
import SemelNodeKit

extension BuildEngine {

    /// Hands one settle's artifact diff to whoever is reading, and records what it said.
    ///
    /// The whole diff, once per settle, over every artifact in the graph. Narrowing it to
    /// a subtree is a *delivery* decision and belongs to whoever is subscribed: the diff
    /// is computed from candidates that are consumed as they are read, so a second,
    /// narrower report of the same settle would find nothing left and every path outside
    /// the first one's subtree would be swallowed. A daemon serving several worktrees
    /// therefore filters this one diff per subscriber (B-30 role 3); the snapshot table
    /// stays the record of what has been told, unfiltered, whoever is listening.
    ///
    /// A settle in which nothing moved says nothing, the way a settle that scheduled
    /// nothing prints no summary.
    ///
    /// Best effort, like the reports beside it: a failure delays the diff to the next
    /// settle rather than losing it. The table is written in the same transaction as the
    /// comparison, so a failed report has recorded nothing, and its candidates go back
    /// into the sets to be compared again.
    func reportArtifactChanges() {
        guard let changes = FatalErrors.attempt({ try recordArtifactChanges() }),
              !changes.isEmpty else {
            return
        }
        artifactReporter(changes)
    }

    /// The diff, and the table updated to match it, in one transaction: a client told an
    /// artifact appeared must find the artifact, so what is said and the state that says
    /// it was said commit together.
    private func recordArtifactChanges() throws -> ArtifactChanges {
        let (touched, collected) = takeArtifactCandidates()
        let firstReportOfThisLaunch = !artifactsHaveBeenReconciled

        // Nothing was woken and nothing was collected, so there is nothing to compare —
        // and the loop passes through idle on every signal that turns out to have no work
        // behind it. Before the transaction, which would otherwise take the serialised
        // writer queue once per pass to do nothing with it.
        guard firstReportOfThisLaunch || !touched.isEmpty || !collected.isEmpty else {
            return ArtifactChanges()
        }

        do {
            let changes = try database.withTransaction {
                firstReportOfThisLaunch ? try reconcileEveryArtifact()
                                        : try compareCandidates(touched: touched, collected: collected)
            }
            // After the commit: a reconciliation that did not finish has not happened, and
            // the launch still owes one.
            artifactsHaveBeenReconciled = true
            return changes.sorted()
        } catch {
            returnArtifactCandidates(touched: touched, collected: collected)
            throw error
        }
    }

    /// Empties both candidate sets and answers what was in them.
    private func takeArtifactCandidates() -> (touched: [String: ObjectID], collected: [String: ObjectID]) {
        artifactCandidateLock.withLock {
            defer {
                touchedArtifacts = [:]
                collectedArtifacts = [:]
            }
            return (touchedArtifacts, collectedArtifacts)
        }
    }

    /// Puts candidates a failed report consumed back, without displacing anything the
    /// write path recorded while that report was running: a later entry for the same path
    /// names the node as it is.
    private func returnArtifactCandidates(touched: [String: ObjectID], collected: [String: ObjectID]) {
        artifactCandidateLock.withLock {
            touchedArtifacts.merge(touched) { current, _ in current }
            collectedArtifacts.merge(collected) { current, _ in current }
        }
    }

    /// The steady path: one lookup by primary key per artifact the write path woke.
    private func compareCandidates(touched: [String: ObjectID],
                                   collected: [String: ObjectID]) throws -> ArtifactChanges {
        var changes = ArtifactChanges()

        // Paths a node still stands at. A path collected and rebuilt inside one settle is
        // here, and its collection is not news: the reader has an artifact at that path,
        // and what it is worth saying about it is how it differs from the one they were
        // told about — including nothing at all, while the rebuilt node has no value yet.
        var stillInTheGraph: Set<String> = []

        for (path, nodeID) in touched.sorted(by: { $0.key < $1.key }) {
            guard let nodeRecord = try database.node.find(nodeID: nodeID),
                  nodeRecord.kind == OutputFile.kind else {
                continue
            }
            stillInTheGraph.insert(path)

            guard let hash = try publishedHash(ofArtifact: nodeRecord) else {
                continue
            }
            try note(path: path, publishing: hash, into: &changes)
        }

        for (path, nodeID) in collected.sorted(by: { $0.key < $1.key })
        where !stillInTheGraph.contains(path) {
            // The collection is recorded before the delete, and a delete can fail: the row
            // goes only once the node is really gone, or a live product would be announced
            // as disappeared and nothing would ever correct it.
            guard try database.node.find(nodeID: nodeID) == nil,
                  try database.artifactSnapshot.select(path: path) != nil else {
                continue
            }
            try database.artifactSnapshot.delete(path: path)
            changes.disappeared.append(path)
        }

        return changes
    }

    /// The first report of a launch, which has no candidates to work from: a restart
    /// keeps the table and loses the set of what was touched, so the whole graph is
    /// compared against the whole table once.
    private func reconcileEveryArtifact() throws -> ArtifactChanges {
        var changes = ArtifactChanges()
        var artifactsInTheGraph: Set<String> = []

        for nodeRecord in try database.node.select(kind: OutputFile.kind) {
            guard let path = nodeRecord.properties["path"] else {
                continue
            }
            // Before the value is asked for: a product that exists and is failing keeps
            // its row, because a failure is not a disappearance.
            artifactsInTheGraph.insert(path)

            guard let hash = try publishedHash(ofArtifact: nodeRecord) else {
                continue
            }
            try note(path: path, publishing: hash, into: &changes)
        }

        for snapshot in try database.artifactSnapshot.selectAll()
        where !artifactsInTheGraph.contains(snapshot.path) {
            try database.artifactSnapshot.delete(path: snapshot.path)
            changes.disappeared.append(snapshot.path)
        }

        return changes
    }

    /// Compares one artifact against the hash last reported for it, and records the new
    /// one when they differ. The comparison is the whole mechanism: every woken artifact
    /// is a candidate, and only this tells the ones that moved from the ones that were
    /// merely rebuilt.
    private func note(path: String, publishing hash: DataObjectHash,
                      into changes: inout ArtifactChanges) throws {
        let reported = try database.artifactSnapshot.select(path: path)?.contentHash

        guard reported != hash else {
            return
        }
        if reported == nil {
            changes.appeared.append(path)
        } else {
            changes.changed.append(path)
        }
        try database.artifactSnapshot.upsert(path: path, contentHash: hash)
    }

    /// The bytes an artifact publishes, or nil when it publishes none — a product waiting
    /// on its builder, one whose builder failed, one nothing has produced yet. An
    /// artifact is pinned by its input port, so that port is where its content is.
    private func publishedHash(ofArtifact nodeRecord: NodeRecord) throws -> DataObjectHash? {
        guard case .value(let hash)? = try nodeRecord.readFromInputPort(OutputFile.inputPort).first?.value else {
            return nil
        }
        return hash
    }
}

private extension ArtifactChanges {

    /// In path order, for the reason the unclaimed-key report sorts by path: a node's id
    /// records the order its graph was written and a set's iteration order is seeded per
    /// process, so the path is the only one of the three that reads the same in two
    /// builds of the same tree (B-04).
    func sorted() -> ArtifactChanges {
        ArtifactChanges(appeared: appeared.sorted(), changed: changed.sorted(),
                        disappeared: disappeared.sorted())
    }
}
