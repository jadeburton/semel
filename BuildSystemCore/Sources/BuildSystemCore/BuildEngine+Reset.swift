//
//  BuildEngine+Reset.swift
//  BuildSystemCore
//

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
        preservedIDs.insert(inputRoot.id!)
        collectDescendants(of: inputRoot.id!, into: &preservedIDs)

        let outputRoot = try outputFileSystem
        preservedIDs.insert(outputRoot.id!)

        let pfNode = try projectFinder
        preservedIDs.insert(pfNode.id!)

        // 2. Determine which nodes to delete.
        let allNodes  = try database.node.selectAll()
        let deleteIDs = allNodes.compactMap(\.id).filter { !preservedIDs.contains($0) }

        guard !deleteIDs.isEmpty else { return }

        // 3. Bulk delete — wires, output ports, nodes, and the cache — in one transaction.
        try database.withTransaction {
            for nodeID in deleteIDs {
                // Wires entering this node (from preserved or other deleted nodes).
                for wire in (try? database.wire.select(goingToNodeID: nodeID)) ?? [] {
                    _ = try? database.wire.delete(comingFromNodeID: wire.fromNodeID,
                                                  fromSymbolID:    wire.fromSymbolID,
                                                  goingToNodeID:   wire.toNodeID,
                                                  toSymbolID:      wire.toSymbolID)
                }
                // Wires leaving this node (to preserved or other deleted nodes).
                for wire in (try? database.wire.select(comingFromNodeID: nodeID)) ?? [] {
                    _ = try? database.wire.delete(comingFromNodeID: wire.fromNodeID,
                                                  fromSymbolID:    wire.fromSymbolID,
                                                  goingToNodeID:   wire.toNodeID,
                                                  toSymbolID:      wire.toSymbolID)
                }
                _ = try? database.outputPort.deleteAll(nodeID: nodeID)
                _ = try? database.node.delete(nodeID: nodeID)
            }

            // All cached build outputs are now invalid.
            _ = try? database.cacheEntry.deleteAll()

            // Clear any stale pending-deletion marks on the nodes we kept.
            for nodeID in preservedIDs {
                try? database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: false)
            }
        }

        print("Reset: removed \(deleteIDs.count) node(s).")

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
