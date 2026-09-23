//
//  BuildEngine+Reset.swift
//  SemelCore
//

import Foundation
import SemelNodeKit

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
    /// cover — an entry believed wrong, or a Semel that computes different outputs from
    /// the same inputs.
    ///
    /// A reset is also a graph's last moment, and the state it discards is the evidence
    /// for whatever made the reset necessary, so the database file is copied aside first.
    @discardableResult
    public func reset(clearCache: Bool = false) throws -> String? {
        let archivedGraphPath = try copyGraphAside()

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

        // 3. Bulk delete — wires, output ports and nodes — in one transaction.
        //    An empty delete set is not an early exit: the rebuild in step 4 still has to
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

        // 4. Discard the cached builds, when asked. Outside the delete above, which an
        //    already-clean graph skips: a cache wipe the user asked for has to happen
        //    whether or not there was a node left to remove.
        if clearCache {
            _ = try database.cacheEntry.deleteAll()
        }

        // 5. Reschedule ProjectFinder so it re-reads the input manifests and
        //    recreates all ProjectBuilder nodes and the downstream build graph.
        try pfNode.setScheduled(true)

        return archivedGraphPath
    }

    /// The copy of the graph database a reset leaves behind, named for the moment it was
    /// taken so that repeated resets each keep their own. Best effort in one respect only:
    /// an in-memory database has no file, and answers nil.
    private func copyGraphAside() throws -> String? {
        let path = try database.copyAside(suffix: ".broken-\(Self.archiveTimestamp(Date()))")
        if let path {
            Debug.log("Reset: the graph was copied to \(path).")
        }
        return path
    }

    /// ISO 8601, to the second and in UTC, with the colons left out: a file name that
    /// sorts by age and survives being copied to any file system.
    private static func archiveTimestamp(_ date: Date) -> String {
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
