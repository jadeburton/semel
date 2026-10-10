//
//  BuildEngine.swift
//  semel
//

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

public final class BuildEngine {

    /// Nil until `start()` is called. Tests leave this nil and set `DatabaseLayer.shared` directly.
    public static var shared: BuildEngine! = nil

    /// Creates and starts the engine. Must be called once before using `shared`.
    ///
    /// Launch, not construction, is where the database is checked against this Semel: a
    /// graph another version built is reset here, and a database with the wrong schema
    /// never gets as far as processing. Tests construct engines over prepared databases
    /// all the time, so the constructor must not have that side effect.
    public static func start() throws {
        // Beside the object store, absolute, whatever the current directory is: the two
        // refer to each other, and a database named relative to the launch directory
        // silently started an empty graph against the shared store.
        try FileManager.default.createDirectory(at: SemelPaths.root, withIntermediateDirectories: true)
        let engine = try BuildEngine(database: DatabaseLayer(filePath: SemelPaths.database.path),
                                     startProcessingLoop: false)
        shared = engine
        do {
            try engine.reconcileVersionMarkers()
            try FormulaPrelude.refreshAll(database: engine.database)
        } catch {
            FatalErrors.check(error)
            throw error
        }
        engine.startProcessingLoop()
    }

    // MARK: - Constants

    /// How many nodes compute at once: `SEMEL_JOBS`, or the machine's core count (B-114).
    /// A declared limit, not the concurrency runtime's: a node's `process()` runs on a
    /// thread of its own (`compute`), so the cooperative pool has no part in how many
    /// tools run at once — and nothing else on that pool waits behind them.
    public let jobs: Int

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
        try TypeRegistry.register(types: [
            FolderManifest.self,
            FolderSubtreeManifest.self,
            TreeManifest.self,
            ErrorDocument.self,
            OutputFile.self,
            TreeFile.self,
            TreeMerger.self,
            TreeBuilder.self,
            FolderTreeBuilder.self,
            StaticFile.self,
            Folder.self,
            ProjectFinder.self,
            ProjectBuilder.self,
            SettingsLiteral.self,
            ConfigFilter.self,
            ConfigMerger.self,
            FormulaPrelude.self,
        ])
        ProjectDiscovery.register(FormulaFilePlugin())
    }

    var projectFinder: NodeRecord {
        get throws {
            let specNode = GraphSpecNode(typeName: "ProjectFinder", properties: [], inputs: [], outputs: [])
            let (fromNode, _) = try specNode.findOrCreateMatchingNode()
            return fromNode
        }
    }

    /// Convenience for callers that already hold an engine. The roots belong to the graph,
    /// not to the engine — `Folder` owns the lookup.
    public var inputFileSystem: NodeRecord {
        get throws { try Folder.inputFileSystem }
    }

    public var outputFileSystem: NodeRecord {
        get throws { try Folder.outputFileSystem }
    }

    // MARK: - Init

    /// Creates the engine and optionally starts the background processing loop.
    ///
    /// Pass `startProcessingLoop: false` in unit and integration tests to prevent the
    /// background Task from starting — this keeps tests synchronous and avoids races. A
    /// test that wants the loop passes false too, and calls `startProcessingLoop()` once
    /// `shared`, its toolchains and its reporters are installed: the loop's first pass
    /// starts at once, on another thread, and reads all of them.
    /// `jobs` is how many nodes compute at once; the environment's, unless a test says.
    init(database: DatabaseLayer, startProcessingLoop: Bool = true, jobs: Int = Jobs.resolve().count) throws {
        try Self.registerTypes()

        // The tools the installed toolchains declared, located on this machine now. The
        // engine knows none of them by name; a host registers its toolchains first.
        try ToolDiscovery.registerInstalledTools(into: .instance)
        // A toolchain node's notice goes where the engine's own go. Read through `shared`
        // when it is posted, so whichever engine is installed then is the one that says it.
        NodeNotice.reporter = { BuildEngine.notice($0) }
        self.database = database
        self.jobs = max(1, jobs)

        if startProcessingLoop {
            self.startProcessingLoop()
        }
    }

    /// Starts the background processing loop. `start()` calls this after the launch checks;
    /// the initialiser calls it directly unless asked not to.
    func startProcessingLoop() {
        let engine = self
        batchLock.withLock { loopIsRunning = true }

        Task {
            try _ = projectFinder
            try _ = inputFileSystem
            try _ = outputFileSystem

            do {
                try await engine.processLoop()
            } catch {
                // processLoop is not expected to throw; log and surface if it does.
                Debug.warn("processLoop terminated with error: \(error)")
            }
        }
    }

    // MARK: - Process loop

    private func processLoop() async throws {
        while true {

            await workSignal.clear()
            // Busy before the wake-ups are consumed, not after. A waiter returns when it
            // finds the loop idle with no wake-up outstanding, and between consuming them
            // and marking busy both were true of a pass that had not yet run: a waiter
            // landing in that window returned with the settle it asked about still ahead
            // of it — a few instructions wide, and a loaded machine landed in it.
            await idle.markBusy()
            consumeWakeUps()
            if batchLock.withLock({ stopRequested }) {
                // Leave every waiter with a settled answer before going: the stop counted
                // as a wake-up and was consumed just above, so they return.
                await idle.markIdle(settledThrough: wakeUpsConsumed)
                batchLock.withLock { loopIsRunning = false }
                return
            }

            do {
                try await processAllNodes()
            } catch {
                // Surface DB / processing errors instead of swallowing them.
                FatalErrors.check(error)
                Debug.warn("error during processAllNodes: \(error)")
            }

            try cleanUpAllPendingDeletions()

            // If a signal arrived while we were processing, drain again immediately
            if await workSignal.isPending {
                continue
            }

            settleTally.errors = reportIdleTimeErrors()
            reportUnclaimedConfigKeys()
            reportUnnamedProjects(settleHasErrors: settleTally.errors > 0)
            reportSettleSummary()
            // Last of the three: what a settle produced is read against what it broke and
            // against the totals above it, and a list of paths between the failures and
            // the line that counts them would separate the two halves of one report.
            reportArtifactChanges()
            // The cache before the collector: an evicted entry's objects are what a
            // collection right after it gives back.
            let evicted = trimCacheAtIdle()
            // After the reports and before the idle mark: nothing computes, so the only
            // objects being interned are a client's pushes, which the age margin covers.
            collectObjectsIfDue(force: evicted)

            await idle.markIdle(settledThrough: wakeUpsConsumed)
            await workSignal.wait()
        }
    }

    // MARK: - Settling

    private let idle = IdleState()

    /// Whether `startProcessingLoop` ran and `stopProcessingLoop` has not. An engine without
    /// a loop — every test engine — has nothing to settle, so waiting on it returns at once
    /// instead of forever. Under `batchLock`: the loop writes it from the cooperative pool
    /// and a server reads it from any connection's thread.
    private var loopIsRunning = false

    /// Set under `batchLock`; the loop reads it at the top of every pass.
    private var stopRequested = false

    /// Ends the processing loop after its current pass. A test that started a loop must
    /// stop it: a loop left running keeps processing against whichever engine and
    /// database the *next* test installs in the shared globals, and unschedules its nodes
    /// from under it.
    public func stopProcessingLoop() {
        batchLock.withLock { stopRequested = true }
        signalWorkAvailable()
    }

    /// Suspends until the build has settled: the loop is at its wait point and nothing has
    /// asked for a pass since its last drain began. The second half matters because a
    /// push signals through a Task — between the request and its delivery the loop can
    /// be marked idle with no signal pending, and a waiter let through there would report
    /// a build that had not started. Each idle mark carries a generation, so a waiter that
    /// finds a request outstanding waits for the *next* mark rather than the current one.
    ///
    /// What a mark is compared with is the count of wake-ups it settled, carried by the
    /// mark itself, never the loop's count as it stands when the waiter looks (B-139). The
    /// mark is read in the idle actor and the count under a lock, and between the two the
    /// loop can wake, mark itself busy and take every wake-up outstanding: a waiter
    /// comparing with that count found a request answered by a pass that had not yet run,
    /// and returned before the push it was waiting for was folded.
    public func waitUntilIdle() async {
        guard batchLock.withLock({ loopIsRunning }) else {
            return
        }
        var seen = -1
        while true {
            let mark = await idle.awaitIdle(newerThan: seen)
            seen = mark.generation
            if wakeUpsRequested == mark.settledThrough {
                return
            }
        }
    }

    /// `waitUntilIdle` for a synchronous caller such as the REPL, which blocks its thread;
    /// the loop runs on the cooperative pool, so blocking here starves nothing.
    public func waitUntilIdleBlocking() {
        let done = DispatchGroup()
        done.enter()
        Task {
            await self.waitUntilIdle()
            done.leave()
        }
        done.wait()
    }

    private func cleanUpAllPendingDeletions() throws {
        // Clean up all pending deletions, which are not safe to delete while Nodes are being
        // processed. A pass that fails is logged and retried on the next idle — unless the
        // failure is the machine's, which reaches the fatal handler first.
        do {
            while try processPendingDeletions() > 0 {
            }
        } catch {
            FatalErrors.check(error)
            Debug.warn("pending deletions could not be processed: \(error)")
        }
    }

    // MARK: - Unclaimed config keys

    /// Keys in a config file that no `ConfigFilter` selected.
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
        let nodeRecord = try database.node.select(nodeID: fileNodeID)
        guard let staticFile = try nodeRecord.nodeAsAny() as? StaticFile,
              let content = try staticFile.read(),
              case .value(let hash) = content else {
            return []
        }

        let keys = [String: String](plainText: try hash.resolveAsString()).keys

        // Down the wires to every selector the file's text reaches: directly, or through
        // the `ConfigMerger`s that lay it under or over other settings (B-109). Every
        // prelude formula wires a merger, so a walk that stopped at one would see no
        // project's keys at all.
        var prefixes: [String] = []
        var pending: [(producerID: ObjectID, port: String)] = [(fileNodeID, StaticFile.outputPort)]
        var seen: Set<ObjectID> = [fileNodeID]

        while let (producerID, port) = pending.popLast() {
            for wire in try database.wire.select(comingFromNodeID: producerID, fromSymbolID: port.asSymbolID())
            where seen.insert(wire.toNodeID).inserted {
                let consumer = try database.node.select(nodeID: wire.toNodeID)
                switch consumer.kind {
                case ConfigFilter.kind:
                    if let prefix = consumer.properties[ConfigFilter.prefixProperty] {
                        prefixes.append(prefix + ".")
                    }
                case ConfigMerger.kind:
                    pending.append((wire.toNodeID, ConfigMerger.outputPort))
                default:
                    continue
                }
            }
        }

        return keys.filter { key in !prefixes.contains { key.hasPrefix($0) } }.sorted()
    }

    /// The `StaticFile`s whose text reaches `nodeID` as settings: wired in directly, or
    /// through the `ConfigMerger`s between (B-109). The upward half of the walk
    /// `unclaimedConfigKeys` makes downward — a file behind a merger is as much a config
    /// file as one wired straight in, and is the one the report names.
    private func configFileNodeIDs(feeding nodeID: ObjectID) throws -> Set<ObjectID> {
        var files: Set<ObjectID> = []
        var pending = [nodeID]
        var seen: Set<ObjectID> = [nodeID]

        while let consumerID = pending.popLast() {
            for wire in try database.wire.select(goingToNodeID: consumerID) where seen.insert(wire.fromNodeID).inserted {
                switch try database.node.select(nodeID: wire.fromNodeID).kind {
                case StaticFile.kind:
                    files.insert(wire.fromNodeID)
                case ConfigMerger.kind:
                    pending.append(wire.fromNodeID)
                default:
                    continue
                }
            }
        }
        return files
    }

    /// Tracks the last-reported unclaimed-key set per config-file node so an unchanged
    /// result is not printed again on every idle cycle.
    private var lastReportedUnclaimedKeys: [ObjectID: [String]] = [:]

    /// The project files the last report found no formula naming, by path, so a standing
    /// one is said once rather than on every settle (B-10). Read and written on the loop's
    /// task only.
    var lastReportedUnnamedProjects: Set<String> = []

    /// `DataObjectStore.bytesStored` when the collector last ran; nil until it has (B-14).
    /// Read and written on the loop's task only.
    var bytesStoredAtLastCollection: Int?

    /// The last trim that evicted something, for `cache` to say what went (B-148). Not
    /// persisted, as the settle record is not. Written by the loop and by `cache limit`,
    /// read by a server's request.
    @Locked var lastCacheTrim: CacheTrim?

    /// Where `reportUnclaimedConfigKeys` sends its lines. A closure rather than a bare
    /// `print` call so a test can capture what would be printed instead of scraping stdout —
    /// the same shape as `FatalErrors.handler`.
    @Locked var unclaimedConfigKeyReporter: (String) -> Void = { BuildEngine.notice($0) }

    /// Where the idle-time error report goes. Structured entries rather than lines: the
    /// engine renders nothing, and a server carries them to a client as records, which the
    /// client draws. An engine with no server has nobody to tell, so the default is
    /// silence.
    @Locked public var errorReporter: ([ErrorReport.Entry]) -> Void = { _ in }

    /// Where the settle summary goes. Totals rather than a line, for the same reason the
    /// error reporter hands over entries: the marks and the wording belong to whatever
    /// terminal is reading, and pinning them in one renderer is what keeps them from
    /// drifting per command. An engine with no server has the per-batch `Debug.log` line
    /// and needs nothing here, so the default is silence.
    @Locked public var settleReporter: (SettleSummary) -> Void = { _ in }

    /// Where one-line status notices go — an artifact written, a product deleted. Nodes
    /// reach it through `notice(_:)`, because a node has the process-wide engine and
    /// nothing else to hand a line to.
    @Locked public var noticeReporter: (String) -> Void = { print($0) }

    /// The one call a node makes to say something to the user. Falls back to printing when
    /// no engine is installed, which is only the case in tests that build nodes by hand.
    public static func notice(_ line: String) {
        (shared?.noticeReporter ?? { print($0) })(line)
    }

    /// Where one settle's artifact diff goes — what appeared, what changed, what went
    /// away, as paths rather than lines, for the reason the error reporter hands over
    /// entries: the wording and the cap belong to whatever terminal is reading. An engine
    /// with no server has nobody to tell, so the default is silence.
    @Locked public var artifactReporter: (ArtifactChanges) -> Void = { _ in }

    /// Where a settle's progress goes as the pass changes state — after a round of
    /// scheduling starts nodes and after a result is written (B-95). The tally's running
    /// totals rather than a batch's, for the reason the summary carries them. An engine
    /// with no server has nobody waiting at a terminal, so the default is silence.
    @Locked public var progressReporter: (ProgressReport) -> Void = { _ in }

    // MARK: - Artifact change tracking

    /// Guards the two candidate sets below. The write path reaches them from whichever
    /// thread is mutating the graph; the settle report empties them on the loop's task.
    let artifactCandidateLock = NSLock()

    /// Artifacts the write path woke since the last report, and the node that carries
    /// each. Touched, not changed: every consumer of a written port is put back to
    /// pending, so a settle that republished the same bytes lands here too and is
    /// filtered out by the comparison against its snapshot hash.
    ///
    /// The node id travels with the path so the report needs no search: a candidate is
    /// one lookup by primary key, which is what keeps the steady path off O(all
    /// artifacts).
    var touchedArtifacts: [String: ObjectID] = [:]

    /// Artifacts whose node the collector was about to delete since the last report, and
    /// the node it was deleting. Captured as an event because nothing survives to be
    /// compared; the id is what lets the report check that the delete actually happened.
    var collectedArtifacts: [String: ObjectID] = [:]

    /// Whether the whole table has been reconciled against the graph since this engine
    /// was constructed. A restart loses the candidate sets, so the first report of a
    /// launch walks everything once and every report after it is the steady path.
    var artifactsHaveBeenReconciled = false

    /// Records that the write path woke an artifact. Called from
    /// `writePendingToAllOutputsOfNode`, which is every path by which a node's inputs can
    /// come to mean something else: a port write cascading to its consumers, a wire
    /// connected, a wire disconnected.
    func noteArtifactTouched(path: String, nodeID: ObjectID) {
        artifactCandidateLock.withLock { touchedArtifacts[path] = nodeID }
    }

    /// Records that the collector is deleting an artifact's node.
    func noteArtifactCollected(path: String, nodeID: ObjectID) {
        artifactCandidateLock.withLock { collectedArtifacts[path] = nodeID }
    }

    /// Finds every config file feeding a `ConfigFilter` and prints its unclaimed keys, but
    /// only when that file's unclaimed set has changed since the last report — a project
    /// with a standing misspelt prefix would otherwise repeat the same line on every idle
    /// cycle until it read as background noise rather than something to fix.
    ///
    /// Starts from `ConfigFilter` nodes rather than scanning for files named `semel.config`:
    /// a config file is identified by being wired into a selector, not by its name — the same
    /// reason a variant is just a different file wired in, with no naming convention of its
    /// own. `ConfigFilter` nodes are also rare (one per prefix), where `StaticFile` is not —
    /// most nodes in a real project are source files, so filtering all of them by name would
    /// cost about what `selectAll()` does. From each selector the walk goes up through the
    /// `ConfigMerger`s that lay files over one another (B-109), so the project file behind
    /// a prelude's merger is found and named. One consequence of
    /// starting here: a config file with no `ConfigFilter` below it at all is invisible to
    /// this pass, and so is a generated config file that is not a `StaticFile` — only
    /// `StaticFile.read()` is understood as a source of config text.
    ///
    /// Internal rather than private so a test can call it directly and inspect
    /// `unclaimedConfigKeyReporter`'s captures — the same reasoning as
    /// `FileWildcardMatcher`'s internal-for-testing methods.
    func reportUnclaimedConfigKeys() {
        // A report, so best effort: a failure here loses one idle-time warning, nothing more.
        guard let subsets = FatalErrors.attempt({ try database.node.select(kind: ConfigFilter.kind) }) else {
            return
        }

        var fileNodeIDs: Set<ObjectID> = []

        for subset in subsets {

            guard let subsetID = subset.id,
                  let files = FatalErrors.attempt({ try configFileNodeIDs(feeding: subsetID) }) else {
                continue
            }

            fileNodeIDs.formUnion(files)
        }

        // Which files have something to say, and what it is. The path each line names is
        // looked up here rather than for every candidate: a file whose unclaimed set is
        // unchanged or empty prints nothing, and asking the database for its node would
        // be a query per settle for a line nobody sees. The order of this pass reaches
        // nothing — every guard and every record below is that file's own.
        var warnings: [(path: String, nodeID: ObjectID, unclaimed: [String])] = []

        for fileNodeID in fileNodeIDs.sorted() {
            guard let unclaimed = FatalErrors.attempt({ try unclaimedConfigKeys(inFileNodeID: fileNodeID) }) else {
                continue
            }

            guard unclaimed != (lastReportedUnclaimedKeys[fileNodeID] ?? []) else {
                continue
            }

            lastReportedUnclaimedKeys[fileNodeID] = unclaimed

            guard !unclaimed.isEmpty else {
                continue
            }

            warnings.append((path: configFilePath(ofNodeID: fileNodeID), nodeID: fileNodeID, unclaimed: unclaimed))
        }

        // In path order: a Set's iteration order is seeded per process, and a node's id
        // records the order its graph was written — phase 2 applies results as tasks
        // finish — so the path is the only one of the three that reads the same in two
        // builds of the same tree (B-04).
        for warning in warnings.sorted(by: { ($0.path, $0.nodeID) < ($1.path, $1.nodeID) }) {
            unclaimedConfigKeyReporter("⚠️  \(warning.path) contains unused configuration key(s): \(warning.unclaimed.joined(separator: ", "))")
        }
    }

    /// The path recorded on a config file's node, or a stand-in naming the node when the
    /// database cannot hand that node over — this report is best effort, and a line that
    /// names the node is worth more than no line at all.
    private func configFilePath(ofNodeID fileNodeID: ObjectID) -> String {
        let fileNode = FatalErrors.attempt({ try database.node.find(nodeID: fileNodeID) }) ?? nil
        return fileNode?.properties["path"] ?? "config file \(fileNodeID)"
    }

    // MARK: - Idle-time error reporting

    /// Tracks the last set of error documents reported per node so repeated identical
    /// errors are not reported on every processing cycle.
    private var lastReportedErrors: [ObjectID: Set<ErrorDocument>] = [:]

    /// Called once the engine is fully idle (no more scheduled nodes, no pending signals).
    /// Compares current error state against the last-reported state and reports only
    /// newly-appearing errors, through the same fold as the `errors` verb.
    ///
    /// Returns how many errors the graph is carrying, counted the way the `errors` report
    /// counts them — one per cause, merged as the client merges its blocks — so that the
    /// number is what that report would say if it were asked for at this moment.
    /// Deliberately not the size of what is reported now: a build that breaks a node and a
    /// rebuild that breaks it again identically leave the graph equally broken, and a
    /// summary reading "0 errors" two lines above `errors` listing one is the kind of
    /// disagreement the count exists to prevent. What is newly appearing decides what is
    /// *reported*; what is currently wrong decides what is *counted*.
    @discardableResult
    func reportIdleTimeErrors() -> Int {
        // A report, so best effort: a failure here delays the error listing to the next idle.
        guard let errorPorts = FatalErrors.attempt({ try ErrorReport.portsToReport(database: database) }) else {
            return 0
        }

        // What the sources in the graph have to say for themselves, worked out once for the
        // three passes below: it is the one reading here that asks the graph anything
        // beyond the ports in hand.
        let sourced = ErrorReport.sourceDocuments(amongPorts: errorPorts, database: database)

        // What the `errors` verb would answer if it were asked at this moment: the same
        // fold, over everything the graph carries rather than over what is newly appearing.
        // Through `entries` rather than by counting ports, because a carrier folded onto
        // its cause is not an error the verb lists, and a count that included one would say
        // more than the report beside it shows.
        let errorCount = ErrorReport.errorCount(of: ErrorReport.entries(forErrorPorts: errorPorts, database: database,
                                                                        sourceDocuments: sourced) { _, documents in documents })

        // The "current" error map. `ErrorReport` is the one place that decides what a port's
        // document is and which state is not one.
        let current = ErrorReport.documentsByNode(forPorts: errorPorts, database: database,
                                                  sourceDocuments: sourced)

        // Only the causes, and of those only the ones with a newly-appearing document.
        // Reporting an error that has already been reported on every settle is how a report
        // stops being read. `ErrorReport` decides the rest — which nodes are causes, how the
        // cascade under each is counted, and the order — so that this event and the `errors`
        // verb's reply list the same failures alike.
        let entries = ErrorReport.entries(forErrorPorts: errorPorts, database: database,
                                          sourceDocuments: sourced) { nodeID, documents in
            documents.subtracting(lastReportedErrors[nodeID] ?? [])
        }

        // What a node is known to have been reported for, kept document by document: a
        // carrier folded into its cause is reported for nothing, so it keeps nothing, and the
        // day its own cause is collected and it becomes the cause, its document still counts
        // as new.
        var reported: [ObjectID: Set<ErrorDocument>] = [:]
        for (nodeID, documents) in current {
            reported[nodeID] = documents.intersection(lastReportedErrors[nodeID] ?? [])
        }
        for entry in entries {
            for nodeID in entry.nodeIDs {
                reported[nodeID] = current[nodeID]
            }
        }
        lastReportedErrors = reported

        guard !entries.isEmpty else {
            return errorCount
        }

        // Named only once there is something to report: the walk is the one part of a report
        // whose cost follows the graph below the failures rather than the failures.
        var reach = ProductReach(database: database)
        errorReporter(ErrorReport.namingProducts(of: entries, reach: &reach))
        return errorCount
    }

    // MARK: - Settle summary

    /// What one settle has seen so far, kept per node rather than per batch. Its three
    /// sets outlive the totals taken from them: they become the settle record `explain`
    /// reads (B-91).
    ///
    /// A settle takes as many batches as the cascade needs, and one node can be fetched by
    /// several of them: woken, found to be waiting on an input, unscheduled, woken again
    /// when that input arrives. Counting fetches would report that node several times over
    /// under a line that says "nodes", so each container here is keyed on the node.
    private struct SettleTally {

        /// Every node the settle fetched as scheduled, once each.
        var scheduledNodeIDs: Set<ObjectID> = []

        /// Nodes whose most recent result in this settle was one they ran themselves.
        var computedNodeIDs: Set<ObjectID> = []

        /// Nodes whose most recent result in this settle came from a cache entry. Disjoint
        /// from `computedNodeIDs`: a node moves between the two as it produces results, so
        /// a node that ran in one batch and hit in a later one is a hit, and one that hit
        /// a stale entry and had to run is not. A fetch that produced no result at all
        /// leaves both alone, so a node not ready does not undo what it did earlier.
        var fromCacheNodeIDs: Set<ObjectID> = []

        /// Set from the settle-time error report rather than accumulated here.
        var errors = 0

        mutating func noteScheduled(_ nodeIDs: [ObjectID]) {
            scheduledNodeIDs.formUnion(nodeIDs)
        }

        mutating func noteResult(nodeID: ObjectID, fromCache: Bool) {
            computedNodeIDs.remove(nodeID)
            fromCacheNodeIDs.remove(nodeID)
            if fromCache {
                fromCacheNodeIDs.insert(nodeID)
            } else {
                computedNodeIDs.insert(nodeID)
            }
        }

        var summary: SettleSummary {
            SettleSummary(scheduled: scheduledNodeIDs.count,
                          computed:  computedNodeIDs.count,
                          fromCache: fromCacheNodeIDs.count,
                          errors:    errors)
        }
    }

    /// What the settle has seen since the engine last left idle. Written by
    /// `processSomeNodes` and by the settle-time error report, both on the loop's own
    /// task, and read and cleared by `reportSettleSummary` on that same task.
    private var settleTally = SettleTally()

    /// Hands one settle's totals to whoever is reading, and starts the next settle's count.
    ///
    /// A settle that scheduled nothing says nothing: the loop passes through idle on every
    /// signal that turns out to have no work behind it, and a line per pass would be noise
    /// where the interesting case — a build where everything came from the cache — is one
    /// line among it.
    private func reportSettleSummary() {
        let tally   = settleTally
        let summary = tally.summary
        settleTally = SettleTally()

        guard summary.scheduled > 0 else {
            return
        }
        // Before the reporter: a client that reads the summary and asks `explain` at once
        // is asking about the settle the summary describes (B-91).
        settleRecorder.finishSettle(scheduled: tally.scheduledNodeIDs,
                                    computed:  tally.computedNodeIDs,
                                    fromCache: tally.fromCacheNodeIDs)
        settleReporter(summary)
    }

    // MARK: - Settle record

    /// What the settle in progress has woken, and the last settle's record once it is
    /// reported (B-91). The write path reaches it through `BuildEngine.shared`, as it
    /// reaches the artifact candidates.
    let settleRecorder = SettleRecorder()

    /// The last settle that did work, node by node; nil until one has since this engine
    /// started. Not persisted: a restart forgets it, and `explain` says so.
    public var lastSettleRecord: SettleRecord? {
        settleRecorder.last
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
            guard batchDepth == 0, signalPendingInBatch else {
                return false
            }
            signalPendingInBatch = false
            return true
        }
        if shouldSignal {
            sendLoopSignal()
        }
    }

    // MARK: - Signalling

    /// How many signals have been sent to the loop — counted as each is dispatched, which
    /// the loop then receives in order. One batch of any size sends one, however many
    /// mutations asked for a pass inside it, which is what a batch is for and what a test
    /// can hold it to.
    private var loopSignalsSentCount = 0

    var loopSignalsSent: Int {
        batchLock.withLock { loopSignalsSentCount }
    }

    private func sendLoopSignal() {
        batchLock.withLock { loopSignalsSentCount += 1 }
        Task { await workSignal.signal() }
    }

    /// Safe to call from any actor or thread. A signal will never be lost:
    /// if the engine is currently draining, the pending count is incremented
    /// and the next iteration of processLoop will drain again immediately.
    /// When a batch is active, the signal is deferred until `endBatch()`.
    /// How many times something asked for a pass, and how many of those the loop had seen
    /// when its current drain began. Read under `batchLock`: requests come from any thread.
    /// Tests pin which mutations wake the loop — a push has to, since its manifest rebuild
    /// is deferred to the pass — and `waitUntilIdle` uses the pair to tell a settled loop
    /// from one about to wake.
    private var wakeUpsRequestedCount = 0
    private var wakeUpsConsumedCount  = 0

    var wakeUpsRequested: Int {
        batchLock.withLock { wakeUpsRequestedCount }
    }

    /// How many wake-ups the loop had taken when its current pass began, and so how many
    /// the passes before its next idle mark answer.
    private var wakeUpsConsumed: Int {
        batchLock.withLock { wakeUpsConsumedCount }
    }

    private func consumeWakeUps() {
        batchLock.withLock { wakeUpsConsumedCount = wakeUpsRequestedCount }
    }

    func signalWorkAvailable() {
        let inBatch = batchLock.withLock { () -> Bool in
            wakeUpsRequestedCount += 1
            guard batchDepth > 0 else {
                return false
            }
            signalPendingInBatch = true
            return true
        }
        guard !inBatch else {
            return
        }
        sendLoopSignal()
    }

    // MARK: - Processing

    private struct ComputeResult {
        let nodeRecord: NodeRecord
        let output: ComputedOutput
        let keyMaterial: CacheKeyMaterial?
        let computeStart: Date

        var fromCache: Bool {
            if case .cached = output {
                return true
            }
            return false
        }
    }

    /// Runs scheduled nodes until none is scheduled and none is running, in two roles.
    ///
    /// **Computing (concurrent):** up to `jobs` nodes read their inputs and run
    /// `process()` at once, each in a task of its own that hands the work to a thread and
    /// waits for it (B-114). A task mutates nothing in the graph, so tasks sharing
    /// providers are safe together.
    ///
    /// **Writing (this loop, one result at a time):** each result is written as soon as
    /// its task finishes — outputs, wires, cascades — and the slot it frees is filled from
    /// the nodes that write scheduled. All graph mutation stays on this one sequence, and
    /// no node waits for a slower one it merely started beside (B-113). Nor does a node
    /// scheduled from outside while the pass runs — a push, a batch ending — wait for a
    /// result: the pass wakes on the work signal too, and fills a free slot at once
    /// (B-117).
    ///
    /// A node is unscheduled as it starts. A write that changes its inputs while it runs
    /// schedules it again, so it runs once more after its stale result is written, and
    /// the cascade re-evaluates whatever read that result. The cache stays sound
    /// throughout: an entry's key and its output come from the one input a task read.
    private func processAllNodes() async throws {
        try await withThrowingTaskGroup(of: PassEvent.self) { group in
            var running = Set<ObjectID>()
            // The same nodes, named and in start order, for the progress report (B-95).
            var runningDescriptions: [(nodeID: ObjectID, description: ActiveNodeDescription)] = []
            // Signals up to here are this pass's to act on by selecting; the watcher below
            // asks for the next one after them (B-117).
            var seenSignal = await workSignal.generation
            var watching = false

            while true {
                // Before selecting: a rebuilt manifest's port write is what schedules its
                // consumers (B-25), and a write may have added output files to folders.
                try Folder.flushDirtyManifests()

                let free = jobs - running.count
                let started = free > 0 ? try database.node.selectScheduled(limit: free, excluding: running) : []
                settleTally.noteScheduled(started.compactMap(\.id))
                for nodeRecord in started {
                    guard let nodeID = nodeRecord.id else {
                        continue
                    }
                    try nodeRecord.setScheduled(false)
                    // Nothing can run a kind this server does not link. Its error is its
                    // result, written here with the other results (B-130).
                    guard nodeRecord.linkedNodeType != nil else {
                        try nodeRecord.publishUnlinkedKindError()
                        settleTally.noteResult(nodeID: nodeID, fromCache: false)
                        continue
                    }
                    running.insert(nodeID)
                    runningDescriptions.append((nodeID, describeForProgress(nodeRecord)))
                    group.addTask {
                        .computed(await Self.compute(nodeRecord))
                    }
                }
                // Only when something started: a pass that starts nothing says nothing,
                // as the settle summary says nothing for a settle that scheduled nothing.
                if !started.isEmpty {
                    reportProgress(running: runningDescriptions.map(\.description))
                }

                // Nothing running and nothing scheduled: settled.
                if running.isEmpty {
                    break
                }

                // A node scheduled while these run — a push, a batch ending — is picked
                // up as soon as it is, not when one of them finishes: the wait below is
                // for the next result or the next signal, whichever comes first.
                if !watching {
                    group.addTask { [seenSignal, workSignal] in
                        .woken(await workSignal.wait(after: seenSignal))
                    }
                    watching = true
                }

                guard let event = try await group.next() else {
                    break
                }
                switch event {
                case .computed(let nodeRecord, let result):
                    if let nodeID = nodeRecord.id {
                        running.remove(nodeID)
                        runningDescriptions.removeAll { $0.nodeID == nodeID }
                    }
                    // A node not ready — waiting on an input — is unscheduled and written
                    // nothing; the input's arrival schedules it again.
                    if let result {
                        write(result)
                    }
                    // After the write: what it scheduled is in the pending count, and the
                    // tally has the result. The last of a settle has nothing running and
                    // nothing pending, and the summary follows it with the same totals.
                    reportProgress(running: runningDescriptions.map(\.description))
                case .woken(let generation):
                    seenSignal = generation
                    watching = false
                }
            }

            // The watcher, if one is still waiting: the pass is over and the outer loop's
            // own wait takes the signal from here. The signal itself is left pending, so
            // a pass that ended with one outstanding is followed by another at once.
            group.cancelAll()
            while try await group.next() != nil {}
        }
    }

    /// Hands where the settle stands to whoever is reading: the tally's totals, the
    /// scheduled rows still ahead, and the nodes computing now (B-95).
    private func reportProgress(running: [ActiveNodeDescription]) {
        let summary = settleTally.summary
        let pending = FatalErrors.attempt({ try database.node.countScheduled() }) ?? 0
        progressReporter(ProgressReport(scheduled: summary.scheduled,
                                        computed:  summary.computed,
                                        fromCache: summary.fromCache,
                                        pending:   pending,
                                        running:   running))
    }

    /// The type name and the name a report gives the node, taken as it starts: a read or
    /// two per node start, which is one per tool process.
    private func describeForProgress(_ nodeRecord: NodeRecord) -> ActiveNodeDescription {
        let typeName = (try? TypeRegistry.type(kind: nodeRecord.kind)).map { String(describing: $0) }
            ?? "kind \(nodeRecord.kind)"
        return ActiveNodeDescription(typeName: typeName, name: progressName(of: nodeRecord))
    }

    /// The name a report gives the node, else the file on its `input` port. A compiler
    /// has no path of its own, and on a dashboard of ten running compilers the file each
    /// one compiles is the only thing that tells them apart. A wire named anything but a
    /// path — a configuration's `wire0` — names nothing.
    private func progressName(of nodeRecord: NodeRecord) -> String {
        if let path = ErrorReport.path(of: nodeRecord, database: database) {
            return path
        }
        guard let nodeID = nodeRecord.id else {
            return ""
        }
        let wires = FatalErrors.attempt({
            try database.wire.select(goingToNodeID: nodeID, toSymbolID: "input".asSymbolID())
        }) ?? []
        return wires.map { $0.name.resolveSymbol() }
            .filter { $0.hasPrefix(FileSystemName.input) || $0.hasPrefix(FileSystemName.output) }
            .min() ?? ""
    }

    /// What a pass waits on: a node's result, or a signal that something was scheduled.
    private enum PassEvent {
        case computed((NodeRecord, ComputeResult?))
        case woken(Int)
    }

    /// One node's computation, on a thread of its own; the task that asked suspends until
    /// it is done and holds no thread meanwhile.
    ///
    /// A `process()` is synchronous by contract, and a tool node's is a wait on a child
    /// process for as long as it takes. On the cooperative pool — one thread per core,
    /// carrying the loop's signals and every client's wait — that wait held a thread, and
    /// everything else queued behind the compilers. A Dispatch queue is no better a home:
    /// its width is the machine's constrained-thread limit less whatever is already busy,
    /// and it ran eight nodes of ten asked for. A thread per computing node costs a
    /// creation per node, and there are never more than `jobs` of them.
    private static func compute(_ nodeRecord: NodeRecord) async -> (NodeRecord, ComputeResult?) {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                guard let node = try? nodeRecord.makeNode(),
                      type(of: node).descriptor.hasInputs,
                      let result = node.tryComputeOutput() else {
                    return continuation.resume(returning: (nodeRecord, nil))
                }
                continuation.resume(returning: (nodeRecord, ComputeResult(nodeRecord: nodeRecord,
                                                                          output: result.output,
                                                                          keyMaterial: result.keyMaterial,
                                                                          computeStart: result.computeStart)))
            }
            thread.name = "semel.compute"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Writes one computed result to the graph: its outputs, the wires it asked for, and
    /// its cache entry.
    private func write(_ result: ComputeResult) {
        guard let nodeID = result.nodeRecord.id else {
            return
        }
        // A cache hit is a node that was scheduled and did not run, which is the one
        // distinction the summary exists to carry; counting it beside the nodes that ran
        // would make a rebuild of an unchanged graph read as a full build.
        settleTally.noteResult(nodeID: nodeID, fromCache: result.fromCache)
        Debug.log("\(result.fromCache ? "from cache" : "computed"): node \(nodeID)")

        do {
            // Skip a node an earlier write cascade-deleted. makeNode() constructs from the
            // in-memory NodeRecord struct and does not re-query the DB, so this explicit
            // existence check is required.
            guard try database.node.find(nodeID: nodeID) != nil else {
                Debug.warn("node \(nodeID) deleted during processing")
                return
            }

            let node = try result.nodeRecord.makeNode()
            guard type(of: node).descriptor.hasInputs else {
                return
            }

            do {
                switch result.output {
                case .cached(let cached):
                    try node.writeToOutputs(output: cached)
                    node.recordCacheKey(result.keyMaterial)
                case .processed(let processed):
                    let applied = try node.writeToOutputs(output: processed)
                    node.recordCacheKey(result.keyMaterial)
                    // Failing to save a cache entry must not fail a build — unless the
                    // failure is the machine's, which no later node will survive either.
                    do {
                        try node.saveCacheForAllInputsAndOutputs(
                            keyMaterial: result.keyMaterial,
                            processingDuration: Date.now.timeIntervalSince(result.computeStart),
                            output: applied
                        )
                    } catch {
                        FatalErrors.check(error)
                    }
                }
            } catch {
                if result.fromCache {
                    // Cached output is stale — fall back to a full sequential reprocess
                    // using the graph as it stands. The node ran after all, so the
                    // summary must not call it a hit.
                    settleTally.noteResult(nodeID: nodeID, fromCache: false)
                    Debug.warn("writeToOutputs failed for cached output, reprocessing: \(error)")
                    try node.processWithPreCheck()
                } else {
                    throw error
                }
            }
        } catch {
            Debug.warn("error processing node \(nodeID): \(error)")
        }
    }

    func processOneNode(_ nodeRecord: NodeRecord) throws {
        try nodeRecord.setScheduled(false)

        guard nodeRecord.linkedNodeType != nil else {
            try nodeRecord.publishUnlinkedKindError()
            return
        }

        let node = try nodeRecord.makeNode()
        guard type(of: node).descriptor.hasInputs else {
            Debug.warn("attempted to process a node that declares no inputs")
            return
        }

        try node.processWithPreCheck()
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

        for nodeRecord in pendingNodes {

            guard let nodeID = nodeRecord.id else {
                continue
            }

            // Skip if already cascade-deleted by an earlier step in this pass.
            guard try database.node.find(nodeID: nodeID) != nil else {
                continue
            }

            guard nodeRecord.linkedNodeType != nil else {
                if try nodeRecord.deleteUnlinked() {
                    deletedCount += 1
                }
                continue
            }

            guard let node = try? nodeRecord.makeNode() else {
                continue
            }

            // If the node has been re-wired since being marked, clear the flag and skip.
            // The mutations below throw: a mark that cannot be cleared or a row that cannot
            // be deleted is a failed pass, not a skipped node — the caller logs it and the
            // next idle retries, and a machine failure reaches the fatal handler.
            guard (try? node.hasNoOutputWires()) == true else {
                try database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: false)
                continue
            }

            guard (try? node.canBeDeleted()) == true else {
                try database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: false)
                continue
            }

            // Delete each input wire; deleteWire will mark upstream nodes that lose
            // their last consumer, so they'll be caught in the next pass.
            for inputWire in try database.wire.select(goingToNodeID: nodeID) {
                try inputWire.deleteWire(database: database)
            }

            if (try? node.hasNoOutputWires()) == true &&
               (try? node.hasNoInputWires()) == true {
                // Where an artifact disappears. The one event-shaped case of the settle
                // diff: once the node is gone there is no value left to compare against
                // the hash the reader was told, so the collection itself is the record.
                // Said before the delete, because after it there is no record to read the
                // path from; the report checks that the node did go before it says so.
                if nodeRecord.kind == OutputFile.kind, let path = nodeRecord.properties["path"] {
                    noteArtifactCollected(path: path, nodeID: nodeID)
                }
                try node.delete()
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            Debug.log("removed \(deletedCount) node(s)")
        }

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
/// Whether the processing loop is at its wait point, with a generation that advances on
/// every idle mark so a waiter can ask for a mark newer than one it has already judged.
private actor IdleState {

    /// One idle mark: its generation, and how many wake-ups the passes before it answered.
    struct Mark {
        let generation:     Int
        let settledThrough: Int
    }

    private var isIdle = false
    private var generation = 0
    private var settledThrough = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markBusy() {
        isIdle = false
    }

    func markIdle(settledThrough wakeUps: Int) {
        isIdle = true
        generation += 1
        settledThrough = wakeUps
        let resumed = waiters
        waiters = []
        for waiter in resumed {
            waiter.resume()
        }
    }

    /// Returns the current mark once the loop is idle at a generation newer than `seen` —
    /// at once if it already is, otherwise after the next idle mark.
    func awaitIdle(newerThan seen: Int) async -> Mark {
        while !(isIdle && generation > seen) {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return Mark(generation: generation, settledThrough: settledThrough)
    }
}

private actor WorkSignal {

    private var pendingCount: Int = 0
    private var continuation: CheckedContinuation<Void, Never>?
    /// Every signal ever, so a waiter inside a pass can ask for the next one after the
    /// ones it has acted on (B-117); `pendingCount` is the outer loop's, cleared per pass.
    private(set) var generation = 0

    /// Increment the pending count and wake any waiting consumer.
    func signal() {
        pendingCount += 1
        generation += 1
        continuation?.resume()
        continuation = nil
    }

    /// Returns true if at least one signal has arrived since the last `clear()`.
    var isPending: Bool { pendingCount > 0 }

    /// The generation once a signal has taken it past `seen`; at once if one already has.
    /// Leaves at once on cancellation, with nothing left waiting: the one continuation
    /// slot is the outer loop's again the moment the pass ends.
    func wait(after seen: Int) async -> Int {
        if generation > seen {
            return generation
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    cont.resume()
                    return
                }
                self.continuation = cont
            }
        } onCancel: {
            Task { await self.abandonWait() }
        }
        return generation
    }

    private func abandonWait() {
        continuation?.resume()
        continuation = nil
    }

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
