//
//  BuildEngine.swift
//  build_system
//

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

public final class BuildEngine {

    /// Nil until `start()` is called. Tests leave this nil and set `DatabaseLayer.shared` directly.
    public static var shared: BuildEngine! = nil

    /// Creates and starts the engine. Must be called once before using `shared`.
    public static func start() throws {
        shared = try BuildEngine(database: DatabaseLayer(filePath: "database352.sqlite"))
    }

    // MARK: - Constants

    private static let processingBatchSize = 16

    // MARK: - State

    let database: DatabaseLayer

    /// A pending-work flag. Incremented by any caller (any actor/thread) via
    /// `signalWorkAvailable()`. Decremented back to zero at the top of every
    /// drain pass. Using an actor-isolated counter means there is no data race
    /// and no signal can be lost: if two signals arrive while we are draining,
    /// the counter reaches 2, and the loop performs a second drain automatically
    /// before sleeping.
    private let workSignal = WorkSignal()

    static func registerTypes() throws {
        try PolyFactory.register(types: [
            FolderManifest.self,
            OutputFile.self,
            StaticFile.self,
            Folder.self,
            ProjectFinder.self,
            ProjectBuilder.self,
            Configuration.self,
            ConfigSubset.self,
        ])
        ProjectDiscovery.register(FormulaFilePlugin())
    }

    var projectFinder: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "ProjectFinder", properties: [], inputs: [], outputs: [])
            let (fromNode, _) = try graphShape.findOrCreateMatchingNode()
            return fromNode
        }
    }

    /// Convenience for callers that already hold an engine. The roots belong to the graph,
    /// not to the engine — `Folder` owns the lookup.
    public var inputFileSystem: Node {
        get throws { try Folder.inputFileSystem }
    }

    public var outputFileSystem: Node {
        get throws { try Folder.outputFileSystem }
    }

    // MARK: - Init

    /// Creates the engine and optionally starts the background processing loop.
    ///
    /// Pass `startProcessingLoop: false` in unit and integration tests to prevent the
    /// background Task from starting — this keeps tests synchronous and avoids races.
    init(database: DatabaseLayer, startProcessingLoop: Bool = true) throws {
        try Self.registerTypes()

        try DefaultTools.setup(toolExecutorRegistry: .instance)
        self.database = database

        guard startProcessingLoop else { return }

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
                FatalErrors.check(error)
                print("BuildEngine: error during processAllNodes: \(error)")
            }

            try cleanUpAllPendingDeletions()

            // If a signal arrived while we were processing, drain again immediately
            if await workSignal.isPending {
                continue
            }

            reportIdleTimeErrors()
            reportUnclaimedConfigKeys()

            await workSignal.wait()
        }
    }

    private func cleanUpAllPendingDeletions() throws {
        // Clean up all pending deletions, which are not safe to delete while Nodes are being processed
        while ((try? processPendingDeletions()) ?? 0) > 0 {
        }
    }

    // MARK: - Unclaimed config keys

    /// Keys in a config file that no `ConfigSubset` selected.
    ///
    /// A selector knows only what it was asked for, so it cannot notice a key nobody wanted.
    /// The graph can: the wires leaving a config file lead to every node that claimed part of
    /// it, and their prefixes are properties. Answerable only once the graph has settled, which
    /// is why this is called from the idle hook rather than at parse time.
    ///
    /// This reports a key only when it falls under no selected prefix at all — a misspelt
    /// prefix. A misspelt key *under* a correct prefix (`swift.compiler.sdkVerison` when
    /// `swift.compiler` IS selected) is invisible to this check: telling it apart from a real
    /// key would require knowing which keys each tool actually reads, the per-type key list
    /// this design deleted.
    func unclaimedConfigKeys(inFileNodeID fileNodeID: ObjectID) throws -> [String] {
        let node = try database.node.select(nodeID: fileNodeID)
        guard let staticFile = try node.nodeAsAny() as? StaticFile,
              let content = try staticFile.read(),
              case .value(let hash) = content else { return [] }

        let keys = [String: String](plainText: try hash.resolveAsString()).keys

        var prefixes: [String] = []
        for wire in try database.wire.select(comingFromNodeID: fileNodeID,
                                             fromSymbolID: StaticFile.outputPort.asSymbolID()) {
            let consumer = try database.node.select(nodeID: wire.toNodeID)
            guard consumer.kind == ConfigSubset.kind,
                  let prefix = consumer.properties[ConfigSubset.prefixProperty] else { continue }
            prefixes.append(prefix + ".")
        }

        return keys.filter { key in !prefixes.contains { key.hasPrefix($0) } }.sorted()
    }

    /// Tracks the last-reported unclaimed-key set per config-file node so an unchanged
    /// result is not printed again on every idle cycle.
    private var lastReportedUnclaimedKeys: [ObjectID: [String]] = [:]

    /// Where `reportUnclaimedConfigKeys` sends its lines. A closure rather than a bare
    /// `print` call so a test can capture what would be printed instead of scraping stdout —
    /// the same shape as `FatalErrors.handler`.
    var unclaimedConfigKeyReporter: (String) -> Void = { print($0) }

    /// Finds every config file feeding a `ConfigSubset` and prints its unclaimed keys, but
    /// only when that file's unclaimed set has changed since the last report — a project
    /// with a standing misspelt prefix would otherwise repeat the same line on every idle
    /// cycle until it read as background noise rather than something to fix.
    ///
    /// Starts from `ConfigSubset` nodes rather than scanning for files named `semel.config`:
    /// a config file is identified by being wired into a selector, not by its name — the same
    /// reason a variant is just a different file wired in, with no naming convention of its
    /// own. `ConfigSubset` nodes are also rare (one per prefix), where `StaticFile` is not —
    /// most nodes in a real project are source files, so filtering all of them by name would
    /// cost about what `selectAll()` does. One consequence of starting here: a config file
    /// with no `ConfigSubset` wired to it at all is invisible to this pass, and so is a
    /// generated config file that is not a `StaticFile` — only `StaticFile.read()` is
    /// understood as a source of config text.
    ///
    /// Internal rather than private so a test can call it directly and inspect
    /// `unclaimedConfigKeyReporter`'s captures — the same reasoning as
    /// `FileWildcardMatcher`'s internal-for-testing methods.
    func reportUnclaimedConfigKeys() {
        guard let subsets = try? database.node.select(kind: ConfigSubset.kind) else { return }

        var fileNodeIDs: Set<ObjectID> = []
        for subset in subsets {
            guard let subsetID = subset.id,
                  let wires = try? database.wire.select(goingToNodeID: subsetID,
                                                        toSymbolID: ConfigSubset.inputPort.asSymbolID())
            else { continue }
            fileNodeIDs.formUnion(wires.map(\.fromNodeID))
        }

        for fileNodeID in fileNodeIDs {
            guard let unclaimed = try? unclaimedConfigKeys(inFileNodeID: fileNodeID) else { continue }
            guard unclaimed != (lastReportedUnclaimedKeys[fileNodeID] ?? []) else { continue }
            lastReportedUnclaimedKeys[fileNodeID] = unclaimed

            guard !unclaimed.isEmpty else { continue }
            let path = (try? database.node.select(nodeID: fileNodeID))?.properties["path"] ?? "config file \(fileNodeID)"
            unclaimedConfigKeyReporter("⚠️  \(path): key(s) no selector claims: \(unclaimed.joined(separator: ", "))")
        }
    }

    // MARK: - Idle-time error reporting

    /// Tracks the last set of error messages reported per node so repeated identical
    /// errors are not printed on every processing cycle.
    private var lastReportedErrors: [ObjectID: Set<String>] = [:]

    /// Called once the engine is fully idle (no more scheduled nodes, no pending signals).
    /// Compares current error state against the last-reported state and prints only
    /// newly-appearing errors, using the same format as the `errors` command.
    private func reportIdleTimeErrors() {
        guard let errorPorts = try? database.outputPort.selectAllErrors() else { return }

        let byNode = Dictionary(grouping: errorPorts, by: \.nodeID)

        // Build the new "current" error map, filtering out transient "initializing" noise.
        var current: [ObjectID: Set<String>] = [:]
        for (nodeID, ports) in byNode {
            let msgs = Set(ports.compactMap { port -> String? in
                let msg = (try? port.dataObjectHash?.resolveAsString()) ?? ""
                return msg.isEmpty || msg == "initializing" ? nil : msg
            })
            if !msgs.isEmpty { current[nodeID] = msgs }
        }

        // Print only nodes with at least one newly-appearing error message.
        for (nodeID, msgs) in current {
            let newMsgs = msgs.subtracting(lastReportedErrors[nodeID] ?? [])
            guard !newMsgs.isEmpty else { continue }

            let node = try? database.node.select(nodeID: nodeID)
            let kindLabel: String
            if let node, let nf = try? node.nodeAsAny() {
                let typeName = String(describing: type(of: nf))
                if let path = node.properties["path"] {
                    kindLabel = "\(typeName)  '\(path)'"
                } else if let wires = try? database.wire.select(goingToNodeID: nodeID,
                                                                 toSymbolID: "projectFile".asSymbolID()),
                          let wireName = wires.first?.name {
                    kindLabel = "\(typeName)  '\(wireName.resolveSymbol())'"
                } else {
                    kindLabel = typeName
                }
            } else {
                kindLabel = "Node \(nodeID)"
            }

            print("❌ \(kindLabel)")

            let portsForNode = byNode[nodeID] ?? []
            for msg in newMsgs.sorted() {
                let portsForMsg = portsForNode.filter {
                    ((try? $0.dataObjectHash?.resolveAsString()) ?? "") == msg
                }
                let portNames = portsForMsg
                    .map { $0.nameSymbolID.resolveSymbol() }
                    .sorted()
                    .joined(separator: ", ")

                let lines = msg
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                    .map    { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                if lines.count == 1 {
                    print("   · \(portNames): \(lines[0])")
                } else {
                    print("   · \(portNames):")
                    lines.forEach { print("     \($0)") }
                }
            }
            print("")
        }

        lastReportedErrors = current
    }

    // MARK: - Batch mode

    /// Guards `batchDepth` and `signalPendingInBatch` from concurrent access.
    private let batchLock = NSLock()
    private var batchDepth = 0
    private var signalPendingInBatch = false

    /// Suppress work signals for the duration of a batch write (e.g. a multi-file push).
    /// Nest calls freely; the engine is unblocked only when the outermost `endBatch()` runs.
    public func beginBatch() {
        batchLock.withLock { batchDepth += 1 }
    }

    /// End a batch. Sends a single coalesced signal if any were suppressed inside.
    public func endBatch() {
        let shouldSignal = batchLock.withLock { () -> Bool in
            batchDepth -= 1
            guard batchDepth == 0, signalPendingInBatch else { return false }
            signalPendingInBatch = false
            return true
        }
        if shouldSignal {
            Task { await workSignal.signal() }
        }
    }

    // MARK: - Signalling

    /// Safe to call from any actor or thread. A signal will never be lost:
    /// if the engine is currently draining, the pending count is incremented
    /// and the next iteration of processLoop will drain again immediately.
    /// When a batch is active, the signal is deferred until `endBatch()`.
    func signalWorkAvailable() {
        let inBatch = batchLock.withLock { () -> Bool in
            guard batchDepth > 0 else { return false }
            signalPendingInBatch = true
            return true
        }
        guard !inBatch else { return }
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
        guard !rawNodes.isEmpty else {
            return false
        }

        // Phase 1: read inputs and compute outputs concurrently.
        // Only DB reads and CPU work happen here — no graph mutations, no cascades.
        let computedResults: [BatchComputeResult] = await withTaskGroup(of: BatchComputeResult?.self) { group in

            for rawNode in rawNodes {
                group.addTask {

                    guard let nodeFunction = try? rawNode.nodeFunction(),
                          type(of: nodeFunction).descriptor.hasInputs else {
                        return nil
                    }

                    guard let result = nodeFunction.tryComputeOutput() else {
                        return nil
                    }

                    return BatchComputeResult(node: rawNode,
                                              output: result.output,
                                              cacheKey: result.cacheKey,
                                              computeStart: result.computeStart,
                                              fromCache: result.fromCache)
                }
            }

            var results: [BatchComputeResult] = []

            for await result in group {
                if let result {
                    results.append(result)
                }
            }

            return results
        }

        // Unschedule every fetched node BEFORE any writes so that cascade
        // reschedules (setScheduled(true)) from phase-2 writes are not clobbered
        // by a later unschedule in the loop below.
        for rawNode in rawNodes {
            try rawNode.setScheduled(false)
        }

        // Phase 2: apply outputs sequentially (all graph mutations happen here).
        //
        // If no node was ready (all returned nil from tryComputeOutput), unschedule
        // the batch and report no work done so the caller re-enters wait() and
        // stays reactive to future signals from push commands or cascades.
        guard !computedResults.isEmpty else {
            return false
        }

        for result in computedResults {
            do {
                // Skip nodes that were cascade-deleted by an earlier phase-2 step.
                // nodeFunction() constructs from the in-memory Node struct and does not
                // re-query the DB, so this explicit existence check is required.
                guard let nodeID = result.node.id, (try? database.node.select(nodeID: nodeID)) != nil else {
                    print("WARNING: node \(try result.node.requireID()) deleted during processing")
                    continue
                }

                let nodeFunction = try result.node.nodeFunction()
                guard type(of: nodeFunction).descriptor.hasInputs else {
                    continue
                }

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

        let nodeFunction = try node.nodeFunction()
        guard type(of: nodeFunction).descriptor.hasInputs else {
            print("WARNING: attempted to process a Node that declares no inputs")
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

        guard !pendingNodes.isEmpty else {
            return 0
        }

        var deletedCount = 0

        for node in pendingNodes {

            guard let nodeID = node.id else {
                continue
            }

            // Skip if already cascade-deleted by an earlier step in this pass.
            guard (try? database.node.select(nodeID: nodeID)) != nil else {
                continue
            }

            guard let nodeFunction = try? node.nodeFunction() else {
                continue
            }

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
            print("Removed \(deletedCount) node(s)")
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
