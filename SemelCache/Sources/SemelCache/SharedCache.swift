// SharedCache.swift
// SemelCache
//
// Everything an engine does with a shared cache (B-153), over a `RemoteCache`: the lookup
// that follows a local miss, the queue that writes what the engine built, the connection
// kept open behind both, and the figures `cache` shows.
//
// Two rules shape it. A shared cache may make a build faster and must never make one wrong
// or stuck: every failure on the way to a hit is a miss, counted and not thrown, and a write
// the server does not take is dropped, counted and not retried. And the processing path
// pays nothing for a remote it cannot use: a lookup while the connection is down is a flag
// read and a miss — no connect, no wait — and the connection is opened again by the queue's
// thread, with the watcher's backoff, never by a node.
//
// Time enters here and nowhere in the engine: the fetch policy weighs a measured rate, and
// the reconnection waits. Both decide how long a build takes, never what it computes — a
// hit declined is a build that runs and gives the same answer.

import Foundation
import SemelNodeKit

/// An entry a shared cache answered, with its objects in this machine's object store: what
/// the engine writes into its own cache and applies as a hit.
public struct FetchedEntry {
    public let entry: ProcessCacheEntry
    public let content: Data
    /// Milliseconds (`CacheCost`).
    public let cost: Int
    public let objects: [CachedObject]
}

/// What a lookup on the shared cache came to. Every case but `hit` is a miss to the engine,
/// which builds; the cases are kept apart for what the engine says about them.
public enum SharedCacheLookup {
    case hit(FetchedEntry)
    /// The remote has no entry under the key.
    case miss
    /// The entry's objects would take longer to fetch than its build took: `cost` and
    /// `estimate` in milliseconds.
    case declined(nodeType: String, cost: Int, estimate: Double)
    /// Something on the way failed; counted, and the connection marked down when it ended.
    case failed(reason: String)
    /// The connection is down, and nothing was asked.
    case unavailable

    /// The entry, for a hit.
    public var fetched: FetchedEntry? {
        guard case .hit(let fetched) = self else {
            return nil
        }
        return fetched
    }
}

public final class SharedCache {

    /// Where the connection stands, as `cache` names it.
    public enum ConnectionState: Equatable, Sendable {
        /// Not yet connected since the cache was started.
        case connecting
        case connected(RemoteCacheAccess)
        /// The last attempt to connect failed, or the connection was lost; the queue's thread
        /// tries again.
        case down(reason: String)
        /// The server answered the hello with a refusal; the queue's thread asks again, at
        /// the longest wait, in case the server changes.
        case rejected(reason: String)
        case stopped
    }

    /// What the cache has done since it started.
    public struct Figures: Equatable, Sendable {
        /// Lookups the remote answered with an entry that was fetched and taken.
        public var hits = 0
        /// Lookups the remote had no entry for.
        public var misses = 0
        /// Lookups that failed on the way: the connection, a missing object, a hash that
        /// did not verify, an entry that does not decode or is not filed under its own key.
        public var failures = 0
        /// Lookups whose fetch the policy judged slower than the build.
        public var declined = 0
        /// Lookups made while the connection was down, answered as misses without asking.
        public var unavailable = 0
        public var bytesFetched = 0
        /// Entries written to the remote, and the bytes of them and of the objects put
        /// before them.
        public var entriesSent = 0
        public var bytesSent = 0
        /// Items the queue dropped because it was full, and items whose write failed.
        public var dropped = 0
        public var writeFailures = 0
        /// Items waiting.
        public var queued = 0
        public var bytesPerSecond = CacheFetchPolicy.assumedBytesPerSecond
        public var rateIsAssumed = true
        /// What a request costs however small, as the fetches measured it; 0 before any.
        public var secondsPerRequest = 0.0
        /// The last failure, for a person to read.
        public var lastFailure: String?

        public init() {}
    }

    /// Why a lookup did not complete, beside the remote's own failures.
    enum FetchFailure: Error, CustomStringConvertible {
        case undecodable(reason: String)
        case keyMismatch(asked: CacheKey, filed: String)
        case objectMissing(hash: DataObjectHash)
        case hashMismatch(declared: DataObjectHash, actual: DataObjectHash)
        case objectNotStored(hash: DataObjectHash, reason: String)

        var description: String {
            switch self {
            case .undecodable(let reason):
                return "an entry this engine cannot decode (\(reason))"
            case .keyMismatch(let asked, let filed):
                return "the entry under \(asked.hash.prefix(16)) is keyed \(filed.prefix(16)) by its own material"
            case .objectMissing(let hash):
                return "the server no longer holds object \(hash.prefix(16))"
            case .hashMismatch(let declared, let actual):
                return "object \(declared.prefix(16)) arrived as bytes hashing to \(actual.prefix(16))"
            case .objectNotStored(let hash, let reason):
                return "object \(hash.prefix(16)) could not be stored here: \(reason)"
            }
        }
    }

    /// Why an item was not written, beside the remote's own failures.
    enum WriteFailure: Error, CustomStringConvertible {
        case objectNotHere(hash: DataObjectHash)

        var description: String {
            switch self {
            case .objectNotHere(let hash):
                return "object \(hash.prefix(16)) is no longer in this engine's store"
            }
        }
    }

    /// The watcher's backoff (`Watcher.openSession`): a quarter of a second after the first
    /// failure, doubling to five.
    public static let firstReconnectDelay: TimeInterval = 0.25
    public static let longestReconnectDelay: TimeInterval = 5

    public let remote: RemoteCache
    public let identity: String?
    private let objectStore: DataObjectStore

    /// Guards everything below it; held for bookkeeping only, never across a call to the
    /// remote.
    private let condition = NSCondition()
    private var currentState = ConnectionState.connecting
    private var counted = Figures()
    private var queue: PopulationQueue
    private var policy = CacheFetchPolicy()
    private var isStopping = false
    /// Which connection is open: moved on at every connect, so a failure on a connection
    /// that has since been replaced does not mark its successor down.
    private var generation = 0
    private var thread: Thread?
    private let threadEnded = DispatchSemaphore(value: 0)

    /// A queue of the standard capacity. An overload rather than a default argument, which
    /// would fold the constant into every caller's object file (AGENTS.md).
    public convenience init(remote: RemoteCache, identity: String?, objectStore: DataObjectStore) {
        self.init(remote: remote, identity: identity, objectStore: objectStore, capacity: .standard)
    }

    public init(remote: RemoteCache, identity: String?, objectStore: DataObjectStore, capacity: PopulationQueue.Capacity) {
        self.remote      = remote
        self.identity    = identity
        self.objectStore = objectStore
        self.queue       = PopulationQueue(capacity: capacity)
    }

    // MARK: - Running

    /// Starts the queue's thread, which connects first.
    public func start() {
        condition.withLock {
            guard thread == nil else {
                return
            }
            let thread = Thread { [self] in run() }
            thread.name = "semel.shared-cache"
            self.thread = thread
            thread.start()
        }
    }

    /// Stops the thread and closes the connection; what is queued is not written. Waits for
    /// the thread at most `timeout`: a write in flight fails once the connection closes.
    public func stop(timeout: TimeInterval = 5) {
        let started: Bool = condition.withLock {
            isStopping = true
            currentState = .stopped
            condition.broadcast()
            return thread != nil
        }
        remote.disconnect()
        if started {
            _ = threadEnded.wait(timeout: .now() + timeout)
        }
    }

    public var state: ConnectionState {
        condition.withLock { currentState }
    }

    public func figures() -> Figures {
        condition.withLock {
            var figures               = counted
            figures.queued            = queue.count
            figures.bytesPerSecond    = policy.bytesPerSecond
            figures.rateIsAssumed     = policy.isAssumed
            figures.secondsPerRequest = policy.secondsPerRequest
            return figures
        }
    }

    /// Takes a fetch's measurement as though it had been measured: what a test of the
    /// policy over a slow link starts from.
    public func record(_ sample: CacheFetchPolicy.Sample) {
        condition.withLock { policy.record(sample) }
    }

    // MARK: - The lookup

    /// The entry under `key` from the remote, with every object it holds now in the object
    /// store and verified — or why not: a miss, a declined fetch, a connection that is down,
    /// or a failure on the way. Never throws and never connects.
    public func fetch(key: CacheKey) -> SharedCacheLookup {
        let usable: Int? = condition.withLock {
            guard case .connected = currentState else {
                counted.unavailable += 1
                return nil
            }
            return generation
        }
        guard let connection = usable else {
            return .unavailable
        }
        do {
            guard let answered = try remote.entry(forKey: key) else {
                condition.withLock { counted.misses += 1 }
                return .miss
            }
            let entry = try decodedEntry(answered.content, key: key)
            let lacking = answered.objects.filter { !$0.hash.isEmpty && !objectStore.exists(hash: $0.hash) }
            if !lacking.isEmpty {
                // Asked before a byte moves: an object evicted since the entry was answered
                // would otherwise be found missing halfway through the fetch.
                if let absent = try remote.missingObjects(among: lacking.map(\.hash)).first {
                    throw FetchFailure.objectMissing(hash: absent)
                }
            }
            let lackingBytes = lacking.reduce(0) { $0 + $1.bytes }
            let (worthIt, estimate) = condition.withLock {
                (policy.shouldFetch(objects: lacking.count, bytes: lackingBytes, cost: answered.cost),
                 policy.estimatedMilliseconds(objects: lacking.count, bytes: lackingBytes))
            }
            guard worthIt else {
                condition.withLock { counted.declined += 1 }
                return .declined(nodeType: entry.keyMaterial.nodeType, cost: answered.cost, estimate: estimate)
            }
            for object in lacking {
                try fetchObject(object)
            }
            condition.withLock { counted.hits += 1 }
            return .hit(FetchedEntry(entry: entry, content: answered.content, cost: answered.cost, objects: answered.objects))
        } catch {
            noteFailure(error, counting: \.failures, connection: connection)
            return .failed(reason: "\(error)")
        }
    }

    /// The entry the bytes hold, and only if its own material keys it under `key`: the server
    /// files what a client sent under what the client said, and an entry filed under a key
    /// it does not account for is the one wrong hit a cache must never give (B-13).
    private func decodedEntry(_ content: Data, key: CacheKey) throws -> ProcessCacheEntry {
        let entry: ProcessCacheEntry
        do {
            entry = try ProcessCacheEntry.decoded(from: content)
        } catch {
            throw FetchFailure.undecodable(reason: "\(error)")
        }
        let filed = try entry.cacheKey()
        guard filed == key.hash else {
            throw FetchFailure.keyMismatch(asked: key, filed: filed)
        }
        return entry
    }

    /// One object into the store, hashed before it is kept, and its time recorded for the
    /// rate.
    private func fetchObject(_ object: CachedObject) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let bytes = try remote.object(hash: object.hash, expectedBytes: object.bytes) else {
            throw FetchFailure.objectMissing(hash: object.hash)
        }
        let actual = Sha256.hash(bytes)
        guard actual == object.hash else {
            throw FetchFailure.hashMismatch(declared: object.hash, actual: actual)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        do {
            try objectStore.store(hash: object.hash, content: [UInt8](bytes))
        } catch {
            throw FetchFailure.objectNotStored(hash: object.hash, reason: "\(error)")
        }
        condition.withLock {
            counted.bytesFetched += bytes.count
            policy.record(CacheFetchPolicy.Sample(bytes: bytes.count, seconds: seconds))
        }
    }

    // MARK: - The population queue

    /// Queues an entry the engine built for the remote. Never waits: a full queue drops its
    /// oldest, and a connection the server made read-only takes nothing.
    public func populate(_ item: PopulationItem) {
        condition.withLock {
            switch currentState {
            case .connected(.readOnly), .stopped:
                return
            case .connecting, .connected(.readWrite), .down, .rejected:
                break
            }
            counted.dropped += queue.append(item)
            condition.broadcast()
        }
    }

    /// The thread: connect when there is no connection, then write what is queued, oldest
    /// first, until stopped.
    private func run() {
        defer {
            remote.disconnect()
            threadEnded.signal()
        }
        var delay = Self.firstReconnectDelay
        while true {
            let next: Step = condition.withLock { nextStep() }
            switch next {
            case .stop:
                return
            case .connect:
                if connect() {
                    delay = Self.firstReconnectDelay
                    continue
                }
                let waited = delay
                delay = min(delay * 2, Self.longestReconnectDelay)
                condition.withLock {
                    if case .rejected = currentState {
                        delay = Self.longestReconnectDelay
                    }
                    guard !isStopping else {
                        return
                    }
                    _ = condition.wait(until: Date(timeIntervalSinceNow: waited))
                }
            case .write(let item, let connection):
                write(item, connection: connection)
            }
        }
    }

    private enum Step {
        case stop
        case connect
        case write(PopulationItem, connection: Int)
    }

    /// What the thread does next, waiting under the lock until there is something.
    private func nextStep() -> Step {
        while true {
            if isStopping {
                return .stop
            }
            switch currentState {
            case .connecting, .down, .rejected:
                return .connect
            case .stopped:
                return .stop
            case .connected:
                if let item = queue.removeFirst() {
                    return .write(item, connection: generation)
                }
                condition.wait()
            }
        }
    }

    /// One attempt. A read-only grant empties the queue: nothing in it can be written.
    private func connect() -> Bool {
        do {
            let access = try remote.connect(identity: identity)
            condition.withLock {
                guard !isStopping else {
                    return
                }
                currentState = .connected(access)
                generation += 1
                if access == .readOnly {
                    queue.removeAll()
                }
            }
            return true
        } catch let error as RemoteCacheError {
            remote.disconnect()
            condition.withLock {
                guard !isStopping else {
                    return
                }
                if case .rejected(let reason) = error {
                    currentState = .rejected(reason: reason)
                } else {
                    currentState = .down(reason: error.description)
                }
            }
            return false
        } catch {
            remote.disconnect()
            condition.withLock {
                if !isStopping {
                    currentState = .down(reason: "\(error)")
                }
            }
            return false
        }
    }

    /// `hasObjects`, a `putObject` for each the server lacks, then `putEntry`. A failure
    /// drops the item; one that ends the connection marks it down for the thread to open
    /// again.
    private func write(_ item: PopulationItem, connection: Int) {
        do {
            var sent = 0
            let named = item.objects.map(\.hash).filter { !$0.isEmpty }
            for hash in try remote.missingObjects(among: named) {
                guard let bytes = try? objectStore.read(hash: hash) else {
                    throw WriteFailure.objectNotHere(hash: hash)
                }
                try remote.putObject(hash: hash, bytes: Data(bytes))
                sent += bytes.count
            }
            try remote.putEntry(key: item.key, cost: item.cost, objects: named, content: item.content)
            sent += item.content.count
            condition.withLock {
                counted.entriesSent += 1
                counted.bytesSent   += sent
            }
        } catch {
            noteFailure(error, counting: \.writeFailures, connection: connection)
        }
    }

    /// Counts a failure, keeps its words for `cache`, and marks the connection down when the
    /// failure ended it — the connection the failing call was made on, and only while it is
    /// still the one open. A lookup marks it down and closes it without connecting; the
    /// thread is woken to connect again.
    private func noteFailure(_ error: Error, counting figure: WritableKeyPath<Figures, Int>, connection: Int) {
        let endsConnection = (error as? RemoteCacheError)?.endsConnection ?? false
        condition.withLock {
            counted[keyPath: figure] += 1
            counted.lastFailure = "\(error)"
            guard endsConnection, connection == generation, case .connected = currentState else {
                return
            }
            currentState = .down(reason: "\(error)")
            // Closed under the lock, so the thread cannot have opened the next connection
            // before this one is shut.
            remote.disconnect()
            condition.broadcast()
        }
    }
}
