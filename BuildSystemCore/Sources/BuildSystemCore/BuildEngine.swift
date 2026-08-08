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

    private init(database: DatabaseLayer = try! DatabaseLayer(filePath: "database332.sqlite")) throws {
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

    private struct BatchComputeResult {
        let node: Node
        let output: ProcessOutput
        let cacheKey: String?
        let computeStart: Date
        let fromCache: Bool
    }

    /// Fetches a batch of scheduled nodes and processes them in two phases.
    ///
    /// **Phase 1 (concurrent):** Each node reads its inputs and runs `process()`
    /// in parallel.  No graph mutations occur, so concurrent execution is safe
    /// regardless of shared upstream connections.
    ///
    /// **Phase 2 (sequential):** Computed outputs are written to the graph one
    /// at a time.  All wire writes and cascade deletions happen here — serialised,
    /// so no wire-deletion races can occur.
    ///
    /// Nodes in the same batch that share providers compute from a consistent
    /// snapshot of the graph (the state at the start of phase 1).  If a stale
    /// result is written in phase 2, the normal cascade mechanism reschedules any
    /// affected consumers for re-evaluation on the next pass.
    private func processSomeNodes() async throws -> Bool {
        let rawNodes = try database.node.selectAllScheduled(limit: Self.processingBatchSize)
        guard !rawNodes.isEmpty else { return false }

        // Phase 1: read inputs and compute outputs concurrently.
        // Only DB reads and CPU work happen here — no graph mutations, no cascades.
        let computedResults: [BatchComputeResult] = await withTaskGroup(of: BatchComputeResult?.self) { group in
            for rawNode in rawNodes {
                group.addTask {
                    guard let nodeFunction = try? rawNode.nodeFunction() as? NodeFunction else { return nil }
                    guard let result = nodeFunction.tryComputeOutput() else { return nil }
                    return BatchComputeResult(node: rawNode,
                                              output: result.output,
                                              cacheKey: result.cacheKey,
                                              computeStart: result.computeStart,
                                              fromCache: result.fromCache)
                }
            }
            var results: [BatchComputeResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        // Phase 2: apply outputs sequentially (all graph mutations happen here).
        //
        // If no node was ready (all returned nil from tryComputeOutput), unschedule
        // the batch and report no work done so the caller re-enters wait() and
        // stays reactive to future signals from push commands or cascades.
        guard !computedResults.isEmpty else {
            for rawNode in rawNodes { try? rawNode.setScheduled(false) }
            return false
        }

        // Unschedule every fetched node BEFORE any writes so that cascade
        // reschedules (setScheduled(true)) from phase-2 writes are not clobbered
        // by a later unschedule in the loop below.
        for rawNode in rawNodes {
            try? rawNode.setScheduled(false)
        }

        for result in computedResults {
            do {
                // Skip nodes that were cascade-deleted by an earlier phase-2 step.
                // nodeFunction() constructs from the in-memory Node struct and does not
                // re-query the DB, so this explicit existence check is required.
                guard let nodeID = result.node.id,
                      (try? database.node.select(nodeID: nodeID)) != nil else { continue }
                guard let nodeFunction = try result.node.nodeFunction() as? NodeFunction else { continue }

                do {
                    try nodeFunction.writeToOutputs(output: result.output)
                    if !result.fromCache {
                        try? nodeFunction.saveCacheForAllInputsAndOutputs(
                            cacheKey: result.cacheKey,
                            processingDuration: Date.now.timeIntervalSince(result.computeStart),
                            output: result.output
                        )
                    }
                } catch {
                    if result.fromCache {
                        // Cached output is stale — fall back to a full sequential reprocess
                        // using the current (post-phase-2) graph state.
                        print("WARNING: writeToOutputs failed for cached output, reprocessing: \(error)")
                        try nodeFunction.processWithPreCheck()
                    } else {
                        throw error
                    }
                }
            } catch {
                print("BuildEngine: error processing node \(result.node.id ?? -1): \(error)")
            }
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

// MARK: - Deferred deletion

extension BuildEngine {

    /// Processes all nodes marked `pendingDeletion = true`.
    ///
    /// Called at idle time (between drain passes) when no concurrent processing is
    /// running, so structural graph mutations are safe.  Each pass may mark upstream
    /// nodes for deletion (via `deleteWire`), so the caller loops until this returns 0.
    ///
    /// This replaces the old brute-force BFS over all nodes: only the explicitly
    /// marked set is visited, giving O(pending deletions) work instead of O(all nodes).
    @discardableResult
    func processPendingDeletions() throws -> Int {
        let pendingNodes = try database.node.selectAllPendingDeletion()
        guard !pendingNodes.isEmpty else { return 0 }

        var deletedCount = 0

        for node in pendingNodes {
            guard let nodeID = node.id else { continue }

            // Skip if already cascade-deleted by an earlier step in this pass.
            guard (try? database.node.select(nodeID: nodeID)) != nil else { continue }
            guard let nodeFunction = try? node.nodeFunction() else { continue }

            // If the node has been re-wired since being marked, clear the flag and skip.
            guard (try? nodeFunction.hasNoOutputWires()) == true else {
                try? database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: false)
                continue
            }
            guard (try? nodeFunction.canBeDeleted()) == true else {
                try? database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: false)
                continue
            }

            // Delete each input wire; deleteWire will mark upstream nodes that lose
            // their last consumer, so they'll be caught in the next pass.
            for inputWire in (try? database.wire.select(goingToNodeID: nodeID)) ?? [] {
                try? inputWire.deleteWire(database: database)
            }

            if (try? nodeFunction.hasNoOutputWires()) == true &&
               (try? nodeFunction.hasNoInputWires()) == true {
                try? nodeFunction.delete()
                deletedCount += 1
            }
        }

        #if DEBUG
        if deletedCount > 0 {
            print("Pending deletion: removed \(deletedCount) node(s)")
        }
        #endif

        return deletedCount
    }
}

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
