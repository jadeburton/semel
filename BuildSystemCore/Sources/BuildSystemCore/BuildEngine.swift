//
//  BuildEngine.swift
//  build_system
//

import Foundation
import GRDB
import DatabaseModels

public final class BuildEngine {

    public static let shared = try! BuildEngine()

    // MARK: - Constants

    private static let processingBatchSize = 8

    // MARK: - State

    let database: DatabaseLayer
    private let commandInterpreter: CommandInterpreter

    /// A pending-work flag. Incremented by any caller (any actor/thread) via
    /// `signalWorkAvailable()`. Decremented back to zero at the top of every
    /// drain pass. Using an actor-isolated counter means there is no data race
    /// and no signal can be lost: if two signals arrive while we are draining,
    /// the counter reaches 2, and the loop performs a second drain automatically
    /// before sleeping.
    private let workSignal = WorkSignal()

    private static func registerTypes() {
        PolyFactory.register(types: [
            FolderManifest.self,
            OutputFile.self,
            StaticFile.self,
            Folder.self,
            ProjectFinder.self,
            ProjectBuilder.self,
            ClangLinkerTool.self,
            ClangCompilerTool.self,
            ClangPreprocessorTool.self,
            Configuration.self,
            IncludeFinder.self,
            SwiftCompilerTool.self,
            SwiftLinkerTool.self,
            SwiftPackageReaderTool.self,
            SwiftFormulaConverter.self
        ])
    }

    var projectFinder: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "ProjectFinder", args: [], inputs: [], outputs: [])
            let (fromNode, _) = try graphShape.findOrCreateMatchingNode()
            return fromNode
        }
    }

    // BUG: this is extremely slow. TODO cache
    var inputFileSystem: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "Folder", args: [.init(key: "path", value: "inputFileSystem")], inputs: [], outputs: [])
            let (fromNode, _) = try graphShape.findOrCreateMatchingNode()
            return fromNode
        }
    }

    // BUG: this is extremely slow. TODO cache
    var outputFileSystem: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "Folder", args: [.init(key: "path", value: "outputFileSystem")], inputs: [], outputs: [])
            let (fromNode, _) = try graphShape.findOrCreateMatchingNode()
            return fromNode
        }
    }

    // MARK: - Init

    private init(database: DatabaseLayer = try! DatabaseLayer(filePath: "database325.sqlite")) throws {
        Self.registerTypes()

        try DefaultTools.setup(toolExecutorRegistry: .instance)
        self.database = database
        self.commandInterpreter = .init(database: database)

        // Capture the fully-initialised self before starting the task.
        let engine = self

        Task {
            try _ = projectFinder
            try _ = inputFileSystem
            try _ = outputFileSystem

            do {
                try await engine.processLoop()
            } catch {
                // processLoop is not expected to throw; log and surface if it does.
                print("BuildEngine: processLoop terminated with error: \(error)")
            }
        }
    }

    // MARK: - Process loop

    private func processLoop() async throws {
        while true {

            await workSignal.clear()

            do {
                try await processAllNodes()
            } catch {
                // Surface DB / processing errors instead of swallowing them.
                print("BuildEngine: error during processAllNodes: \(error)")
            }

            try cleanUpAllPendingDeletions()

            // If a signal arrived while we were processing, drain again immediately
            if await workSignal.isPending {
                continue
            }

            await workSignal.wait()
        }
    }

    private func cleanUpAllPendingDeletions() throws {
        // Clean up all pending deletions, which are not safe to delete while Nodes are being processed
        while ((try? processPendingDeletions()) ?? 0) > 0 {
        }
    }

    public func receiveUserInput(line: String) -> Bool {
        do {
            try commandInterpreter.handleCommand(line)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Signalling

    /// Safe to call from any actor or thread. A signal will never be lost:
    /// if the engine is currently draining, the pending count is incremented
    /// and the next iteration of processLoop will drain again immediately.
    func signalWorkAvailable() {
        Task { await workSignal.signal() }
    }

    // MARK: - Processing

    private func processAllNodes() async throws {
        while try await processSomeNodes() {}
    }

    /// Fetches a batch of scheduled nodes and processes them **in parallel**.
    ///
    /// All nodes in a batch are independent work items, so they are dispatched
    /// concurrently via a `TaskGroup`. Database access remains safe because
    /// `DatabaseLayer` serialises all reads/writes through a single GRDB
    /// `DatabaseQueue`, and each task runs in its own task context so the
    /// `@TaskLocal` transaction connection is correctly isolated per node.
    ///
    /// Errors are caught per-node and logged so that one failing node does not
    /// cancel the processing of its siblings.
    private func processSomeNodes() async throws -> Bool {
        let rawNodes = try database.node.selectAllScheduled(limit: Self.processingBatchSize)

        guard !rawNodes.isEmpty else {
            return false
        }

        await withTaskGroup(of: Void.self) { group in
            for rawNode in rawNodes {
                group.addTask {
                    do {
                        try self.processOneNode(rawNode)
                    } catch {
                        print("BuildEngine: error processing node \(rawNode.id ?? -1): \(error)")
                    }
                }
            }
            await group.waitForAll()
        }

        return true
    }

    func processOneNode(_ node: Node) throws {
        try node.setScheduled(false)

        guard let nodeFunction = try node.nodeFunction() as? NodeFunction else {
            print("WARNING: attempted to process a non-inputtable Node")
            return
        }

        try nodeFunction.processWithPreCheck()
    }
}

// MARK: - Orphan detection (DEBUG only)

#if DEBUG
extension BuildEngine {

    /// A node is "live" if it is reachable backwards through the wire graph from
    /// one of the three permanent roots: ProjectFinder, inputFileSystem, outputFileSystem.
    /// Any node outside that reachable set is orphaned — it cannot affect any product
    /// and will never be cleaned up by the normal wire-cascade deletion logic.
    ///
    /// Runs once per idle cycle and prints a summary if orphans are found.
    func detectOrphans() throws {
        let allNodes = try database.node.selectAll()
        guard !allNodes.isEmpty else { return }

        // Seed the live set with the three permanent roots.
        var liveIDs = Set<ObjectID>()
        var queue   = [ObjectID]()
        let roots: [Node?] = [try? projectFinder, try? inputFileSystem, try? outputFileSystem]
        for case let root? in roots {
            if let id = root.id, liveIDs.insert(id).inserted { queue.append(id) }
        }

        // Build a parentID map from the snapshot to avoid per-node DB queries in the BFS.
        let parentIDOf: [ObjectID: ObjectID] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { n in
                guard let id = n.id, let pid = n.parentNodeID else { return nil }
                return (id, pid)
            }
        )

        // BFS with two traversal axes:
        //   • Wires backward:   providers are live if a live node consumes their output.
        //   • Child → parent:   a containing folder is live if any of its contents are live.
        while !queue.isEmpty {
            let nodeID = queue.removeFirst()
            for wire in try database.wire.select(goingToNodeID: nodeID) {
                if liveIDs.insert(wire.fromNodeID).inserted {
                    queue.append(wire.fromNodeID)
                }
            }
            if let parentID = parentIDOf[nodeID], liveIDs.insert(parentID).inserted {
                queue.append(parentID)
            }
        }

        let orphans = allNodes.filter { $0.id.map { !liveIDs.contains($0) } ?? false }
        guard !orphans.isEmpty else { return }

        print("⚠️ ORPHAN DETECTION: \(orphans.count) orphaned node(s) (not reachable from any permanent root):")
        for node in orphans {
            let typeName = (try? node.nodeFunction()).map { String(describing: type(of: $0)) } ?? "?"
            let canDelete = try? node.nodeFunction().canBeDeleted()
            print("  • #\(node.id ?? -1) \(typeName)  canDelete=\(canDelete.map(String.init) ?? "?")  searchKey: \(node.searchKey ?? "—")")
        }
    }
}
#endif

// MARK: - WorkSignal

/// An actor that acts as a coalescing, non-lossy signal channel.
///
/// - `signal()` increments a pending counter and resumes any waiting continuation.
/// - `wait()` suspends until the counter is non-zero, then returns.
/// - `clear()` resets the counter to zero (call at the start of each drain pass).
/// - `isPending` returns true if a signal arrived since the last `clear()`.
///
/// Because this is an actor, all mutations are serialised — there is no data race.
private actor WorkSignal {

    private var pendingCount: Int = 0
    private var continuation: CheckedContinuation<Void, Never>?

    /// Increment the pending count and wake any waiting consumer.
    func signal() {
        pendingCount += 1
        continuation?.resume()
        continuation = nil
    }

    /// Returns true if at least one signal has arrived since the last `clear()`.
    var isPending: Bool { pendingCount > 0 }

    /// Reset the pending count to zero. Call at the start of each drain pass.
    func clear() {
        pendingCount = 0
    }

    /// Suspend until at least one signal has been received (non-lossy: if a
    /// signal already arrived before `wait()` is called, returns immediately).
    func wait() async {
        if pendingCount > 0 { return }
        await withCheckedContinuation { cont in
            // If a concurrent signal fires between the check above and here,
            // it will immediately resume the continuation we are about to store.
            self.continuation = cont
        }
    }
}
