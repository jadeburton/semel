//
//  BuildEngine+Reset.swift
//  SemelCore
//

import SemelNodeKit

extension BuildEngine {

    /// Resets the build graph to a clean state.
    ///
    /// Preserves:
    ///   • Every node in the input file system (root Folder + all descendants)
    ///   • The output file system root Folder
    ///   • ProjectFinder
    ///
    /// Deletes everything else — all compiler/linker/builder nodes, all output file
    /// system contents, all cached build results — then reschedules ProjectFinder so
    /// it rebuilds the entire graph from the current input file system contents.
    public func reset() throws {
        // 1. Collect node IDs to preserve.
        var preservedIDs = Set<ObjectID>()

        let inputRoot = try inputFileSystem
        preservedIDs.insert(try inputRoot.requireID())
        collectDescendants(of: (try inputRoot.requireID()), into: &preservedIDs)

        let outputRoot = try outputFileSystem
        preservedIDs.insert(try outputRoot.requireID())

        let pfNode = try projectFinder
        preservedIDs.insert(try pfNode.requireID())

        // 2. Determine which nodes to delete.
        let allNodes  = try database.node.selectAll()
        let deleteIDs = allNodes.compactMap(\.id).filter { !preservedIDs.contains($0) }

        // 3. Bulk delete — wires, output ports, nodes, and the cache — in one transaction.
        //    An empty delete set is not an early exit: the rebuild in step 4 still has to
        //    run, otherwise `reset` on an already-clean graph silently does nothing.
        if !deleteIDs.isEmpty {
            try database.withTransaction {
                for nodeID in deleteIDs {
                    // Wires entering this node (from preserved or other deleted nodes).
                    for wire in (try? database.wire.select(goingToNodeID: nodeID)) ?? [] {
                        _ = try? database.wire.delete(wire: wire)
                    }
                    // Wires leaving this node (to preserved or other deleted nodes).
                    for wire in (try? database.wire.select(comingFromNodeID: nodeID)) ?? [] {
                        _ = try? database.wire.delete(wire: wire)
                    }
                    _ = try? database.outputPort.deleteAll(nodeID: nodeID)
                    _ = try? database.node.delete(nodeID: nodeID)
                }

                // All cached build outputs are now invalid.
                _ = try? database.cacheEntry.deleteAll()

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

        // 4. Reschedule ProjectFinder so it re-reads the input manifests and
        //    recreates all ProjectBuilder nodes and the downstream build graph.
        try pfNode.setScheduled(true)
    }

    private func collectDescendants(of nodeID: ObjectID, into set: inout Set<ObjectID>) {
        for child in (try? database.node.select(parentNodeID: nodeID)) ?? [] {
            guard let childID = child.id else { continue }
            set.insert(childID)
            collectDescendants(of: childID, into: &set)
        }
    }
}
