//
//  Folder.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation
import SemelNodeKit

public struct Folder: NodeFunction, HasPath, Pinnable, UserDeletable {
    public static let kind: UInt = 1

    // The values live in SemelNodeKit, where a node function can reach them without
    // depending on the engine. Kept here under their long-standing names so the call
    // sites read as they always have.
    public static let inputFileSystemName  = FileSystemName.input
    public static let outputFileSystemName = FileSystemName.output

    public var thisNode: Node

    public init(thisNode: Node) throws {
        self.thisNode = thisNode
        try placeInFileSystem()
    }

    var inputFileSystem: Node {
        get throws {
            try Folder.inputFileSystem
        }
    }

    func canBePinned() -> Bool {
        // HACK
        containingPath.hasPrefix(.init(Folder.inputFileSystemName))
//        self.parentNodeFunction?.canBePin
    }

    public func didCreate() throws -> ProcessOutput? {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest().toJSON().intern()),
                             Self.pinnedOutputPort: canBePinned() ? .noValue(reason: .error(messageDataObjectHash: try "Deleted".intern())) : .value("")], // HACK
              inputWireExpectations: [:])
    }

    var path: Path {
        .init(thisNode.properties["path"]!)
    }

    // Ignores the fact that a Node that has wires to/from it should never be deleted; that check needs to happen outside this
    public func canBeDeleted() throws -> Bool {
        // Own state first. It is one port read, it settles the question on its own, and in
        // the input file system a folder the user made is pinned — so this is the common
        // answer and it now costs nothing to reach.
        if try canBePinned() && isPinned {
            return false
        }
        return try everyChildCanBeDeleted()
    }

    /// Whether anything under this folder objects to being collected.
    ///
    /// Reads pinned state per kind in one query, exactly as `buildManifest` does, rather than
    /// building a node function per child and asking it. Asking each child directly is
    /// expensive four ways at once: whole `Node` rows with their properties decoded, a node
    /// function constructed per child, an output-port read inside each `isPinned`, and no way
    /// to stop at the first objection. This recurses, so that is the cost *per level* — during
    /// a delete cascade or a collection sweep, which is when whole trees come through here.
    ///
    /// Losing the polymorphism is the price, so the kind-to-port mapping is spelled out and
    /// `FolderDeletabilityTests` checks it says what asking each child says. The types
    /// that can be a folder's children are `Folder`, `StaticFile` and `OutputFile`; only the
    /// first two override `canBeDeleted`, and the third takes the default `true`.
    private func everyChildCanBeDeleted() throws -> Bool {
        let children = try database.node.selectChildSummaries(parentNodeID: try thisNode.requireID())
        guard !children.isEmpty else { return true }

        let pinned = try pinnedStates(of: children)

        // `canBePinned()` asks about the *containing* path, which for every one of these
        // children is this folder's path — so it is one answer, not one per child.
        let childFolderCanBePinned = path.hasPrefix(.init(Folder.inputFileSystemName))

        var unpinnedSubfolderIDs: [ObjectID] = []

        for child in children {
            switch child.kind {
            case StaticFile.kind:
                // A pushed file is held by the user rather than by the graph.
                if pinned[child.id] == true { return false }

            case Folder.kind:
                if childFolderCanBePinned && pinned[child.id] == true { return false }
                unpinnedSubfolderIDs.append(child.id)

            default:
                break   // Everything else takes the default `canBeDeleted()`, which is true.
            }
        }

        // Descend only into the subfolders that did not already answer for themselves.
        for subfolderID in unpinnedSubfolderIDs {
            let node = try database.node.select(nodeID: subfolderID)
            guard let subfolder = try node.nodeFunction() as? Folder else { continue }
            guard try subfolder.everyChildCanBeDeleted() else { return false }
        }

        return true
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    // Nodes are not normally allowed to store state. A Folder in the input file system, however, needs to know if the user deleted it
    // (or never pushed it) but it has references from the graph -- called a ghost or "not pinned". StaticFiles represent this ghost
    // state by clearing their output value. So we use this "fake" (unlikely to be connected) output as a way to store this ghost/not-pinned state.
    static let pinnedOutputPort = "pinned"

    public static let descriptor = NodeFunctionDescriptor(inputPorts: [], outputPorts: [folderManifestOutputPort, pinnedOutputPort])

    /// Never reached in a working graph: a node declaring no input ports is not scheduled,
    /// so nothing asks it to process. An ordinary error rather than a trap — a node is not
    /// the right place to enforce the engine's invariants, and a third-party one should not
    /// be able to bring the process down.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.other(message: "\(Self.self) declares no input ports and cannot process")
    }

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    public func onChildAdded(nodeID: ObjectID) throws {
        try refreshOutputs()
    }

    public func onChildContentChanged(nodeID: ObjectID, name: String) throws {
        try refreshOutputs()
    }

    public func onChildDeleted(nodeID: ObjectID) throws {
        try refreshOutputs()

        // Only self-delete when the folder is truly empty. Using canBeDeleted() here is wrong:
        // it returns true whenever all *remaining* children are individually deletable, which
        // causes premature self-deletion while other children still exist in the DB. When the
        // second child's cascade later calls notifyParentOfChildDeletion(), the parent is gone
        // and the lookup throws nodeNotFound, aborting the cascade and leaving orphaned nodes.
        if try thisNode.allChildren.isEmpty && !(canBePinned() && isPinned) && hasNoOutputWires() && hasNoInputWires() {
            try delete()
        }
    }

    public var isPinned: Bool {
        get throws {
            try !thisNode.readFromOutputPort(Self.pinnedOutputPort).isNoValue
        }
    }

    func setPinned(_ pinned: Bool) throws {
        if !canBePinned() && pinned {
            return
        }
        try thisNode.writeToOutputPort(Self.pinnedOutputPort,
                                       value: pinned ? .value("true".intern()) : .noValue(reason: .error(messageDataObjectHash: "Deleted/Nonexistent".intern())))

        try notifyParentOfChildContentChange()
    }

    private func buildManifest() throws -> FolderManifest {
        // Summaries rather than whole nodes: a manifest entry is a name and two flags, and
        // decoding every child's properties to produce that was most of the rebuild cost.
        let children = try database.node.selectChildSummaries(parentNodeID: try thisNode.requireID())
        let pinned   = try pinnedStates(of: children)

        var folderManifestEntries = [FolderManifestEntry]()
        for child in children {
            folderManifestEntries.append(.init(name: child.name!,
                                               isFolder: child.kind == Folder.kind,
                                               isPinned: pinned[child.id] ?? false))
        }

        return .init(baseFolderPath: path.string, entries: folderManifestEntries)
    }

    /// Pinned state for every child, in one query per kind that has one.
    ///
    /// This used to ask each child individually, through its `Pinnable` conformance. Since
    /// a manifest is rebuilt on *every* child change, pushing N files into a folder cost
    /// N²/2 database round trips: 200 files took 3.4s, and the time quadrupled with each
    /// doubling. Reading the port directly loses the polymorphism, so the mapping from
    /// kind to port is spelled out here and pinned by a test asserting it still agrees
    /// with each type's own `isPinned`.
    private func pinnedStates(of children: [NodeChildSummary]) throws -> [ObjectID: Bool] {
        var result: [ObjectID: Bool] = [:]

        let parentNodeID = try thisNode.requireID()

        for (kind, portName) in [(Folder.kind,     Folder.pinnedOutputPort),
                                 (StaticFile.kind, StaticFile.outputPort)] {
            let kinds = try database.node.selectChildPortKinds(parentNodeID: parentNodeID,
                                                               nameSymbolID: try portName.asSymbolID())
            for child in children where child.kind == kind {
                // Absent or non-value both mean not pinned — the same reading `isPinned`
                // gives, where a missing port becomes a noValue.
                result[child.id] = kinds[child.id] == .value
            }
        }
        return result
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a Node with outputs, however.
    func refreshOutputs() throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest().toJSON().intern()))
    }

    public func deleteInInputFileSystem() throws {

        // Delete children or unpin them
        for child in try thisNode.allChildren {
            if let userDeletableChild = try child.nodeFunction() as? UserDeletable {
                try userDeletableChild.deleteInInputFileSystem()
            } else {
                throw NodeError.other(message: "Cannot delete Folder because one or more children are not deletable")
            }
        }

        try setPinned(false)

        if try hasNoOutputWires() && canBeDeleted() {
            try delete()
        }
    }
}

// MARK: - File system roots

extension Folder {

    /// The input file system's root Folder.
    ///
    /// These roots are a property of the graph, not of the engine: each is just the Folder
    /// node whose path is "input:" or "output:", found or created by shape like any other
    /// node. They live here rather than on BuildEngine so a node function does not have to
    /// reach for the engine — and so the engine is not a dependency of the layer below it.
    public static var inputFileSystem: Node {
        get throws { try root(named: inputFileSystemName) }
    }

    /// The output file system's root Folder.
    public static var outputFileSystem: Node {
        get throws { try root(named: outputFileSystemName) }
    }

    /// Node IDs of the two file-system roots, so the common case is one indexed read by
    /// primary key instead of a graph-shape lookup wrapped in a write transaction.
    ///
    /// `root(named:)` is on a very hot path: every `resolveFolderID` goes through it, which
    /// is every `StaticFile` and every `Folder` init. The searchKey lookup it did was itself
    /// cheap — `Node.searchKey` is unique-indexed — but `findOrCreateMatchingNode` wraps
    /// find-and-create in a transaction, so the read paid for a write it never did.
    ///
    /// The ID is cached rather than the Node: `Node` is a mutable value type, and handing
    /// out a stale copy invites writing it back.
    ///
    /// Locked because node processing runs in a concurrent TaskGroup, and resolution reaches
    /// here from more than one thread. Most writes happen inside a transaction and are
    /// serialised by GRDB's writer queue, but reads are not — `inputFileSystem` is called
    /// from plain reads too — and a Dictionary read concurrent with a write is undefined,
    /// not merely stale.
    private static let rootCacheLock = NSLock()
    private static var cachedRootIDs: [String: ObjectID] = [:]

    private static func cachedRootID(named name: String) -> ObjectID? {
        rootCacheLock.lock()
        defer { rootCacheLock.unlock() }
        return cachedRootIDs[name]
    }

    private static func cacheRootID(_ id: ObjectID, named name: String) {
        rootCacheLock.lock()
        defer { rootCacheLock.unlock() }
        cachedRootIDs[name] = id
    }

    private static func root(named name: String) throws -> Node {
        // Verified, not trusted, because a cached ID can be wrong in two ways.
        //
        // It can point at nothing: the roots are *not* permanent. `canBePinned()` asks
        // whether the containing path is under `input:`, and a root's containing path is
        // empty — so it is false for the roots themselves, and a root with no children and
        // no output wires is collectable. The collector takes it and the next caller has to
        // build it again, which is why this is find-*or-create*.
        //
        // Worse, it can point at the wrong node. Every test builds a fresh database, and a
        // fresh database reissues low rowids, so an ID carried over from the previous one
        // resolves to a real node that is not this root. Checking kind and path costs a
        // dictionary lookup on a row already fetched, and makes the cache correct without
        // depending on every test target remembering to clear it — which the CLI target,
        // having no TestGlobals of its own, would not have done.
        if let cachedID = cachedRootID(named: name),
           let cached = try? DatabaseLayer.shared.node.select(nodeID: cachedID),
           cached.kind == Folder.kind,
           cached.properties["path"] == name {
            return cached
        }

        let graphShape = GraphShapeNode(typeName: "Folder",
                                        properties: [.init(key: "path", value: name)],
                                        inputs: [],
                                        outputs: [])
        let (rootNode, _) = try graphShape.findOrCreateMatchingNode()
        cacheRootID(try rootNode.requireID(), named: name)
        return rootNode
    }
}
