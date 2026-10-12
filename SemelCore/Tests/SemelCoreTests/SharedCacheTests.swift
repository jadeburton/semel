//
//  SharedCacheTests.swift
//  SemelCore
//
//  B-153, phase 3. The engine as a shared cache's client, behind the two hooks: a local miss
//  asks the shared cache and takes its entry with every object fetched and verified, and a
//  local write is queued for it on a thread of its own. Every failure on the way to a hit is
//  a miss and is counted; a queue whose server is stalled never holds up a settle, and a
//  full one drops its oldest. Two machines are two databases and two object stores in this
//  process, with one shared cache between them: a `CacheStore` and an object store behind
//  the `RemoteCache` protocol, which fails at whichever step a test says.
//

@testable import SemelCore
import Foundation
import SemelCache
import SemelDatabaseModels
import SemelNodeKit
import XCTest

// MARK: - A shared cache in this process

/// A shared cache with no socket: the entries in a `CacheStore` over an index in memory, the
/// objects in an object store of its own. Each step of the protocol can be made to fail, to
/// answer wrongly, or to wait until it is let go.
final class InProcessRemoteCache: RemoteCache {

    enum Step: Hashable {
        case connect
        case getEntry
        case hasObjects
        case getObject
        case putObject
        case putEntry
    }

    let address = "in-process"
    let objects: DataObjectStore
    private let index: CacheIndexDatabase
    private let rows: SQLiteCacheStore
    private let lock = NSLock()

    private var failures: [Step: RemoteCacheError] = [:]
    private var calls: [Step] = []
    private var access = RemoteCacheAccess.readWrite
    private var corruptsObjects = false
    private var claimsEveryObject = false
    private var stalledWrites: DispatchSemaphore?
    private var stopsAfterCalls: Int?

    init(objectRoot: URL) throws {
        objects = DataObjectStore(storeRoot: objectRoot)
        index   = try CacheIndexDatabase()
        rows    = SQLiteCacheStore(database: index)
    }

    // MARK: What a test sets

    func fail(_ step: Step, with error: RemoteCacheError) {
        lock.withLock { failures[step] = error }
    }

    func unfail(_ step: Step) {
        lock.withLock { failures[step] = nil }
    }

    /// Answers again after `stop(afterCalls:)`.
    func restart() {
        lock.withLock { stopsAfterCalls = nil }
    }

    func grant(_ granted: RemoteCacheAccess) {
        lock.withLock { access = granted }
    }

    /// Every object fetched arrives with its last byte changed.
    func corruptObjects() {
        lock.withLock { corruptsObjects = true }
    }

    /// `hasObjects` answers that nothing is missing, and `getObject` then has nothing: an
    /// object evicted between the two.
    func loseObjectsAfterAnsweringForThem() {
        lock.withLock { claimsEveryObject = true }
    }

    /// Every put waits until `releaseWrites`.
    func stallWrites() {
        lock.withLock { stalledWrites = DispatchSemaphore(value: 0) }
    }

    func releaseWrites() {
        let stalled = lock.withLock { () -> DispatchSemaphore? in
            defer { stalledWrites = nil }
            return stalledWrites
        }
        for _ in 0..<1_000 {
            stalled?.signal()
        }
    }

    /// After `count` more calls every call fails as a stopped server's would.
    func stop(afterCalls count: Int) {
        lock.withLock { stopsAfterCalls = calls.count + count }
    }

    var recordedCalls: [Step] {
        lock.withLock { calls }
    }

    /// Files bytes under a key as a client could, whatever they are.
    func file(content: Data, underKey key: CacheKey, cost: Int = 1, objects held: [CachedObject] = []) throws {
        try rows.save(hash: key.hash, nodeType: "", cost: cost, content: content, objects: held)
    }

    func entryCount() throws -> Int {
        try rows.count()
    }

    private func enter(_ step: Step) throws {
        let (failure, stalled) = try lock.withLock { () throws -> (RemoteCacheError?, DispatchSemaphore?) in
            calls.append(step)
            if let stopsAfterCalls, calls.count > stopsAfterCalls {
                throw RemoteCacheError.connectionLost(reason: "the server stopped")
            }
            let isWrite = step == .putObject || step == .putEntry
            return (failures[step], isWrite ? stalledWrites : nil)
        }
        stalled?.wait()
        if let failure {
            throw failure
        }
    }

    // MARK: RemoteCache

    func connect(identity: String?) throws -> RemoteCacheAccess {
        try enter(.connect)
        return lock.withLock { access }
    }

    func disconnect() {}

    func entry(forKey key: CacheKey) throws -> RemoteEntry? {
        try enter(.getEntry)
        guard let content = try rows.content(hash: key.hash) else {
            return nil
        }
        let cost = try rows.sizes().first { $0.hash == key.hash }?.cost ?? 0
        let held = try rows.objects(ofEntry: key.hash).map { CachedObject(hash: $0, bytes: objects.size(hash: $0) ?? 0) }
        return RemoteEntry(content: content, cost: cost, objects: held)
    }

    func missingObjects(among hashes: [DataObjectHash]) throws -> [DataObjectHash] {
        try enter(.hasObjects)
        guard !lock.withLock({ claimsEveryObject }) else {
            return []
        }
        return hashes.filter { !$0.isEmpty && !objects.exists(hash: $0) }
    }

    func object(hash: DataObjectHash, expectedBytes: Int) throws -> Data? {
        try enter(.getObject)
        guard !lock.withLock({ claimsEveryObject }), let bytes = try objects.read(hash: hash) else {
            return nil
        }
        var data = Data(bytes)
        if lock.withLock({ corruptsObjects }), let last = data.indices.last {
            data[last] ^= 0xFF
        }
        return data
    }

    func putObject(hash: DataObjectHash, bytes: Data) throws {
        try enter(.putObject)
        try objects.store(hash: hash, content: [UInt8](bytes))
    }

    func putEntry(key: CacheKey, cost: Int, objects named: [DataObjectHash], content: Data) throws {
        try enter(.putEntry)
        let held = named.map { CachedObject(hash: $0, bytes: objects.size(hash: $0) ?? 0) }
        try rows.save(hash: key.hash, nodeType: "", cost: cost, content: content, objects: held)
    }
}

// MARK: - The hooks

final class SharedCacheTests: SemelCoreTestCase {

    /// One machine: its graph, its object store, and its client of the shared cache.
    private struct Machine {
        let engine: BuildEngine
        let store: DataObjectStore
        let sharedCache: SharedCache
    }

    private var remote: InProcessRemoteCache!
    private var machines: [Machine] = []
    private var folders: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        remote = try InProcessRemoteCache(objectRoot: try temporaryFolder("remote"))
    }

    override func tearDown() {
        remote?.releaseWrites()
        for machine in machines {
            machine.engine.useSharedCache(nil)
        }
        machines = []
        remote = nil
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
        super.tearDown()
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("semel-shared-cache-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A machine of its own, made the current one: its engine is `BuildEngine.shared` and its
    /// store `DataObjectStore.shared`, as in a server.
    @discardableResult
    private func machine(capacity: PopulationQueue.Capacity = .standard, connected: Bool = true) throws -> Machine {
        let store = DataObjectStore(storeRoot: try temporaryFolder("objects"))
        DataObjectStore.shared = store
        let engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        let sharedCache = SharedCache(remote: remote, identity: "test", objectStore: store, capacity: capacity)
        engine.useSharedCache(sharedCache)
        let made = Machine(engine: engine, store: store, sharedCache: sharedCache)
        machines.append(made)
        if connected {
            try waitUntil("the shared cache connects") {
                if case .connected = sharedCache.state {
                    return true
                }
                return false
            }
        }
        return made
    }

    private func use(_ machine: Machine) {
        DataObjectStore.shared = machine.store
        BuildEngine.shared     = machine.engine
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while try !condition() {
            guard Date() < deadline else {
                XCTFail("\(what): not within \(Int(timeout)) s")
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func sampleTool() throws -> SampleTool {
        let (node, _) = try GraphSpecNode(SampleTool.self).findOrCreateMatchingNode()
        return try SampleTool(thisNode: node)
    }

    private func input() throws -> ProcessInput {
        ProcessInput(inputValues: [SampleTool.configuration: ["configuration": .value(try "optimise=1".intern())],
                                   SampleTool.input: [:]])
    }

    /// The output a build of the sample tool leaves: an object of `text`.
    private func output(_ text: String) throws -> AppliedOutput {
        AppliedOutput(outputValues: [SampleTool.output:   .value(try text.intern()),
                                     SampleTool.errorLog: .value(""),
                                     SampleTool.infoLog:  .value("")],
                      specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]))
    }

    /// A build on the current machine, written to its cache and queued for the shared one.
    /// Its key.
    @discardableResult
    private func build(_ text: String, cost: TimeInterval = 0.5) throws -> String {
        let tool = try sampleTool()
        let material = try tool.buildCacheKeyMaterial(input: try input())
        try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: cost, output: try output(text))
        return try material.cacheKey()
    }

    /// The current machine's lookup of the sample tool's key.
    private func lookUp() throws -> AppliedOutput? {
        let tool = try sampleTool()
        return try tool.loadCachedOutputs(cacheKey: try tool.buildCacheKeyMaterial(input: try input()).cacheKey())
    }

    /// Machine A builds and its queue writes the entry to the shared cache.
    private func populatedByA(_ text: String = "an object file", cost: TimeInterval = 0.5) throws -> String {
        let machineA = try machine()
        let key = try build(text, cost: cost)
        try waitUntil("A's entry reaches the shared cache") { machineA.sharedCache.figures().entriesSent == 1 }
        return key
    }

    // MARK: - The lookup

    func test_aColdMachineTakesTheEntryAndItsObjectsFromTheSharedCache() throws {
        let key = try populatedByA()
        let machineB = try machine()

        let applied = try XCTUnwrap(try lookUp(), "a local miss the shared cache answers is a hit")

        let produced = try XCTUnwrap(applied.outputValues[SampleTool.output])
        guard case .value(let hash) = produced else {
            return XCTFail("the output is a value, got \(produced)")
        }
        XCTAssertEqual(try hash.resolveAsString(), "an object file", "the object is in B's own store, verified")
        XCTAssertNotNil(try machineB.engine.database.cacheEntry.entry(forKey: key), "the entry is B's now")
        XCTAssertEqual(try machineB.engine.database.cacheEntry.objects(ofEntry: key), [hash],
                       "with the objects the shared cache said it holds, for B's trim and collector")
        let figures = machineB.sharedCache.figures()
        XCTAssertEqual(figures.hits, 1)
        XCTAssertEqual(figures.bytesFetched, "an object file".utf8.count)

        XCTAssertNotNil(try lookUp())
        XCTAssertEqual(machineB.sharedCache.figures().hits, 1, "the second lookup is local and asks nothing")
    }

    func test_aKeyTheSharedCacheDoesNotHoldIsAMiss() throws {
        let machineB = try machine()

        XCTAssertNil(try lookUp())

        XCTAssertEqual(machineB.sharedCache.figures().misses, 1)
        XCTAssertEqual(remote.recordedCalls.filter { $0 == .getEntry }.count, 1)
    }

    /// Every step of the way can fail, and each failure is a miss, counted, with nothing
    /// written into the local cache and nothing thrown into the build.
    func test_aFailureAtEachStepOfTheFetchIsACountedMiss() throws {
        let cases: [(String, (InProcessRemoteCache) -> Void)] = [
            ("getEntry fails", { $0.fail(.getEntry, with: .connectionLost(reason: "reset")) }),
            ("the server's store fails", { $0.fail(.getEntry, with: .storeFailed(reason: "disk full")) }),
            ("hasObjects fails", { $0.fail(.hasObjects, with: .refused(reason: "malformed")) }),
            ("getObject fails", { $0.fail(.getObject, with: .connectionLost(reason: "timed out")) }),
            ("an object is gone by the time it is fetched", { $0.loseObjectsAfterAnsweringForThem() }),
            ("an object does not hash to its name", { $0.corruptObjects() }),
        ]
        for (name, breakIt) in cases {
            remote = try InProcessRemoteCache(objectRoot: try temporaryFolder("remote"))
            let key = try populatedByA()
            breakIt(remote)
            let machineB = try machine()

            XCTAssertNil(try lookUp(), name)

            XCTAssertEqual(machineB.sharedCache.figures().failures, 1, name)
            XCTAssertNotNil(machineB.sharedCache.figures().lastFailure, name)
            XCTAssertNil(try machineB.engine.database.cacheEntry.entry(forKey: key), "\(name): nothing is written locally")
        }
    }

    /// An object the server says it lacks is a miss before a byte moves.
    func test_anEntryWhoseObjectTheServerLacksIsAMissWithoutAFetch() throws {
        let machineA = try machine()
        let key = try build("an object file")
        try waitUntil("A's entry reaches the shared cache") { machineA.sharedCache.figures().entriesSent == 1 }
        let objectHash = try XCTUnwrap(try machineA.engine.database.cacheEntry.objects(ofEntry: key).first)
        try remote.objects.remove(hash: objectHash)
        let machineB = try machine()

        XCTAssertNil(try lookUp())

        XCTAssertEqual(machineB.sharedCache.figures().failures, 1)
        XCTAssertFalse(remote.recordedCalls.contains(.getObject))
    }

    /// The server files what a client sends under what the client says: bytes that are not
    /// an entry, and an entry whose own material keys it elsewhere, are misses.
    func test_anEntryThatDoesNotDecodeOrIsFiledUnderAnotherKeyIsAMiss() throws {
        let machineB = try machine()
        let tool = try sampleTool()
        let key = try tool.buildCacheKeyMaterial(input: try input()).key()

        try remote.file(content: Data("not an entry".utf8), underKey: key)
        XCTAssertNil(try lookUp())
        XCTAssertEqual(machineB.sharedCache.figures().failures, 1)

        let other = try tool.buildCacheKeyMaterial(input: ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try "optimise=2".intern())], SampleTool.input: [:]]))
        let misfiled = ProcessCacheEntry(outputValues: try output("another build").outputValues,
                                         specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]), keyMaterial: other)
        try remote.file(content: try misfiled.encoded(), underKey: key)
        XCTAssertNil(try lookUp(), "an entry keyed elsewhere by its own material is the wrong hit a cache must never give")
        XCTAssertEqual(machineB.sharedCache.figures().failures, 2)
    }

    // MARK: - Degradation

    /// While the connection is down a lookup is a flag read: no request, no connect.
    func test_whileTheServerIsUnreachableALookupAsksNothing() throws {
        remote.fail(.connect, with: .unreachable(address: "in-process", reason: "connection refused"))
        let machineB = try machine(connected: false)
        try waitUntil("the first attempt fails") {
            if case .down = machineB.sharedCache.state {
                return true
            }
            return false
        }

        XCTAssertNil(try lookUp())
        XCTAssertNil(try lookUp())

        XCTAssertEqual(machineB.sharedCache.figures().unavailable, 2)
        XCTAssertFalse(remote.recordedCalls.contains(.getEntry))
    }

    /// The server stopped in the middle of a build: the lookup that finds it gone is a
    /// failure, every one after it a miss that asks nothing, and the queue's thread connects
    /// again once the server is back, after which a lookup is a hit again.
    func test_aServerStoppedMidBuildLeavesTheLaterLookupsLocalAndIsConnectedToAgain() throws {
        _ = try populatedByA()
        let machineB = try machine()
        let connectsBefore = remote.recordedCalls.filter { $0 == .connect }.count
        remote.stop(afterCalls: 0)

        XCTAssertNil(try lookUp())
        let getsWhenStopped = remote.recordedCalls.filter { $0 == .getEntry }.count
        XCTAssertNil(try lookUp())

        XCTAssertEqual(machineB.sharedCache.figures().failures, 1)
        XCTAssertEqual(machineB.sharedCache.figures().unavailable, 1)
        XCTAssertEqual(remote.recordedCalls.filter { $0 == .getEntry }.count, getsWhenStopped, "the second asked nothing")
        try waitUntil("the queue's thread tries again, off the processing path") {
            remote.recordedCalls.filter { $0 == .connect }.count > connectsBefore
        }

        remote.restart()
        try waitUntil("the queue's thread connects again") {
            if case .connected = machineB.sharedCache.state {
                return true
            }
            return false
        }
        XCTAssertNotNil(try lookUp())
        XCTAssertEqual(machineB.sharedCache.figures().hits, 1)
    }

    func test_theQueueConnectsAgainWithTheWatchersBackoff() throws {
        remote.fail(.connect, with: .unreachable(address: "in-process", reason: "connection refused"))
        let started = Date()
        let machineB = try machine(connected: false)
        try waitUntil("two attempts fail") { remote.recordedCalls.filter { $0 == .connect }.count >= 2 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), SharedCache.firstReconnectDelay,
                                    "the second attempt waits the first delay")

        remote.unfail(.connect)

        try waitUntil("a later attempt connects") {
            if case .connected(.readWrite) = machineB.sharedCache.state {
                return true
            }
            return false
        }
    }

    // MARK: - The population queue

    func test_aReadOnlyGrantTakesNothingFromTheQueue() throws {
        remote.grant(.readOnly)
        let machineA = try machine()

        try build("an object file")

        XCTAssertEqual(machineA.sharedCache.figures().queued, 0)
        XCTAssertFalse(remote.recordedCalls.contains(.putEntry))
        XCTAssertEqual(try remote.entryCount(), 0)
    }

    /// A write is the entry's objects the server lacks, then the entry.
    func test_aWriteSendsOnlyTheObjectsTheServerLacksThenTheEntry() throws {
        let machineA = try machine()
        try build("an object file")
        try waitUntil("the entry is sent") { machineA.sharedCache.figures().entriesSent == 1 }

        XCTAssertEqual(Array(remote.recordedCalls.drop { $0 == .connect }), [.hasObjects, .putObject, .putEntry])
        XCTAssertEqual(try remote.entryCount(), 1)
    }

    /// A failed write drops the item and counts it; the queue goes on.
    func test_aFailedWriteIsDroppedAndCounted() throws {
        remote.fail(.putEntry, with: .refused(reason: "readOnly"))
        let machineA = try machine()

        try build("an object file")

        try waitUntil("the write fails") { machineA.sharedCache.figures().writeFailures == 1 }
        XCTAssertEqual(machineA.sharedCache.figures().queued, 0)
        XCTAssertEqual(try remote.entryCount(), 0)
    }

    /// A dead server never grows the engine's memory: the queue holds what it may and drops
    /// the oldest.
    func test_aFullQueueDropsItsOldest() throws {
        remote.fail(.connect, with: .unreachable(address: "in-process", reason: "connection refused"))
        let machineA = try machine(capacity: PopulationQueue.Capacity(items: 2, bytes: 1 << 20), connected: false)

        for edition in 0..<5 {
            let tool = try sampleTool()
            let material = try tool.buildCacheKeyMaterial(input: ProcessInput(inputValues: [
                SampleTool.configuration: ["configuration": .value(try "edition=\(edition)".intern())], SampleTool.input: [:]]))
            try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 0.1,
                                                     output: try output("edition \(edition)"))
        }

        let figures = machineA.sharedCache.figures()
        XCTAssertEqual(figures.queued, 2)
        XCTAssertEqual(figures.dropped, 3)
    }

    /// The settle's write hands the entry to the queue and goes on: a server that takes no
    /// write leaves every settle to complete.
    func test_aSettleCompletesWhileTheQueuesServerIsStalled() async throws {
        remote.stallWrites()
        let machineA = try machine()
        machineA.engine.startProcessingLoop()
        defer {
            remote.releaseWrites()
            machineA.engine.stopProcessingLoop()
            machineA.engine.waitUntilIdleBlocking()
        }

        machineA.engine.beginBatch()
        var tools: [ObjectID] = []
        do {
            _ = try machineA.engine.inputFileSystem.ensureEntirePathExistsAsFolders("src", pinned: true)
            for index in 0..<4 {
                let path = "input:/src/\(index).txt"
                let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(path)')").findOrCreateMatchingNode()
                let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
                _ = try file.replaceContent(try "source \(index)".intern())
                let spec = "LabellingSampleTool(input: ['source': StaticFile(path: '\(path)').output]).output"
                tools.append(try GraphSpecNode.parse(spec).findOrCreateMatchingNode().fromNode.requireID())
            }
        } catch {
            machineA.engine.endBatch()
            throw error
        }
        machineA.engine.endBatch()

        machineA.engine.signalWorkAvailable()
        let settled = expectation(description: "the settle completes")
        Task {
            await machineA.engine.waitUntilIdle()
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 20)

        for nodeID in tools {
            let port = try machineA.engine.database.outputPort.select(nodeID: nodeID,
                                                                      nameSymbolID: LabellingSampleTool.output.asSymbolID())
            XCTAssertEqual(port?.valueKind, .value)
        }
        let figures = machineA.sharedCache.figures()
        XCTAssertEqual(figures.entriesSent, 0, "the server took nothing")
        XCTAssertGreaterThanOrEqual(figures.queued, tools.count - 1, "at most one write is in flight, stalled; the rest wait")
    }

    // MARK: - The fetch policy

    /// An entry that cost a millisecond to build, over a link measured at a kilobyte a
    /// second, is built rather than fetched; the same entry at the assumed LAN rate is
    /// fetched.
    func test_aCheapEntryOverASlowLinkIsBuiltRatherThanFetched() throws {
        _ = try populatedByA(String(repeating: "x", count: 10_000), cost: 0.001)
        let slow = try machine()
        for _ in 0..<4 {
            slow.sharedCache.record(CacheFetchPolicy.Sample(bytes: 1_000, seconds: 1))
        }

        XCTAssertNil(try lookUp())

        XCTAssertEqual(slow.sharedCache.figures().declined, 1)
        XCTAssertFalse(remote.recordedCalls.contains(.getObject), "nothing was fetched")

        try machine()
        XCTAssertNotNil(try lookUp(), "at the assumed rate the fetch is under the build's millisecond")
    }
}
