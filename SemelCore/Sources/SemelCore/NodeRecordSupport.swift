//
//  NodeSupport.swift
//  semel
//
//  Created by Jade Burton on 14.06.26.
//

// MARK: - String helpers

import SemelNodeKit

extension String {
    /// Returns the string with the given suffix removed, or the original string
    /// unchanged if it does not end with that suffix.
    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

extension NodeRecord {
    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    /// Returns the full logical path of this node from the root, e.g. `input:/src/hello.c`.
    /// Returns `.empty` when the node is the specified `baseNodeID` (so callers can do relative paths).
    func buildFullPathName(baseNodeID: ObjectID?) throws -> Path {

        if let baseNodeID, id == baseNodeID {
            return .empty
        }

        func parentPath() throws -> Path {

            guard let parentNodeID else {
                return .empty
            }

            return try database.node.select(nodeID: parentNodeID).buildFullPathName(baseNodeID: baseNodeID)
        }

        guard let name, !name.isEmpty else {
            throw NodeError.other(message: "Node \(try requireID()) in \(try parentPath()) has no name or it is empty; cannot build full path")
        }

        let parent = try parentPath()

        return parent.isEmpty ? Path(name) : parent / name
    }

    func makeNode() throws -> any Node {
        try (TypeRegistry.type(kind: kind) as! Node.Type).init(thisNode: self)
    }

    /// Returns the node as `Any` so app-layer callers can pattern-match
    /// against concrete public types (e.g. `as? UserDeletable`, `as? FileType`).
    public func nodeAsAny() throws -> Any {
        try makeNode()
    }

    var allChildren: [NodeRecord] {
        get throws {
            try DatabaseLayer.shared.node.select(parentNodeID: (try requireID()))
        }
    }

    /// `identity` is the node's, computed by the applier from the tree it is creating;
    /// a caller creating a node outside any tree — a file-system root, a test — passes
    /// nil and gets the identity of the node as it stands, which has no wires yet.
    static func createNode(database: DatabaseLayer, kind: UInt, properties: [String: String], identity: String?) throws -> NodeRecord {

        var nodeRecord = NodeRecord(parentNodeID: nil,
                                    kind: kind,
                                    name: nil,
                                    properties: properties,
                                    scheduled: false,
                                    identity: identity)

        nodeRecord.id = try database.node.insert(nodeRecord)
        if let nodeID = nodeRecord.id {
            BuildEngine.shared?.settleRecorder.noteCreated(nodeID: nodeID)
        }

        let node = try nodeRecord.makeNode()

        nodeRecord.name = node.thisNode.name
        nodeRecord.parentNodeID = node.thisNode.parentNodeID

        let nodeID = try nodeRecord.requireID()
        assert(nodeRecord.parentNodeID != nodeID, "a node cannot be its own parent")

        // Saved now, not with the rest below: collecting a stale sibling deletes it from
        // its folder, and a folder that finds itself childless deletes itself. This node
        // is the folder's child from here on, so the folder stays.
        try database.node.update(nodeRecord)

        // The row was inserted above before the node could report its name, so the
        // uniqueness check can only happen here — and a rejection has to back that
        // row out, or a failed creation leaves an unreachable orphan behind.
        if let name = nodeRecord.name, let parentNodeID = nodeRecord.parentNodeID {
            let siblings = try database.node.select(named: name, parentNodeID: parentNodeID)
            if let existing = siblings.first(where: { $0.id != nodeID }) {
                // A sibling nothing references any more is not a collision, it is the
                // node this one replaces: a product whose definition changed keeps its
                // path, and the builder that changed it has just unwired the old node in
                // the same pass, leaving it marked for the idle-time collection. Collect
                // it now, or the new one can never be created and the builder stays in
                // error until something else reschedules it.
                if existing.pendingDeletion, try Self.collectIfUnreferenced(existing, database: database) {
                    // fall through: the name is free
                } else {
                    // The collision is the error worth throwing; backing the row out is
                    // best effort on the way there, short of the machine itself failing.
                    FatalErrors.attempt { try database.node.delete(nodeID: nodeID) }
                    throw NodeError.nameCollision(path: try Self.describePath(database: database,
                                                                              parentNodeID: parentNodeID,
                                                                              name: name),
                                                  existingKind: existing.kind)
                }
            }
        }

        try nodeRecord.writePendingToAllOutputsOfNode()

        // A node that says nothing at creation publishes the state it is in: created, not
        // yet processed. Not an error, so a report passes over it and a graph of fresh nodes
        // does not read as a graph of failures.
        let output = try node.didCreate() ?? node.buildOutput(reason: .initializing)

        try node.writeToOutputs(output: output)

        if type(of: node).descriptor.hasInputs {
            try nodeRecord.setScheduled(true)
        }

        if identity == nil {
            nodeRecord.identity = try nodeRecord.recomputedIdentity(database: database)
        }

        try database.node.update(nodeRecord)

        assert(nodeRecord.identity != nil)

        try node.notifyParentThisChildAdded()

        return nodeRecord
    }

    /// Deletes `record` now if nothing references it and it may go — the same test and the
    /// same steps as the idle-time pass, for a node that is in the way of its replacement.
    /// False if it is still held, in which case it stays and the caller has a collision.
    private static func collectIfUnreferenced(_ record: NodeRecord, database: DatabaseLayer) throws -> Bool {
        guard let existingID = record.id, let node = try? record.makeNode(),
              try node.hasNoOutputWires(), try node.canBeDeleted() else {
            return false
        }
        for inputWire in try database.wire.select(goingToNodeID: existingID) {
            try inputWire.deleteWire(database: database)
        }
        try node.delete()
        return true
    }

    /// Best-effort full path of a would-be child, for error messages only. Falls back to
    /// the bare name if the parent cannot be resolved — an error report must never fail.
    private static func describePath(database: DatabaseLayer, parentNodeID: ObjectID, name: String) throws -> String {
        guard let parent = FatalErrors.attempt({ try database.node.find(nodeID: parentNodeID) }) ?? nil,
              let parentPath = try? parent.buildFullPathName(baseNodeID: nil) else {
            return name
        }
        return (parentPath / name).string
    }

    /// Walk (creating as needed) the given path of folder nodes beneath `self`.
    /// Returns the deepest folder node.
    @discardableResult
    public func ensureEntirePathExistsAsFolders(_ path: Path, pinned: Bool) throws -> NodeRecord {
        guard kind == Folder.kind else {
            throw NodeError.other(message: "Cannot ensure path exists on a non-folder node")
        }

        var currentFolder = self
        var pathSoFar = try buildFullPathName(baseNodeID: nil)

        for name in path.segments {
            pathSoFar = pathSoFar.isEmpty ? Path(name) : pathSoFar / name

            let existingChildren = try database.node.select(named: name, parentNodeID: (try currentFolder.requireID()))

            if existingChildren.count > 1 {
                // Can happen when folder and file have same name
                throw NodeError.other(message: "Multiple children with the same name '\(name)' under folder '\(currentFolder.name ?? "<no name>")'")
            }

            if let existingChild = existingChildren.first {
                if existingChild.kind != Folder.kind {
                    // Previously a `break`, which silently returned the last good folder
                    // and left the caller believing a path had been created that had not.
                    throw NodeError.nameCollision(path: pathSoFar.string, existingKind: existingChild.kind)
                }
                currentFolder = existingChild
            } else {
                assert(!pathSoFar.string.hasSuffix("/"))
                assert(!pathSoFar.string.hasPrefix("/"))

                let specNode = GraphSpecNode(Folder.self, properties: [Folder.pathProperty: pathSoFar.string])
                let (fromNode, _) = try specNode.findOrCreateMatchingNode()
                var newFolder = fromNode
                newFolder.parentNodeID = (try currentFolder.requireID())
                try database.node.update(newFolder)

                try newFolder.makeNode().notifyParentThisChildAdded()
                currentFolder = newFolder
            }

            if pinned {
                if let folder = try currentFolder.makeNode() as? Folder, try !folder.isPinned {
                    // setPinned notifies the parent itself, through onChildContentChanged,
                    // and that is the whole notification this needs. Folder answers both that
                    // and onChildAdded with refreshOutputs, so announcing the pin a second
                    // time rebuilds the parent's manifest for nothing — buildManifest runs in
                    // full even when the resulting JSON is identical and the write is skipped.
                    //
                    // Content is also the accurate event: the child exists and has been
                    // announced by the time we reach here, so its presence is not what
                    // changed.
                    try folder.setPinned(true)
                }
            }
        }

        return currentFolder
    }

    /// Convenience overload accepting a String path.
    @discardableResult
    public func ensureEntirePathExistsAsFolders(_ path: String, pinned: Bool) throws -> NodeRecord {
        try ensureEntirePathExistsAsFolders(Path(path), pinned: pinned)
    }

    /// Walk the node tree by path segments, returning the node at the given path or `nil` if not found.
    public func childNode(path: Path) throws -> NodeRecord? {
        guard !path.isEmpty else {
            return self
        }
        var currentNode = self
        for name in path.segments {
            guard let child = try database.node.select(named: name, parentNodeID: (try currentNode.requireID())).first else {
                return nil
            }
            currentNode = child
        }
        return currentNode
    }

    /// Convenience overload accepting a String path.
    public func childNode(path: String) throws -> NodeRecord? {
        try childNode(path: Path(path))
    }

    func setScheduled(_ scheduled: Bool) throws {
        let node = try self.makeNode()

        guard type(of: node).descriptor.hasInputs else {
            Debug.warn("ignoring a request to schedule \(self) / \(type(of: node)), which declares no inputs")
            return
        }

        try database.node.updateScheduled(nodeID: (try requireID()), scheduled: scheduled)

        if scheduled {
            BuildEngine.shared?.signalWorkAvailable()
        }
    }
}

// MARK: - Port management

extension NodeRecord {
    func hasOneOrMoreErrorOrPendingOutputs() throws -> Bool {
        try database.outputPort.selectAll(nodeID: (try requireID())).contains { $0.valueKind != .value }
    }

    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
        // A folder's two derived values are rebuilt on demand (B-25, B-26): reading one is
        // what makes it current.
        if kind == Folder.kind {
            switch outputPort {
            case Folder.folderManifestOutputPort: try Folder.flushManifestIfDirty(nodeID: try requireID())
            case Folder.contentRootOutputPort:    try Folder.flushContentRootIfDirty(nodeID: try requireID())
            default: break
            }
        }

        let outputSymbolID = outputPort.asSymbolID()

        let nodeID = try requireID()
        guard let port = try database.outputPort.select(nodeID: nodeID, nameSymbolID: outputSymbolID) else {
            throw NodeError.outputPortMissing(nodeID: nodeID, port: outputPort)
        }
        return try port.asNodeValue()
    }

    func readFromInputPort(_ inputPort: String) throws -> [String: NodeValue] {
        // One query for the port, whatever arrives at it: the wires joined with the ports
        // they come from. A select per wire cost a wide consumer the width of its fan on
        // every evaluation (B-124).
        let arrivals = try database.outputPort.selectArriving(atNodeID: try requireID(),
                                                              toSymbolID: inputPort.asSymbolID())

        var result = [String: NodeValue]()

        for arrival in arrivals {
            guard let port = arrival.port else {
                continue
            }
            let wireName = arrival.wireName.resolveSymbol()
            assert(result[wireName] == nil)
            try result[wireName] = port.asNodeValue()
        }

        return result
    }

    func writePendingToAllOutputsOfNode() throws {
        // Every way a node's inputs come to mean something else passes through here — a
        // port write cascading to its consumers, a wire connected, a wire disconnected —
        // which makes it the one place an artifact can be noticed as a candidate for the
        // settle diff (B-50). Touched, not changed: the comparison against the reported
        // hash is what tells those apart.
        if kind == OutputFile.kind, let path = properties["path"], let nodeID = id {
            BuildEngine.shared?.noteArtifactTouched(path: path, nodeID: nodeID)
        }

        for outputPort in try makeNode().descriptor.outputPorts {
            try writeToOutputPort(outputPort, value: .noValue(reason: .pending))
        }
    }

    @discardableResult func writeToOutputPort(_ outputPort: String, value: NodeValue) throws -> Bool {
        try writeToOutputPort(port: try value.asOutputPort(nodeID: (try requireID()), outputSymbolID: outputPort.asSymbolID()))
    }

    @discardableResult func writeToOutputPort(port: OutputPort) throws -> Bool {

        let nodeID   = try requireID()
        let existing = try database.outputPort.select(nodeID: nodeID, nameSymbolID: port.nameSymbolID)
        if existing == port {
            return false
        }

        // What the port held when the settle began, asked before the row is replaced: the
        // first write in a settle is usually the cascade's `pending`, so comparing with
        // `existing` would call every value that followed it a change (B-91).
        let recorder    = BuildEngine.shared?.settleRecorder
        let settleStart = recorder?.valueAtSettleStart(nodeID: nodeID, portSymbolID: port.nameSymbolID,
                                                       replacing: existing)

        try database.outputPort.insertOrUpdate(port)

        for wire in try database.wire.select(comingFromNodeID: nodeID, fromSymbolID: port.nameSymbolID) {
            let toNode = try database.node.select(nodeID: wire.toNodeID)

            try toNode.writePendingToAllOutputsOfNode()

            if port.valueKind != .pending {
                recorder?.noteWake(consumerNodeID: wire.toNodeID, wire: wire,
                                   change: SettleRecorder.change(from: settleStart, to: port))
                try toNode.setScheduled(true)
            }
        }
        return true
    }
}
