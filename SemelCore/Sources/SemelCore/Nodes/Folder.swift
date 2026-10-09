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

    func canBePinned() throws -> Bool {
        // HACK
        try containingPath.hasPrefix(.init(Folder.inputFileSystemName))
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
    /// an empty tree stands. `subtreeManifest` likewise carries an empty tree's names.
    ///
    /// Folded over no children without reading any, because a folder being made has none:
    /// its id is new, `Node` never issues an id twice, and so no row can name it as a
    /// parent yet. A push makes every folder on the way to its files, and asking each one
    /// for children it could not have was a query per port and kind per folder. The
    /// children it then gets mark it (`markManifestDirty`), and the next pass folds it once
    /// over all of them, however many files the push brought it.
    public func didCreate() throws -> ProcessOutput? {
        let documents = try buildContentRootDocuments(of: [])
        return .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest(of: []).toJSON().intern()),
                                    Self.contentRootOutputPort: .value(try documents.whole.intern()),
                                    Self.pushedContentRootOutputPort: .value(try documents.pushed.intern()),
                                    Self.subtreeManifestOutputPort: .value(try FolderSubtreeManifest(entries: []).toJSON().intern()),
                                    Self.pinnedOutputPort: try initialPinnedValue(),
                                    Self.symbolicLinkOutputPort: Self.notASymbolicLink],
                     inputWireSpecs: [:])
    }

    /// What a folder made on the way to something placed below it is created with
    /// (`ensureEntirePathExistsAsFolders`): its three folds in the state of values nobody
    /// has produced yet. A push and a node's placement make every folder on the way and
    /// give each its child at once, and the empty listing `didCreate` writes would be a
    /// document stored per folder — named by the folder's path, so one of its own each —
    /// for the next pass to replace before anything read it.
    ///
    /// The child marks the folder as it is placed (`onChildAdded`), in the same
    /// transaction where a push is one, and from then on nothing reads one of these
    /// states: a read of the port flushes a marked folder first, so it is handed the fold
    /// as it would have been; a node wired to a folder is processed only after the flush
    /// that starts every selection; a fold of the folder above runs after this one, which
    /// is deeper; and a push comparing roots (B-132) takes no root of a marked folder or
    /// of any folder above one.
    func didCreateOnTheWayToAChild() throws -> ProcessOutput {
        .init(outputValues: [Self.folderManifestOutputPort:   .noValue(reason: .initializing),
                             Self.contentRootOutputPort:      .noValue(reason: .initializing),
                             Self.pushedContentRootOutputPort: .noValue(reason: .initializing),
                             Self.subtreeManifestOutputPort:  .noValue(reason: .initializing),
                             Self.pinnedOutputPort:           try initialPinnedValue(),
                             Self.symbolicLinkOutputPort:     Self.notASymbolicLink],
              inputWireSpecs: [:])
    }

    private func initialPinnedValue() throws -> NodeValue {
        try canBePinned() ? .noValue(reason: .initializing) : .value("") // HACK
    }

    /// What `symbolicLink` holds for a folder that is not a link.
    static let notASymbolicLink = NodeValue.value("")

    /// Stores the folder at `relativePath` in the input file system as a symbolic link
    /// holding `target`, creating it and the folders on the way pinned, as a pushed folder
    /// is. Returns whether that changed anything. What the link names is pushed below it
    /// as any folder's files are.
    public static func pushSymbolicLink(target: String, at relativePath: Path) throws -> Bool {
        let folderRecord = try Folder.inputFileSystem.ensureEntirePathExistsAsFolders(relativePath, pinned: true)
        guard let folder = try folderRecord.makeNode() as? Folder else {
            throw NodeError.nameCollision(path: relativePath.string, existingKind: folderRecord.kind)
        }
        return try folder.setSymbolicLinkTarget(target)
    }

    /// Records that this folder is a symbolic link holding `target` (B-77), and tells the
    /// folder above — whose manifest lists it and whose root folds it — when that changed.
    /// Returns whether it did.
    func setSymbolicLinkTarget(_ target: String) throws -> Bool {
        let changed = try thisNode.writeToOutputPort(Self.symbolicLinkOutputPort, value: .value(try target.intern()))
        if changed {
            try notifyParentOfChildContentChange()
        }
        return changed
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
        let childFolderCanBePinned = try path.hasPrefix(.init(Folder.inputFileSystemName))

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

    /// The content root over what a push of this folder sends, and nothing else: the same
    /// fold less every dot-named child, every child holding no content — a name a node
    /// asked for and nobody pushed, a file taken back out — every product, and every
    /// subfolder left holding nothing by that rule. It is the root `FolderContentRoot
    /// .root(ofFolderAt:)` folds from the disk, by construction, and so the one a
    /// dependency's lock is compared with (B-06, B-143): the lock locks what the push
    /// pushes.
    ///
    /// Beside `contentRoot` rather than instead of it. That root is the graph's whole
    /// state below the folder — a ghost and a removed file are part of what a consumer, or
    /// a push comparing roots (B-132), has to see — while a lock is taken from a copy on
    /// disk, which has no ghosts, and whose walk leaves every dot-name out. A dot-named
    /// file the graph holds because something asked for it by name, or a name a converter
    /// demanded that the copy lacks, would otherwise fail a lock nobody edited.
    ///
    /// Folded with `contentRoot`, from the same reads of the same children, so it is
    /// current exactly when that one is: the marks and the flush serve both.
    static let pushedContentRootOutputPort = "pushedContentRoot"

    /// The names, kinds and pinned state of everything below this folder at every depth
    /// (B-135): a `FolderSubtreeManifest`, whose document is this folder's children with
    /// each subfolder's own subtree manifest named by hash, so that one value stands for
    /// the whole tree while a fold reads only the children.
    ///
    /// A port of its own for both reasons the other two are separate. Not the manifest: a
    /// consumer of one folder's children is not asking about a name three folders down,
    /// and would be woken by one. Not the content root: a consumer walking a tree for its
    /// file set — a converter finding a target's resources, a builder expanding `**` — is
    /// asking what the tree is called, and an edit to a file in it does not change that.
    static let subtreeManifestOutputPort = "subtreeManifest"

    // Nodes are not normally allowed to store state. A Folder in the input file system, however, needs to know if the user deleted it
    // (or never pushed it) but it has references from the graph -- called a ghost or "not pinned". StaticFiles represent this ghost
    // state by clearing their output value. So we use this "fake" (unlikely to be connected) output as a way to store this ghost/not-pinned state.
    static let pinnedOutputPort = "pinned"

    /// What the folder holds as a symbolic link, when a push found it to be one that stays
    /// inside its own folder (B-77): the target, as the link holds it. The empty value for
    /// a folder that is not a link. Such a folder still holds what the link names, pushed as
    /// every folder link always was, so that everything walking it reads what it did; what
    /// this port adds is the fact, which the folder above folds and lists in its manifest,
    /// and which a walk building a tree places as the link rather than descending.
    ///
    /// A push only adds, and so only ever sets this: a link on disk replaced by a folder
    /// stays a link here until the folder is removed and pushed again, as a file removed
    /// from disk stays a file.
    static let symbolicLinkOutputPort = "symbolicLink"

    public static let descriptor = NodeDescriptor(inputPorts: [],
                                                  outputPorts: [folderManifestOutputPort,
                                                                contentRootOutputPort,
                                                                pushedContentRootOutputPort,
                                                                subtreeManifestOutputPort,
                                                                pinnedOutputPort,
                                                                symbolicLinkOutputPort])

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
    // A folder carries three marks, because it publishes three values a child change can
    // move and they travel different distances (B-26, B-135).
    //
    // The manifest is names and pinned state, so only this folder's own children can move
    // it; a mark for it goes no further than the folder whose child changed, exactly as it
    // did before. The content root folds in each child's content, so a change anywhere
    // below moves every root above it: a recompute that moves the root marks the folder
    // above, and the flush's rounds walk the change to the top. That is why the two are on
    // separate ports — a consumer wired to a manifest is asking what a folder holds, and is
    // not woken by an edit to what is in it.
    //
    // The subtree manifest travels like the root and moves like the manifest: a change of
    // names anywhere below moves every subtree manifest above it, one refold per ancestor
    // over its own children, and an edit to a file's bytes moves none — the refold of the
    // folder holding the file finds the same names, writes nothing and marks nothing above.
    //
    // What a direct read of one port guarantees is therefore that folder's own children.
    // The asymmetry is in where the rebuild happens: a read flushes *this* folder
    // (`flushManifestIfDirty` / `flushContentRootIfDirty`), while the mark an ancestor
    // needs is only written once this folder has been recomputed. An ancestor is current
    // once the flush has drained, which every processing pass does before it selects
    // anything, so no consumer is ever handed a root the change had not reached.

    static let manifestDirtyKeyPrefix        = "manifestDirty/"
    static let contentRootDirtyKeyPrefix     = "contentRootDirty/"
    static let subtreeManifestDirtyKeyPrefix = "subtreeManifestDirty/"

    private static func manifestDirtyKey(_ nodeID: ObjectID) -> String {
        "\(manifestDirtyKeyPrefix)\(nodeID)"
    }

    private static func contentRootDirtyKey(_ nodeID: ObjectID) -> String {
        "\(contentRootDirtyKeyPrefix)\(nodeID)"
    }

    private static func subtreeManifestDirtyKey(_ nodeID: ObjectID) -> String {
        "\(subtreeManifestDirtyKeyPrefix)\(nodeID)"
    }

    /// Every mark: a change to one of this folder's children can move any of the values.
    private func markManifestDirty() throws {
        let nodeID = try thisNode.requireID()
        try database.metadata.upsert(key: Self.manifestDirtyKey(nodeID), value: "1")
        try database.metadata.upsert(key: Self.contentRootDirtyKey(nodeID), value: "1")
        try database.metadata.upsert(key: Self.subtreeManifestDirtyKey(nodeID), value: "1")
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
        try DatabaseLayer.shared.metadata.upsert(key: contentRootDirtyKey(nodeID), value: "1")
        BuildEngine.shared?.signalWorkAvailable()
    }

    /// The subtree manifest alone, for a folder whose descendant's names moved; by node id
    /// for the reason `markContentRootDirty` is.
    static func markSubtreeManifestDirty(nodeID: ObjectID) throws {
        try DatabaseLayer.shared.metadata.upsert(key: subtreeManifestDirtyKey(nodeID), value: "1")
        BuildEngine.shared?.signalWorkAvailable()
    }

    /// Rebuilds the manifest of every folder marked dirty, recomputes the content root and
    /// the subtree manifest of every folder marked for those, and collects the folders that
    /// their last child took with it. Returns how many *manifests* it rebuilt, so a caller
    /// can tell whether anything wired to one may now be scheduled.
    ///
    /// A collected folder marks its parent, and a root or a subtree manifest that moved
    /// marks the folder above, so the marks are drained in rounds until none is left; the
    /// rounds walk up the tree and there are at most as many as it is deep.
    ///
    /// The flush is one transaction. A fold reads a dozen statements and writes a few rows,
    /// and outside a transaction every one of those reads is a `DatabaseQueue.read`, whose
    /// `PRAGMA query_only` expires every prepared statement on the connection, and every
    /// write is a commit of its own: a flush outside one spent a quarter of its database
    /// time preparing statements again. Measured on a cold push of 4,530 files, a
    /// transaction per round of the flush and one per fold each folded the tree more
    /// slowly than one for the whole flush (1.8 s and 2.0 s against 1.5 s, medians of
    /// five), so a request waiting on the queue waits for the flush, as it would for any
    /// other write of that size, and a reader sees the flush whole or not at all.
    ///
    /// Each fold is a savepoint inside it, so a fold that throws leaves its mark and
    /// publishes nothing — not the manifest without the root, and not the mark cleared
    /// over a value nobody folded. The folds beside it commit; its own is said and tried
    /// again on the next pass, and not again in this flush, whose rounds would otherwise
    /// meet the same mark for ever. Only the machine's failures — a full disk, a damaged
    /// database — leave the flush.
    @discardableResult
    static func flushDirtyManifests() throws -> Int {
        try DatabaseLayer.shared.withTransaction {
            var flushed = 0
            var refused = Set<String>()
            while true {
                let round = try flushRound(refusing: refused)
                flushed += round.manifestsRebuilt
                refused.formUnion(round.refused)
                guard round.foundMarks else {
                    return flushed
                }
            }
        }
    }

    /// What one round of the flush did.
    private struct FlushRound {
        var foundMarks       = false
        var manifestsRebuilt = 0
        /// The marks whose fold threw in this round, left in place.
        var refused          = Set<String>()
    }

    /// One round: every mark there is, less those already refused in this flush, folded
    /// deepest folder first.
    ///
    /// Deepest first because a root or a subtree manifest that moves marks the folder
    /// above, and a folder folded before its marked subfolders folds them as they were and
    /// is folded again in the next round, over what they became — once per round per level
    /// below it, each fold a document written to the object store. Below-first, the mark a
    /// subfolder leaves on its parent is one the parent's own fold in this round clears,
    /// having read what the subfolder published: a push of a new tree is folded once per
    /// folder, however deep.
    private static func flushRound(refusing refused: Set<String>) throws -> FlushRound {
        var round = FlushRound()
        let manifestMarks    = try deepestFirst(marked: manifestDirtyKeyPrefix, refusing: refused)
        let contentRootMarks = try deepestFirst(marked: contentRootDirtyKeyPrefix, refusing: refused)
        let subtreeMarks     = try deepestFirst(marked: subtreeManifestDirtyKeyPrefix, refusing: refused)
        guard !manifestMarks.isEmpty || !contentRootMarks.isEmpty || !subtreeMarks.isEmpty else {
            return round
        }
        round.foundMarks = true

        for mark in manifestMarks {
            let rebuilt = try foldAlone(mark, refused: &round.refused) {
                guard let folder = try markedFolder(nodeID: mark.nodeID, clearing: mark.key) else {
                    return false
                }
                guard try !folder.isAbandoned() else {
                    try folder.delete()
                    return false
                }
                try folder.refreshManifest()
                return true
            }
            if rebuilt == true {
                round.manifestsRebuilt += 1
            }
        }

        // After the manifests, so that a folder its last child took with it is gone by
        // the time its root would have been recomputed.
        for mark in contentRootMarks {
            _ = try foldAlone(mark, refused: &round.refused) {
                try markedFolder(nodeID: mark.nodeID, clearing: mark.key)?.refreshContentRoot()
            }
        }

        for mark in subtreeMarks {
            _ = try foldAlone(mark, refused: &round.refused) {
                try markedFolder(nodeID: mark.nodeID, clearing: mark.key)?.refreshSubtreeManifest()
            }
        }
        return round
    }

    /// One mark: its key, the folder it names, and how deep that folder is.
    private struct Mark {
        let key:    String
        let nodeID: ObjectID
        let depth:  Int
    }

    /// The marks under `prefix`, less `refused`, deepest folder first and by node id within
    /// a depth. A mark naming a folder that has been collected since sorts last, where
    /// `markedFolder` clears it.
    private static func deepestFirst(marked prefix: String, refusing refused: Set<String>) throws -> [Mark] {
        let database: DatabaseLayer = DatabaseLayer.shared
        var marks: [Mark] = []
        for key in try database.metadata.selectKeys(withPrefix: prefix) where !refused.contains(key) {
            guard let nodeID = ObjectID(key.dropFirst(prefix.count)) else {
                continue
            }
            let path  = try database.node.find(nodeID: nodeID)?.properties[pathProperty]
            marks.append(Mark(key: key, nodeID: nodeID, depth: path.map { Path($0).count } ?? -1))
        }
        return marks.sorted { ($0.depth, $1.nodeID) > ($1.depth, $0.nodeID) }
    }

    /// Runs one fold in a savepoint of its own. A fold that throws is undone, its mark with
    /// it, and is said and added to `refused`; nil is what it returns then. A failure of
    /// the machine is not caught.
    private static func foldAlone<Outcome>(_ mark: Mark, refused: inout Set<String>,
                                           _ fold: () throws -> Outcome) throws -> Outcome? {
        do {
            return try DatabaseLayer.shared.withSavepoint(fold)
        } catch let error as any UnrecoverableError {
            throw error
        } catch {
            refused.insert(mark.key)
            Debug.warn("the fold marked \(mark.key) failed and stays marked for the next pass: \(error)")
            return nil
        }
    }

    /// The folder a mark names, with the mark cleared first — before the rebuild, so that a
    /// mark the flush removes always belongs to a change the rebuild can see. Nil where the
    /// folder has been collected since it was marked: then there is nothing to rebuild and
    /// the row was all that was left of it.
    private static func markedFolder(nodeID: ObjectID, clearing key: String) throws -> Folder? {
        let database: DatabaseLayer = DatabaseLayer.shared
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
    ///
    /// In a savepoint, as each fold of the flush is: a rebuild that throws leaves the
    /// mark, and the reader's error, rather than a cleared mark over the old manifest.
    static func flushManifestIfDirty(nodeID: ObjectID) throws {
        let database: DatabaseLayer = DatabaseLayer.shared
        let key = manifestDirtyKey(nodeID)
        guard try database.metadata.select(key: key) != nil else {
            return
        }
        try database.withSavepoint {
            try database.metadata.delete(key: key)
            guard let folder = try database.node.select(nodeID: nodeID).makeNode() as? Folder else {
                return
            }
            try folder.refreshManifest()
            if try folder.isAbandoned() {
                try folder.markManifestDirty()
            }
        }
    }

    /// Recomputes one folder's content root if it is marked, on the way into a direct read
    /// of that port. The folder's own children, not the tree below it: a read that walked
    /// down would be O(tree), which is the cost the marks exist to avoid.
    ///
    /// The mark is cleared, the root folded and the folder above marked when the root
    /// moved in one savepoint, so that no reader sees the mark gone before the mark above
    /// it is written. Between the two, the folder above would hold a stale root with
    /// nothing saying so, and a push comparing roots (B-132) would take it for current and
    /// send nothing for a change the graph has not folded in yet.
    static func flushContentRootIfDirty(nodeID: ObjectID) throws {
        let database: DatabaseLayer = DatabaseLayer.shared
        let key = contentRootDirtyKey(nodeID)
        guard try database.metadata.select(key: key) != nil else {
            return
        }
        try database.withSavepoint {
            try markedFolder(nodeID: nodeID, clearing: key)?.refreshContentRoot()
        }
    }

    /// Refolds one folder's subtree manifest if it is marked, on the way into a direct read
    /// of that port: the folder's own children, as `flushContentRootIfDirty` reads, and for
    /// the same reason; in a savepoint, as that one is.
    static func flushSubtreeManifestIfDirty(nodeID: ObjectID) throws {
        let database: DatabaseLayer = DatabaseLayer.shared
        let key = subtreeManifestDirtyKey(nodeID)
        guard try database.metadata.select(key: key) != nil else {
            return
        }
        try database.withSavepoint {
            try database.metadata.delete(key: key)
            guard let folder = try database.node.select(nodeID: nodeID).makeNode() as? Folder else {
                return
            }
            try folder.refreshSubtreeManifest()
        }
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
            && !(try canBePinned() && isPinned)
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
        guard try canBePinned() else {
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

    /// How many subtree manifests have been folded in this process, pinned the way the
    /// content root's count is: against the depth of the tree above a change of names.
    static let subtreeManifestRebuildCount = SharedCounter()

    /// This folder's children, as a fold reads them. Summaries rather than whole nodes: a
    /// manifest entry is a name and two flags, and decoding every child's properties to
    /// produce that was most of the rebuild cost.
    private func childSummaries() throws -> [NodeChildSummary] {
        try database.node.selectChildSummaries(parentNodeID: try thisNode.requireID())
    }

    private func buildManifest(of children: [NodeChildSummary]) throws -> FolderManifest {
        Self.manifestRebuildCount.increment()
        let pinned   = try pinnedStates(of: children)
        // A subfolder's link, for a walk to know before it descends; a file's is on its
        // metadata, where what reads files looks.
        let links    = try symbolicLinkTargets(of: children.filter { $0.kind == Folder.kind }).targets

        var folderManifestEntries = [FolderManifestEntry]()
        for child in children {
            folderManifestEntries.append(.init(name: try child.requireName(),
                                               isFolder: child.kind == Folder.kind,
                                               isPinned: pinned[child.id] ?? false,
                                               symbolicLinkTarget: links[child.id]))
        }

        return .init(baseFolderPath: try path.string, entries: folderManifestEntries)
    }

    /// The documents this folder's two content roots are the hashes of: one line per child,
    /// carrying what that child's content is. A subfolder contributes its own root, which is
    /// how one hash comes to stand for a whole tree. `FolderContentRoot` states the format
    /// and the order; this supplies the lines.
    ///
    /// `whole` has a line for every child. `pushed` has one for every child a push of the
    /// folder sends (`pushedContentRootOutputPort`): no dot-name, nothing without content,
    /// no product, and a subfolder by its own pushed root and only when that holds
    /// something — what `FolderOnDisk`'s fold of the disk keeps, line for line.
    private func buildContentRootDocuments(of children: [NodeChildSummary]) throws -> (whole: String, pushed: String) {
        Self.contentRootRebuildCount.increment()
        let content            = try contentStates(of: children, folderPort: Self.contentRootOutputPort)
        let pushedFolderRoots  = try contentStates(of: children.filter { $0.kind == Folder.kind },
                                                   folderPort: Self.pushedContentRootOutputPort)
        let (links, modes)     = try symbolicLinkTargets(of: children)

        var lines  = [FolderContentRoot.Line]()
        var pushed = [FolderContentRoot.Line]()
        for child in children {
            let childName = try child.requireName()
            let isPushed  = !childName.hasPrefix(".")
            switch child.kind {
            // A child of a kind the fold reads, with no row for the port its content is on,
            // has had nothing produced on it — the same reading `asNodeValue` gives.
            case StaticFile.kind:
                let fileContent = content[child.id] ?? .notProduced
                let kind: FolderChildKind = links[child.id] == nil ? .file : .link
                // A file's bytes carry its mode on the line, a link its target; a state has
                // neither, and a removed link stays a link: the metadata a removal leaves is
                // the one it was pushed with.
                guard case .hash(let hash) = fileContent else {
                    lines.append((childName, kind, fileContent))
                    continue
                }
                let line: FolderContentRoot.Line = links[child.id].map { (childName, .link, .symbolicLinkTarget($0)) }
                    ?? (childName, .file, .file(hash: hash, mode: modes[child.id] ?? FileMetadata.defaultMode))
                lines.append(line)
                if isPushed {
                    pushed.append(line)
                }

            case Folder.kind:
                // A folder that is a link is what the link holds, whatever the copy of what
                // it names below it holds: that is folded where it is.
                if let target = links[child.id] {
                    lines.append((childName, .link, .symbolicLinkTarget(target)))
                    if isPushed {
                        pushed.append((childName, .link, .symbolicLinkTarget(target)))
                    }
                    continue
                }
                lines.append((childName, .folder, content[child.id] ?? .notProduced))
                // A push makes a folder only on the way to something below it, so one whose
                // pushed root is empty is not on the disk a lock is folded from. A state is
                // kept: a subfolder not folded yet leaves this root saying so.
                let pushedRoot = pushedFolderRoots[child.id] ?? .notProduced
                guard isPushed, pushedRoot != .hash(FolderContentRoot.emptyFolderRoot) else {
                    continue
                }
                pushed.append((childName, .folder, pushedRoot))

            default:
                // Every other kind under a folder is a product, whose content the fold does
                // not reach. `FolderChildContent.notFolded` says why, and saying it here by
                // `kind` rather than by absence from a dictionary means a node kind that
                // becomes a folder's child cannot acquire the answer by accident. A push
                // sends no product, so the pushed fold has no line for one.
                lines.append((childName, .other, .notFolded))
            }
        }

        return (FolderContentRoot.document(of: lines), FolderContentRoot.document(of: pushed))
    }

    /// This folder's children with each subfolder's own subtree manifest, by hash: the
    /// document that stands for everything below this folder by name (B-135).
    ///
    /// Folded from this folder's manifest, which holds every fact about a child the
    /// document does — name, kind, pinned state, a link's target — and is current whenever
    /// this runs: the flush rebuilds manifests before it refolds anything, and a read of
    /// the port rebuilds a manifest still marked. Folding from the children's rows again
    /// would repeat the manifest's four queries on every change of names below, and during
    /// a push that is every file. What the manifest does not hold is one query, by name.
    private func buildSubtreeManifest() throws -> FolderSubtreeManifest {
        Self.subtreeManifestRebuildCount.increment()
        guard case .value(let manifestHash) = try thisNode.readFromOutputPort(Self.folderManifestOutputPort),
              let manifest: FolderManifest = try? TypeRegistry.decodeAndCast(encodedJSON: try manifestHash.resolveAsString()) else {
            throw NodeError.other(message: "the manifest of \(try path) cannot be read to fold its subtree manifest")
        }
        // Only a subfolder carries a subtree manifest, so a folder of files asks for none.
        var subtrees: [String: OutputPort] = [:]
        if manifest.entries.contains(where: \.isFolder) {
            subtrees = try database.node.selectChildPortsByName(parentNodeID: try thisNode.requireID(),
                                                                nameSymbolID: Self.subtreeManifestOutputPort.asSymbolID())
        }

        return FolderSubtreeManifest(entries: try manifest.entries.map { entry in
            var subtree: DataObjectHash?
            if entry.isFolder, case .value(let hash)? = try subtrees[entry.name]?.asNodeValue() {
                subtree = hash
            }
            return FolderSubtreeEntry(name: entry.name, isFolder: entry.isFolder, isPinned: entry.isPinned,
                                      symbolicLinkTarget: entry.symbolicLinkTarget, subtree: subtree)
        })
    }

    /// The content of every child that carries it on a port of its own, in one query per
    /// kind — the shape `pinnedStates` uses and for the same reason.
    ///
    /// A file's bytes are on its output port, and a folder's content root is on its. The
    /// subfolder's root was folded the same way, so putting it in a line is what makes this
    /// folder's root identify its whole subtree rather than only what is directly in it.
    ///
    /// `folderPort` is the root a subfolder is read by: its whole one, or its pushed one.
    private func contentStates(of children: [NodeChildSummary],
                               folderPort: String) throws -> [ObjectID: FolderChildContent] {
        var result: [ObjectID: FolderChildContent] = [:]
        let parentNodeID = try thisNode.requireID()

        for (kind, portName) in [(Folder.kind,     folderPort),
                                 (StaticFile.kind, StaticFile.outputPort)] where Self.has(children, of: kind) {
            let ports = try database.node.selectChildPorts(parentNodeID: parentNodeID,
                                                           nameSymbolID: portName.asSymbolID())
            for child in children where child.kind == kind {
                result[child.id] = try ports[child.id].map { .init(try $0.asNodeValue()) } ?? .notProduced
            }
        }

        return result
    }

    /// The target of every child that is a symbolic link (B-77), in one query per kind: a
    /// file's from its metadata, a folder's from its `symbolicLink` port. Each distinct
    /// document is read once — a folder of thousands of files holds a handful of metadata
    /// documents, one per mode and one per link — and a folder that is not a link holds
    /// the empty value, which is read as none.
    ///
    /// A file's mode comes out of the same documents, for the fold, whose file lines carry
    /// it (B-132): the default for a file whose metadata cannot be read, as every reader of
    /// a mode takes it.
    private func symbolicLinkTargets(of children: [NodeChildSummary]) throws -> (targets: [ObjectID: String],
                                                                                 modes:   [ObjectID: UInt16]) {
        let parentNodeID = try thisNode.requireID()
        var targets: [ObjectID: String] = [:]
        var modes:   [ObjectID: UInt16] = [:]
        for (kind, portName) in [(Folder.kind,     Folder.symbolicLinkOutputPort),
                                 (StaticFile.kind, StaticFile.fileMetadataOutputPort)] where Self.has(children, of: kind) {
            let ports = try database.node.selectChildPorts(parentNodeID: parentNodeID, nameSymbolID: portName.asSymbolID())
            var metadataByDocument: [DataObjectHash: (target: String?, mode: UInt16?)] = [:]
            for child in children where child.kind == kind {
                guard case .value(let hash)? = try ports[child.id]?.asNodeValue(), !hash.isEmpty else {
                    continue
                }
                if metadataByDocument[hash] == nil {
                    let document = try hash.resolveAsString()
                    if kind == Folder.kind {
                        metadataByDocument[hash] = (document, nil)
                    } else {
                        let metadata = FileMetadata.decode(from: document)
                        metadataByDocument[hash] = (metadata?.symbolicLinkTarget, metadata?.mode)
                    }
                }
                let metadata = metadataByDocument[hash]
                if let target = metadata?.target, !target.isEmpty {
                    targets[child.id] = target
                }
                if let mode = metadata?.mode {
                    modes[child.id] = mode
                }
            }
        }
        return (targets, modes)
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
                                 (StaticFile.kind, StaticFile.outputPort)] where Self.has(children, of: kind) {
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

    /// Whether any of `children` is of `kind`: a port the fold reads per kind is read only
    /// for a kind the folder holds, so a folder with no subfolders asks nothing about
    /// subfolders, and a folder with no children — every folder as it is made — asks
    /// nothing at all.
    private static func has(_ children: [NodeChildSummary], of kind: UInt) -> Bool {
        children.contains { $0.kind == kind }
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a node with outputs, however.
    func refreshOutputs() throws {
        try refreshManifest()
        try refreshContentRoot()
        try refreshSubtreeManifest()
    }

    /// The names and pinned state of this folder's children. Nothing is marked above:
    /// what a folder is called and what it holds are this folder's own business, and a
    /// change to them reaches its parent as an ordinary child change if it reaches it at
    /// all.
    func refreshManifest() throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest(of: childSummaries()).toJSON().intern()))
    }

    /// The fold over this folder's children, published as a hash.
    ///
    /// A root that moved is a change to this folder's content as the folder above it sees
    /// it, so it marks that one. Marking rather than recomputing keeps the walk to one
    /// level per round of the flush, and the rounds are bounded by the depth of the tree:
    /// an edit costs one fold per ancestor, never one per folder.
    func refreshContentRoot() throws {
        let documents = try buildContentRootDocuments(of: childSummaries())
        let changed = try thisNode.writeToOutputPort(Self.contentRootOutputPort, value: .value(try documents.whole.intern()))
        let pushedChanged = try thisNode.writeToOutputPort(Self.pushedContentRootOutputPort,
                                                           value: .value(try documents.pushed.intern()))

        if changed || pushedChanged, let parentNodeID = thisNode.parentNodeID {
            try Folder.markContentRootDirty(nodeID: parentNodeID)
        }
    }

    /// The names below this folder, published as a subtree manifest. One that moved marks
    /// the folder above, as a moved root does, so the change reaches the top in one refold
    /// per ancestor; one that did not — an edit to a file's bytes, which marks this folder
    /// like any child change — stops here.
    func refreshSubtreeManifest() throws {
        let changed = try thisNode.writeToOutputPort(
            Self.subtreeManifestOutputPort,
            value: .value(try buildSubtreeManifest().toJSON().intern()))

        if changed, let parentNodeID = thisNode.parentNodeID {
            try Folder.markSubtreeManifestDirty(nodeID: parentNodeID)
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

    /// The id the cache holds for the input file system's root, unread and so unverified:
    /// for a caller that reads the root's row anyway and checks it with `isRoot` in the
    /// same query, instead of paying the select `inputFileSystem` verifies with. Nil when
    /// the cache is empty, which sends that caller to `inputFileSystem`, the path that may
    /// create.
    static var cachedInputFileSystemID: ObjectID? {
        cachedRootID(named: inputFileSystemName)
    }

    /// Whether `nodeRecord` is the root of the file system `name` — the check that makes a
    /// cached id safe to use, for the reasons `root(named:)` gives.
    static func isRoot(_ nodeRecord: NodeRecord, named name: String) -> Bool {
        nodeRecord.kind == Folder.kind && nodeRecord.properties[Folder.pathProperty] == name
    }

    private static func knownRoot(named name: String) -> NodeRecord? {
        guard let cachedID = cachedRootID(named: name),
              let cached = try? DatabaseLayer.shared.node.select(nodeID: cachedID),
              isRoot(cached, named: name) else {
            return nil
        }
        return cached
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
        if let cached = knownRoot(named: name) {
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
