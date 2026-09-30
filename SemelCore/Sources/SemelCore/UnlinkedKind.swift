// UnlinkedKind.swift
// SemelCore
//
// A row whose kind this server does not link (B-130).
//
// A graph outlives the server that built it. A type removed from `semelserv` — the
// tutorial's `MyLineCounter` once the reader takes it out, a plugin left out of a build, a
// branch that never had it — leaves its rows behind, and they cannot become nodes: nothing
// knows their ports or can run them. The engine carries such a node as an error rather
// than refusing the graph at launch. It is the dataflow rule: a failure is a value on the
// failing node's ports, the report names it where it is, and the rest of the graph goes on
// — a push stores its file and wakes every other reader, a build of anything the node does
// not reach is unaffected, and linking the type again brings the node back as it was. A
// refusal at launch would have made every such graph wait for a `reset`, including one
// whose stale node nothing reads any more, and a reset discards the whole derived graph for
// the sake of one row. It is the same choice as a tool version no longer installed
// (AGENTS.md, "Deliberate choices"): expected to fail when processed, and said then.

import SemelDatabaseModels
import SemelNodeKit

/// What a node of a kind this server does not link says for itself.
enum UnlinkedKind {

    /// The error a node of `kind` publishes when woken: its kind in the words `check` uses
    /// for the same row, and the ways out. `SemelNodeKit`, whose registry throws for the
    /// kind, cannot name `reset`; the engine renders this, so the remedy is written here.
    static func message(kind: UInt) -> String {
        "its kind \(kind) is a type this server does not link. Link the type again, or take it "
            + "out of the formula and build, which lets the node go; reset discards the derived "
            + "state that is stuck."
    }
}

extension NodeRecord {

    /// The node type this row is, or nil when this server links none by its kind.
    var linkedNodeType: (any Node.Type)? {
        (try? TypeRegistry.type(kind: kind)) as? any Node.Type
    }

    /// The output ports to write when the node's value changes: those its type declares, or
    /// for a kind this server does not link, those it holds rows for — which the type made
    /// when it made the node, one per declared port.
    func outputPortNames() throws -> [String] {
        if let nodeType = linkedNodeType {
            return nodeType.descriptor.outputPorts
        }
        return try database.outputPort.selectAll(nodeID: try requireID()).map { $0.nameSymbolID.resolveSymbol() }
    }

    /// What a node of a kind this server does not link publishes in place of a run: the
    /// error, on every port it holds. Written through `writeToOutputPort`, so its readers
    /// are woken and carry it as any failure is carried, and a second wake that finds the
    /// same error there writes nothing.
    func publishUnlinkedKindError() throws {
        let messageHash = try UnlinkedKind.message(kind: kind).intern()
        for outputPort in try outputPortNames() {
            try writeToOutputPort(outputPort, value: .noValue(reason: .error(messageDataObjectHash: messageHash)))
        }
    }

    /// Deletes a row of a kind this server does not link once nothing reads it, with its
    /// input wires — what `processPendingDeletions` does for a node it can make — and says
    /// whether it went. One read again since it was marked has its mark cleared instead.
    ///
    /// Deletable without asking its type, which is gone: what `canBeDeleted` keeps is a
    /// pushed file or folder, held for the user's sake, and those are the engine's own
    /// types, always linked. Anything else is derived, and is collected once nothing reads
    /// it. The parent is told, as `Node.delete` tells it.
    func deleteUnlinked() throws -> Bool {
        let nodeID = try requireID()
        guard try database.wire.select(comingFromNodeID: nodeID).isEmpty else {
            try database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: false)
            return false
        }
        // Each deletion marks an upstream node that loses its last reader, for the next pass.
        for inputWire in try database.wire.select(goingToNodeID: nodeID) {
            try inputWire.deleteWire(database: database)
        }
        _ = try database.node.delete(nodeID: nodeID)
        if let parentNodeID, let parent = try database.node.find(nodeID: parentNodeID) {
            try parent.makeNode().onChildDeleted(nodeID: nodeID)
        }
        return true
    }
}
