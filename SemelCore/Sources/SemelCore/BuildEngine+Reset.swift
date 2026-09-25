//
//  BuildEngine+Reset.swift
//  SemelCore
//

import Foundation
import SemelDatabaseModels
import SemelNodeKit

/// The graph could not be copied aside, so the reset stopped before it deleted anything.
///
/// Unrecoverable, for the reason the copy is taken first: it is the reset's first write,
/// and what stops it — a volume with no room, a home that cannot be written to, a file
/// SQLite cannot read — stops everything the reset would do next. The path it tried to
/// write is in the message, because that is what the reader has to make room for.
public struct GraphCopyFailedError: UnrecoverableError {
    public let destinationPath: String
    public let underlying: Error

    public init(destinationPath: String, underlying: Error) {
        self.destinationPath = destinationPath
        self.underlying      = underlying
    }

    public var unrecoverableDescription: String {
        let reason = (underlying as? any UnrecoverableError)?.unrecoverableDescription ?? "\(underlying)"
        return """
            The graph could not be copied to \(destinationPath), so nothing was reset.
            The graph is as it was.

            \(reason)
            """
    }
}

extension BuildEngine {

    /// Resets the build graph to a clean state, and answers where the graph it discarded
    /// was copied to — nil for an in-memory database, which has no file.
    ///
    /// Preserves:
    ///   • Every node in the input file system (root Folder + all descendants)
    ///   • The output file system root Folder
    ///   • ProjectFinder
    ///   • Every cached build result, unless `clearCache` asks for those too
    ///
    /// Deletes everything else — all compiler/linker/builder nodes, all output file
    /// system contents — then reschedules ProjectFinder so it rebuilds the entire graph
    /// from the current input file system contents. The cache is content-addressed and
    /// keyed on nothing a node ID knows, so the rebuilt graph hits the entries the
    /// deleted one left: a reset costs one pass of cache lookups rather than a cold build
    /// of every project in the home. `clearCache` is for the one case the key cannot
    /// cover — an entry believed wrong. A Semel that computes different outputs from the
    /// same inputs is covered: the node type that changed carries a new
    /// `implementationVersion` and misses on its own key.
    ///
    /// A reset is also a graph's last moment, and the state it discards is the evidence
    /// for whatever made the reset necessary, so the database file is copied aside before
    /// anything is deleted — and only then, since a reset that finds nothing to discard
    /// destroys nothing and leaves the live file standing as its own record.
    @discardableResult
    public func reset(clearCache: Bool = false) throws -> String? {
        // 1. Collect node IDs to preserve.
        var preservedIDs = Set<ObjectID>()

        let inputRoot = try inputFileSystem
        preservedIDs.insert(try inputRoot.requireID())
        try collectDescendants(of: try inputRoot.requireID(), into: &preservedIDs)

        let outputRoot = try outputFileSystem
        preservedIDs.insert(try outputRoot.requireID())

        let pfNode = try projectFinder
        preservedIDs.insert(try pfNode.requireID())

        // 2. Determine which nodes to delete.
        let allNodes  = try database.node.selectAll()
        let deleteIDs = allNodes.compactMap(\.id).filter { !preservedIDs.contains($0) }

        // 3. Copy the graph aside, while it still holds what is about to go. A fresh home
        //    holds nothing beyond the roots and a reset there discards nothing, so it is
        //    not worth a copy; a cache the user asked to discard is state in this same
        //    file, and is.
        let discardsSomething = try !deleteIDs.isEmpty || (clearCache && database.cacheEntry.count() > 0)
        let archivedGraphPath = try discardsSomething ? copyGraphAside() : nil

        // 4. Bulk delete — wires, output ports and nodes — in one transaction.
        //    An empty delete set is not an early exit: the rebuild in step 6 still has to
        //    run, otherwise `reset` on an already-clean graph silently does nothing.
        //    Every step throws: a delete that fails rolls the whole transaction back and
        //    `reset` reports it, rather than skipping the row and committing a graph with
        //    dangling wires in it.
        if !deleteIDs.isEmpty {
            try database.withTransaction {
                for nodeID in deleteIDs {
                    // Wires entering this node (from preserved or other deleted nodes).
                    for wire in try database.wire.select(goingToNodeID: nodeID) {
                        _ = try database.wire.delete(wire: wire)
                    }
                    // Wires leaving this node (to preserved or other deleted nodes).
                    for wire in try database.wire.select(comingFromNodeID: nodeID) {
                        _ = try database.wire.delete(wire: wire)
                    }
                    _ = try database.outputPort.deleteAll(nodeID: nodeID)
                    _ = try database.node.delete(nodeID: nodeID)
                }

                // Artifact snapshots are left alone too, and this is the one place that
                // removes `OutputFile` nodes without the collector noticing. The rebuild
                // republishes the same products from the same sources, so the rows still
                // describe what the reader was told and they are told nothing — which is
                // the truth. A product the rebuild does not recreate leaves a row behind
                // saying it is there; the reconciliation at the next launch is what takes
                // it away. Clearing the table here would be worse: the rebuild takes as
                // many settles as it takes, and the first would report every product gone
                // and the next report it back.
                //
                // Pending-deletion marks on preserved nodes are deliberately left alone.
                // A mark means the user ran `rm` and the idle-time GC has not collected
                // the node yet; clearing it here would silently undo the delete, and
                // nothing would ever re-mark it.  `connectWire` clears the flag on its
                // own if the rebuild wires the node back up.
            }

            Debug.log("Reset: removed \(deleteIDs.count) node(s).")

            // The output root is preserved but every child under it was just deleted.
            // Its manifest is built from the child list, and the bulk delete above
            // bypasses node.delete() — the only path that notifies a parent —
            // so refresh it here or it keeps advertising products that are gone.
            if let outputFolder = try? outputRoot.makeNode() as? Folder {
                try outputFolder.refreshOutputs()
            }
        }

        // 5. Discard the cached builds, when asked. Outside the delete above, which an
        //    already-clean graph skips: a cache wipe the user asked for has to happen
        //    whether or not there was a node left to remove.
        if clearCache {
            _ = try database.cacheEntry.deleteAll()
        }

        // 6. Reschedule ProjectFinder so it re-reads the input manifests and
        //    recreates all ProjectBuilder nodes and the downstream build graph.
        try pfNode.setScheduled(true)

        return archivedGraphPath
    }

    /// The copy of the graph database a reset leaves behind, named for the moment it was
    /// taken so that repeated resets each keep their own. Answers nil for an in-memory
    /// database, which has no file.
    ///
    /// A failure here stops the reset with the graph untouched, and says so: the copy is
    /// the first thing a reset writes, so what breaks it — a full disk, a read-only home,
    /// a damaged file — is what would break every write the reset makes next.
    private func copyGraphAside() throws -> String? {
        guard let destinationPath = database.pathForCopyAside(suffix: ".broken-\(Self.archiveTimestamp(Date()))") else {
            return nil
        }
        do {
            try database.copyAside(to: destinationPath)
        } catch {
            throw GraphCopyFailedError(destinationPath: destinationPath, underlying: error)
        }
        Debug.log("Reset: the graph was copied to \(destinationPath).")
        return destinationPath
    }

    /// ISO 8601, to the second and in UTC, with the colons left out: a file name that
    /// sorts by age and survives being copied to any file system. A copy taken inside the
    /// same second as an earlier one is told apart by `pathForCopyAside`.
    static func archiveTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        return formatter.string(from: date)
    }

    private func collectDescendants(of nodeID: ObjectID, into set: inout Set<ObjectID>) throws {
        for child in try database.node.select(parentNodeID: nodeID) {
            guard let childID = child.id else { continue }
            set.insert(childID)
            try collectDescendants(of: childID, into: &set)
        }
    }
}
