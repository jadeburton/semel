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
            throw NodeError.nodeHasNoName(nodeID: id)
        }

        let parent = try parentPath()

        return parent.isEmpty ? Path(name) : parent / name
    }

    func makeNode() throws -> any Node {
        try TypeRegistry.nodeType(kind: kind).init(thisNode: self)
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

    /// Walk (creating as needed) the given path of folder nodes beneath `self`.
    /// Returns the deepest folder node.
    ///
    /// The part of the path that exists is read in one query, with each folder's pin
    /// (`selectPath`), so a path whose folders are all there and pinned costs one read
    /// however deep it is (B-131). Below a folder this creates, the rest is read again from
    /// that folder: a folder found by its identity rather than made may already hold some.
    ///
    /// A folder made here with a folder of the path below it, or — `forAChild` — the last
    /// one, when the caller is about to place a node in it, is made without its folds
    /// (`Folder.didCreateOnTheWayToAChild`): the child marks it as it is placed, and the
    /// next pass folds it once, over everything placed in it by then. The last folder of a
    /// walk nobody places anything in is made with the folds of an empty folder, which is
    /// what it is: a link pushed as a folder, a folder a formula names and nobody pushed.
    @discardableResult
    public func ensureEntirePathExistsAsFolders(_ path: Path, pinned: Bool, forAChild: Bool = false) throws -> NodeRecord {
        guard kind == Folder.kind else {
            throw NodeError.notAFolder(kind: kind)
        }

        let names          = path.segments
        let pinnedSymbolID = Folder.pinnedOutputPort.asSymbolID()

        var currentFolder = self
        var pathSoFar     = try buildFullPathName(baseNodeID: nil)
        var existingSteps = try database.node.selectPath(below: try requireID(), names: names,
                                                         portSymbolIDs: [pinnedSymbolID])
        var depthOffset   = 0

        for (index, name) in names.enumerated() {
            pathSoFar = pathSoFar.isEmpty ? Path(name) : pathSoFar / name

            let parentNodeID     = try currentFolder.requireID()
            let existingChildren = existingSteps.filter {
                $0.depth + depthOffset == index + 1 && $0.node.parentNodeID == parentNodeID
            }

            if existingChildren.count > 1 {
                // Can happen when folder and file have same name
                throw NodeError.nameCollision(path: pathSoFar.string, existingKind: existingChildren[0].node.kind)
            }

            // What the walk read of this folder's pin, or nil when it has to be asked: a
            // folder made here, or one with no row for the port — which `isPinned` refuses
            // as a damaged graph, and should go on refusing.
            var knownPinnedPort: OutputPort?

            if let existingChild = existingChildren.first {
                if existingChild.node.kind != Folder.kind {
                    // Previously a `break`, which silently returned the last good folder
                    // and left the caller believing a path had been created that had not.
                    throw NodeError.nameCollision(path: pathSoFar.string, existingKind: existingChild.node.kind)
                }
                currentFolder   = existingChild.node
                knownPinnedPort = existingChild.ports[pinnedSymbolID]
            } else {
                assert(!pathSoFar.string.hasSuffix("/"))
                assert(!pathSoFar.string.hasPrefix("/"))

                let specNode = GraphSpecNode(Folder.self, properties: [Folder.pathProperty: pathSoFar.string])
                let childFollows  = forAChild || index < names.count - 1
                let (fromNode, _) = try specNode.findOrCreateMatchingNode(outputIfCreated: { node in
                    childFollows ? try (node as? Folder)?.didCreateOnTheWayToAChild() : nil
                })
                var newFolder = fromNode
                newFolder.parentNodeID = (try currentFolder.requireID())
                try database.node.update(newFolder)

                try newFolder.makeNode().notifyParentThisChildAdded()
                currentFolder = newFolder

                let remainingNames = Array(names[(index + 1)...])
                existingSteps = try database.node.selectPath(below: try newFolder.requireID(), names: remainingNames,
                                                             portSymbolIDs: [pinnedSymbolID])
                depthOffset   = index + 1
            }

            if pinned {
                // `isPinned`'s own reading, of the row the walk already holds.
                let knownPinned = try knownPinnedPort.map { try !$0.asNodeValue().isNoValue }
                if let folder = try currentFolder.makeNode() as? Folder, try !(knownPinned ?? folder.isPinned) {
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
        // A kind this server does not link is scheduled as any reader is: the pass that
        // picks it up publishes its error (`publishUnlinkedKindError`).
        if linkedNodeType != nil {
            let node = try self.makeNode()
            guard type(of: node).descriptor.hasInputs else {
                Debug.warn("ignoring a request to schedule \(self) / \(type(of: node)), which declares no inputs")
                return
            }
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
        // A folder's three derived values are rebuilt on demand (B-25, B-26, B-135): reading
        // one is what makes it current.
        if kind == Folder.kind {
            switch outputPort {
            case Folder.folderManifestOutputPort:  try Folder.flushManifestIfDirty(nodeID: try requireID())
            case Folder.contentRootOutputPort, Folder.pushedContentRootOutputPort:
                try Folder.flushContentRootIfDirty(nodeID: try requireID())
            case Folder.subtreeManifestOutputPort: try Folder.flushSubtreeManifestIfDirty(nodeID: try requireID())
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

        for outputPort in try outputPortNames() {
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
