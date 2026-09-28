//
//  Folder.swift
//  semel
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation
import SemelNodeKit

public struct Folder: Node, HasPath, Pinnable, UserDeletable {
    public static let kind: UInt = 1

    // The values live in SemelNodeKit, where a node can reach them without
    // depending on the engine. Kept here under their long-standing names so the call
    // sites read as they always have.
    public static let inputFileSystemName  = FileSystemName.input
    public static let outputFileSystemName = FileSystemName.output

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        Self.instantiationCount.increment()
        self.thisNode = thisNode
        try placeInFileSystem()
    }

    /// How many `Folder` values this process has built.
    ///
    /// A test observable, of a piece with `manifestRebuildCount`. `everyChildCanBeDeleted`
    /// answers for a folder's leaf children out of one query per kind, but descends into an
    /// unpinned subfolder by fetching its row and building a `Folder` around it — so the
    /// deletability of a tree costs a node per subfolder in it, and whether that count
    /// follows a tree's depth or something worse is what `FolderDeletabilityScaleTests`
    /// reads this for. Not read by the engine.
    static let instantiationCount = SharedCounter()

    var inputFileSystem: NodeRecord {
        get throws {
            try Folder.inputFileSystem
        }
    }

    func canBePinned() -> Bool {
        // HACK
        containingPath.hasPrefix(.init(Folder.inputFileSystemName))
//        self.parentNode?.canBePin
    }

    /// A folder arrives with both of its ports written.
    ///
    /// `manifest` carries a listing from the start, empty until something is pushed under
    /// it: a node reading a folder as a tree reads a folder with nothing in it as a tree
    /// with nothing in it, and gets to decide for itself whether that is a problem.
    ///
    /// `pinned` carries the state of a value nobody has produced, which is what a folder
    /// nobody pushed into is — the same state a file nobody pushed holds, so a report
    /// names the two alike. A folder outside the input file system cannot be pinned at all
    /// and holds a value instead, so it is never mistaken for one waiting to be pushed.
    ///
    /// `contentRoot` carries the fold over a folder with nothing in it, which is a value
    /// like any other: an empty tree has a content hash, and it is the same hash wherever
    /// an empty tree stands.
    public func didCreate() throws -> ProcessOutput? {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest().toJSON().intern()),
                             Self.contentRootOutputPort: .value(try buildContentRootDocument().intern()),
                             Self.pinnedOutputPort: canBePinned() ? .noValue(reason: .initializing) : .value("")], // HACK
              inputWireSpecs: [:])
    }

    var path: Path {
        .init(thisNode.properties[Self.pathProperty]!)
    }

    // Ignores the fact that a node that has wires to/from it should never be deleted; that check needs to happen outside this
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
    /// building a node per child and asking it. Asking each child directly is
    /// expensive four ways at once: whole `NodeRecord` rows with their properties decoded, a
    /// node constructed per child, an output-port read inside each `isPinned`, and no way to
    /// stop at the first objection. This recurses, so that is the cost *per level* — during
    /// a delete cascade or a collection sweep, which is when whole trees come through here.
    ///
    /// Losing the polymorphism is the price, so the kind-to-port mapping is spelled out and
    /// `FolderDeletabilityTests` checks it says what asking each child says. The types
    /// that can be a folder's children are `Folder`, `StaticFile` and `OutputFile`; only the
    /// first two override `canBeDeleted`, and the third takes the default `true`.
    private func everyChildCanBeDeleted() throws -> Bool {
        let children = try database.node.selectChildSummaries(parentNodeID: try thisNode.requireID())
        guard !children.isEmpty else {
            return true
        }

        let pinned = try pinnedStates(of: children)

        // `canBePinned()` asks about the *containing* path, which for every one of these
        // children is this folder's path — so it is one answer, not one per child.
        let childFolderCanBePinned = path.hasPrefix(.init(Folder.inputFileSystemName))

        var unpinnedSubfolderIDs: [ObjectID] = []

        for child in children {
            switch child.kind {
            case StaticFile.kind:
                // A pushed file is held by the user rather than by the graph.
                if pinned[child.id] == true {
                    return false
                }

            case Folder.kind:
                if childFolderCanBePinned && pinned[child.id] == true {
                    return false
                }
                unpinnedSubfolderIDs.append(child.id)

            default:
                break   // Everything else takes the default `canBeDeleted()`, which is true.
            }
        }

        // Descend only into the subfolders that did not already answer for themselves.
        for subfolderID in unpinnedSubfolderIDs {
            let nodeRecord = try database.node.select(nodeID: subfolderID)
            guard let subfolder = try nodeRecord.makeNode() as? Folder else {
                continue
            }
            guard try subfolder.everyChildCanBeDeleted() else {
                return false
            }
        }

        return true
    }

    // The manifest is a non-recursive list of immediate children
    static let pathProperty = "path"
    static let folderManifestOutputPort = "manifest"

    /// The Merkle root of everything under this folder (B-26): the hash of the document
    /// `FolderContentRoot` folds from each child's own content, a subfolder's line carrying
    /// that subfolder's root.
    ///
    /// A port of its own rather than a field of the manifest. The manifest is what a folder's
    /// children are called, and nearly everything downstream of a folder — `ProjectFinder`
    /// on `input:`, a converter on a target folder — is wired to it to learn the file set.
    /// Folding content into that value would move it on every edit to every file below, and
    /// re-run all of them for a question whose answer did not change. A consumer that wants
    /// the content asks for the content.
    static let contentRootOutputPort = "contentRoot"

    // Nodes are not normally allowed to store state. A Folder in the input file system, however, needs to know if the user deleted it
    // (or never pushed it) but it has references from the graph -- called a ghost or "not pinned". StaticFiles represent this ghost
    // state by clearing their output value. So we use this "fake" (unlikely to be connected) output as a way to store this ghost/not-pinned state.
    static let pinnedOutputPort = "pinned"

    public static let descriptor = NodeDescriptor(inputPorts: [],
                                                  outputPorts: [folderManifestOutputPort,
                                                                contentRootOutputPort,
                                                                pinnedOutputPort])

    /// Never reached in a working graph: a node declaring no input ports is not scheduled,
    /// so nothing asks it to process. An ordinary error rather than a trap — a node is not
    /// the right place to enforce the engine's invariants, and a third-party one should not
    /// be able to bring the process down.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.other(message: "\(Self.self) declares no input ports and cannot process")
    }

    // MARK: - Manifest freshness (B-25)
    //
    // A child change does not rebuild the manifest; it marks this folder dirty, and the
    // manifest is rebuilt exactly once when something next needs it — the next processing
    // pass (`flushDirtyManifests`, before it selects scheduled nodes, since the rebuild's
    // port write is what schedules the manifest's consumers) or a direct read of the port
    // (`NodeRecord.readFromOutputPort` asks `flushManifestIfDirty` first). A reader never
    // sees a stale manifest, because reading is what rebuilds it; a push of N files costs
    // one rebuild instead of 2N, each O(N).
    //
    // The mark is a row in the Metadata table rather than an in-memory set, so a crash
    // between a push and the next pass leaves a row that the next launch's first pass
    // flushes, instead of a stale manifest nothing would ever rebuild. The order matters
    // for correctness under a concurrent push: every mutation marks *after* it has
    // mutated, and the flush clears the mark *before* it rebuilds, so a mark the flush
    // removes always belongs to a change the rebuild can see.
    //
    // A folder carries two marks, because it publishes two values a child change can move
    // and they travel different distances (B-26).
    //
    // The manifest is names and pinned state, so only this folder's own children can move
    // it; a mark for it goes no further than the folder whose child changed, exactly as it
    // did before. The content root folds in each child's content, so a change anywhere
    // below moves every root above it: a recompute that moves the root marks the folder
    // above, and the flush's rounds walk the change to the top. That is why the two are on
    // separate ports — a consumer wired to a manifest is asking what a folder holds, and is
    // not woken by an edit to what is in it.
    //
    // What a direct read of one port guarantees is therefore that folder's own children.
    // The asymmetry is in where the rebuild happens: a read flushes *this* folder
    // (`flushManifestIfDirty` / `flushContentRootIfDirty`), while the mark an ancestor
    // needs is only written once this folder has been recomputed. An ancestor is current
    // once the flush has drained, which every processing pass does before it selects
    // anything, so no consumer is ever handed a root the change had not reached.

    static let manifestDirtyKeyPrefix    = "manifestDirty/"
    static let contentRootDirtyKeyPrefix = "contentRootDirty/"

    private static func manifestDirtyKey(_ nodeID: ObjectID) -> String {
        "\(manifestDirtyKeyPrefix)\(nodeID)"
    }

    private static func contentRootDirtyKey(_ nodeID: ObjectID) -> String {
        "\(contentRootDirtyKeyPrefix)\(nodeID)"
    }

    /// Both marks: a change to one of this folder's children can move either value.
    private func markManifestDirty() throws {
        let nodeID = try thisNode.requireID()
        try database.metadata.upsert(key: Self.manifestDirtyKey(nodeID), value: "1")
        try database.metadata.upsert(key: Self.contentRootDirtyKey(nodeID), value: "1")
        // The rebuild a child change once did here wrote the manifest port, which scheduled
        // the folder's consumers and so woke the processing loop. The mark defers the
        // rebuild to the loop's next pass — which therefore has to be asked for, or a push
        // into a sleeping engine leaves every manifest dirty and nothing ever scheduled.
        BuildEngine.shared?.signalWorkAvailable()
    }

    /// The root alone, for a folder whose *descendant* moved. Taken by node id rather than
    /// by node, because the caller is a folder recomputing its own root and has its
    /// parent's id in hand: building the parent to mark it would read a row and construct a
    /// node per level of every walk up the tree.
    static func markContentRootDirty(nodeID: ObjectID) throws {
        try DatabaseLayer.shared!.metadata.upsert(key: contentRootDirtyKey(nodeID), value: "1")
        BuildEngine.shared?.signalWorkAvailable()
    }

    /// Rebuilds the manifest of every folder marked dirty, recomputes the content root of
    /// every folder marked for that, and collects the folders that their last child took
    /// with it. Returns how many *manifests* it rebuilt, so a caller can tell whether
    /// anything wired to one may now be scheduled.
    ///
    /// A collected folder marks its parent, and a root that moved marks the folder above,
    /// so the marks are drained in rounds until none is left; the rounds walk up the tree
    /// and there are at most as many as it is deep.
    @discardableResult
    static func flushDirtyManifests() throws -> Int {
        let database = DatabaseLayer.shared!
        var flushed = 0
        while true {
            let manifestKeys    = try database.metadata.selectKeys(withPrefix: manifestDirtyKeyPrefix)
            let contentRootKeys = try database.metadata.selectKeys(withPrefix: contentRootDirtyKeyPrefix)
            guard !manifestKeys.isEmpty || !contentRootKeys.isEmpty else {
                return flushed
            }

            for key in manifestKeys {
                guard let nodeID = ObjectID(key.dropFirst(manifestDirtyKeyPrefix.count)),
                      let folder = try markedFolder(nodeID: nodeID, clearing: key) else {
                    continue
                }
                guard try !folder.isAbandoned() else {
                    try folder.delete()
                    continue
                }
                try folder.refreshManifest()
                flushed += 1
            }

            // After the manifests, so that a folder its last child took with it is gone by
            // the time its root would have been recomputed.
            for key in contentRootKeys {
                guard let nodeID = ObjectID(key.dropFirst(contentRootDirtyKeyPrefix.count)),
                      let folder = try markedFolder(nodeID: nodeID, clearing: key) else {
                    continue
                }
                try folder.refreshContentRoot()
            }
        }
    }

    /// The folder a mark names, with the mark cleared first — before the rebuild, so that a
    /// mark the flush removes always belongs to a change the rebuild can see. Nil where the
    /// folder has been collected since it was marked: then there is nothing to rebuild and
    /// the row was all that was left of it.
    private static func markedFolder(nodeID: ObjectID, clearing key: String) throws -> Folder? {
        let database = DatabaseLayer.shared!
        try database.metadata.delete(key: key)
        guard let nodeRecord = try database.node.find(nodeID: nodeID) else {
            return nil
        }
        return try nodeRecord.makeNode() as? Folder
    }

    /// Rebuilds one folder's manifest if it is marked dirty. Called on the way into a
    /// direct read of the manifest port.
    ///
    /// A read rebuilds; it never collects, since the caller is about to read the port of
    /// the node it would delete. A folder whose last child has gone is marked again
    /// instead, and the next pass collects it.
    static func flushManifestIfDirty(nodeID: ObjectID) throws {
        let database = DatabaseLayer.shared!
        let key = manifestDirtyKey(nodeID)
        guard try database.metadata.select(key: key) != nil else {
            return
        }
        try database.metadata.delete(key: key)
        guard let folder = try database.node.select(nodeID: nodeID).makeNode() as? Folder else {
            return
        }
        try folder.refreshManifest()
        if try folder.isAbandoned() {
            try folder.markManifestDirty()
        }
    }

    /// Recomputes one folder's content root if it is marked, on the way into a direct read
    /// of that port. The folder's own children, not the tree below it: a read that walked
    /// down would be O(tree), which is the cost the marks exist to avoid.
    static func flushContentRootIfDirty(nodeID: ObjectID) throws {
        let database = DatabaseLayer.shared!
        let key = contentRootDirtyKey(nodeID)
        guard try database.metadata.select(key: key) != nil else {
            return
        }
        try database.metadata.delete(key: key)
        guard let folder = try database.node.select(nodeID: nodeID).makeNode() as? Folder else {
            return
        }
        try folder.refreshContentRoot()
    }

    public func onChildAdded(nodeID: ObjectID) throws {
        try markManifestDirty()
    }

    public func onChildContentChanged(nodeID: ObjectID, name: String) throws {
        try markManifestDirty()
    }

    public func onChildDeleted(nodeID: ObjectID) throws {
        // Deferred like every other child change: a rebuild here is O(children) and a
        // collector takes children one at a time, so rebuilding as they go costs one walk
        // of the folder per file it holds. The self-delete check is deferred with it, for
        // the same reason — it reads every child too.
        try markManifestDirty()
    }

    /// Whether nothing holds this folder in the graph any more: no children, no pin of its
    /// own, and no wires either way.
    ///
    /// Emptiness rather than `canBeDeleted()`: that one answers whether the *remaining*
    /// children could each be collected, which is true while children still exist, and a
    /// folder deleted from under them leaves their cascade looking for a parent that is
    /// gone — a `nodeNotFound` mid-cascade and orphaned nodes behind it.
    private func isAbandoned() throws -> Bool {
        try thisNode.allChildren.isEmpty
            && !(canBePinned() && isPinned)
            && hasNoOutputWires()
            && hasNoInputWires()
    }

    /// A folder is a source too, and its `pinned` port holds the same three states a file's
    /// does: a value once the user pushed it, the state of a value nobody has produced while
    /// nothing has been pushed into it, and `deleted` once the user takes it back out. A
    /// folder that cannot be pinned carries a value from its creation and so has nothing
    /// else to show.
    public var pinnedValue: NodeValue? {
        get throws {
            try thisNode.readFromOutputPort(Self.pinnedOutputPort)
        }
    }

    /// Both directions are refused on a folder that cannot be pinned, not only the pin.
    /// Such a folder holds a value on this port from its creation and is outside the input
    /// file system, so there is nothing for the user to have taken away: unpinning one
    /// would leave it saying it was deleted, in a report line naming a path the reader
    /// never pushed.
    func setPinned(_ pinned: Bool) throws {
        guard canBePinned() else {
            return
        }
        // Unpinning is the user taking the folder back out of the input file system, which
        // is the deleted state and not the never-produced one a fresh folder holds.
        try thisNode.writeToOutputPort(Self.pinnedOutputPort,
                                       value: pinned ? .value("true".intern()) : .noValue(reason: .deleted))

        try notifyParentOfChildContentChange()
    }

    /// How many manifests have been built in this process. Read by tests that pin the cost
    /// of a push in rebuilds rather than in seconds, which a timing assertion cannot do
    /// reliably.
    static let manifestRebuildCount = SharedCounter()

    /// How many content roots have been folded in this process, the same measurement for
    /// the other value a folder publishes. Separate, because the two are rebuilt for
    /// different reasons and a test pins each against what moves it: a manifest against
    /// this folder's children, a root against the depth of the tree below the change.
    static let contentRootRebuildCount = SharedCounter()

    private func buildManifest() throws -> FolderManifest {
        Self.manifestRebuildCount.increment()
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

    /// The document this folder's content root is the hash of: one line per child, carrying
    /// what that child's content is. A subfolder contributes its own root, which is how one
    /// hash comes to stand for a whole tree. `FolderContentRoot` states the format and the
    /// order; this supplies the lines.
    private func buildContentRootDocument() throws -> String {
        Self.contentRootRebuildCount.increment()
        let children = try database.node.selectChildSummaries(parentNodeID: try thisNode.requireID())
        let content  = try contentStates(of: children)

        var lines = [(name: String, kind: FolderChildKind, content: FolderChildContent)]()
        for child in children {
            switch child.kind {
            // A child of a kind the fold reads, with no row for the port its content is on,
            // has had nothing produced on it — the same reading `asNodeValue` gives.
            case StaticFile.kind:
                lines.append((child.name!, .file, content[child.id] ?? .notProduced))

            case Folder.kind:
                lines.append((child.name!, .folder, content[child.id] ?? .notProduced))

            default:
                // Every other kind under a folder is a product, whose content the fold does
                // not reach. `FolderChildContent.notFolded` says why, and saying it here by
                // `kind` rather than by absence from a dictionary means a node kind that
                // becomes a folder's child cannot acquire the answer by accident.
                lines.append((child.name!, .other, .notFolded))
            }
        }

        return FolderContentRoot.document(of: lines)
    }

    /// The content of every child that carries it on a port of its own, in one query per
    /// kind — the shape `pinnedStates` uses and for the same reason.
    ///
    /// A file's bytes are on its output port, and a folder's content root is on its. The
    /// subfolder's root was folded the same way, so putting it in a line is what makes this
    /// folder's root identify its whole subtree rather than only what is directly in it.
    private func contentStates(of children: [NodeChildSummary]) throws -> [ObjectID: FolderChildContent] {
        var result: [ObjectID: FolderChildContent] = [:]
        let parentNodeID = try thisNode.requireID()

        for (kind, portName) in [(Folder.kind,     Folder.contentRootOutputPort),
                                 (StaticFile.kind, StaticFile.outputPort)] {
            let ports = try database.node.selectChildPorts(parentNodeID: parentNodeID,
                                                           nameSymbolID: portName.asSymbolID())
            for child in children where child.kind == kind {
                result[child.id] = try ports[child.id].map { .init(try $0.asNodeValue()) } ?? .notProduced
            }
        }

        return result
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
            let ports = try database.node.selectChildPorts(parentNodeID: parentNodeID,
                                                           nameSymbolID: portName.asSymbolID())
            for child in children where child.kind == kind {
                // Absent or non-value both mean not pinned — the same reading `isPinned`
                // gives, where a missing port becomes a noValue.
                result[child.id] = ports[child.id]?.valueKind == .value
            }
        }

        return result
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a node with outputs, however.
    func refreshOutputs() throws {
        try refreshManifest()
        try refreshContentRoot()
    }

    /// The names and pinned state of this folder's children. Nothing is marked above:
    /// what a folder is called and what it holds are this folder's own business, and a
    /// change to them reaches its parent as an ordinary child change if it reaches it at
    /// all.
    func refreshManifest() throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest().toJSON().intern()))
    }

    /// The fold over this folder's children, published as a hash.
    ///
    /// A root that moved is a change to this folder's content as the folder above it sees
    /// it, so it marks that one. Marking rather than recomputing keeps the walk to one
    /// level per round of the flush, and the rounds are bounded by the depth of the tree:
    /// an edit costs one fold per ancestor, never one per folder.
    func refreshContentRoot() throws {
        let changed = try thisNode.writeToOutputPort(
            Self.contentRootOutputPort,
            value: .value(try buildContentRootDocument().intern()))

        if changed, let parentNodeID = thisNode.parentNodeID {
            try Folder.markContentRootDirty(nodeID: parentNodeID)
        }
    }

    public func deleteInInputFileSystem() throws {

        // Delete children or unpin them
        for child in try thisNode.allChildren {
            if let userDeletableChild = try child.makeNode() as? UserDeletable {
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
    /// node whose path is "input:" or "output:", found or created by spec like any other
    /// node. They live here rather than on BuildEngine so a node does not have to
    /// reach for the engine — and so the engine is not a dependency of the layer below it.
    public static var inputFileSystem: NodeRecord {
        get throws { try root(named: inputFileSystemName) }
    }

    /// The output file system's root Folder.
    public static var outputFileSystem: NodeRecord {
        get throws { try root(named: outputFileSystemName) }
    }

    /// Node IDs of the two file-system roots, so the common case is one indexed read by
    /// primary key instead of a graph-spec lookup wrapped in a write transaction.
    ///
    /// `root(named:)` is on a very hot path: every `resolveFolderID` goes through it, which
    /// is every `StaticFile` and every `Folder` init. The identity lookup it did was itself
    /// cheap — `Node.identity` is unique-indexed — but `findOrCreateMatchingNode` wraps
    /// find-and-create in a transaction, so the read paid for a write it never did.
    ///
    /// The ID is cached rather than the NodeRecord: `NodeRecord` is a mutable value type, and handing
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

    private static func root(named name: String) throws -> NodeRecord {
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
           cached.properties[Folder.pathProperty] == name {
            return cached
        }

        let specNode = GraphSpecNode(typeName: "Folder",
                                        properties: [.init(key: "path", value: name)],
                                        inputs: [],
                                        outputs: [])
        let (rootNode, _) = try specNode.findOrCreateMatchingNode()
        cacheRootID(try rootNode.requireID(), named: name)
        return rootNode
    }
}
