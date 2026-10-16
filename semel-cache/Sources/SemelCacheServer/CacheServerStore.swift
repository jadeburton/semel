// CacheServerStore.swift
// SemelCacheServer
//
// The shared cache's store: entries under their keys and objects under their hashes, on disk
// under the server's home, answered from an index in memory.
//
// The server answers as quickly as it can and trades durability for it, never consistency.
// Every key, every object hash and every size is held in memory and kept in step with the
// disk, so a miss and a `hasObjects` never touch the disk, and an entry's accounting —
// B-148's sizes and order — is worked out without a query. The disk is the index's SQLite
// database (`CacheIndexDatabase`) and the node kit's object store. Writes to the database
// are queued and committed in batches by one writer thread, each batch one transaction in
// the write-ahead log; a `putEntry` is answered once its batch is in the log, and the log is
// moved into the database file when the writer finds nothing waiting. A `putObject` is
// answered once its bytes are hashed and in memory, and its file is written behind the
// answer by writers of its own. A crash can lose the last batches and the last objects, and
// leaves the database consistent; an entry whose objects did not survive with it is dropped
// when the store opens again, and an object no entry holds is removed then.
//
// The server reads nothing inside an entry. The bytes are the engine's encoding, filed as
// they came; the cost and the objects the entry references come beside them as fields of
// the request, and they are all the accounting needs.

import Foundation
import SemelCache
import SemelNodeKit
import SemelProtocol

/// A request's answer, made ready: the reply, and the write it has to wait for before it
/// may be sent.
public struct CacheAnswer {
    public let response: Response
    public let body: Data?
    /// The queued write this answer waits for: a `putEntry` is answered once its entry is in
    /// the log. Nil for an answer that waits for nothing.
    let awaitedWrite: UInt64?

    init(_ response: CacheResponse, body: Data? = nil, awaitedWrite: UInt64? = nil) {
        self.response     = .cache(response)
        self.body         = body
        self.awaitedWrite = awaitedWrite
    }

    init(error: ErrorResponse) {
        self.response     = .error(error)
        self.body         = nil
        self.awaitedWrite = nil
    }

    init(hello: HelloResponse) {
        self.response     = .hello(hello)
        self.body         = nil
        self.awaitedWrite = nil
    }
}

public final class CacheServerStore {

    /// The bytes the entries may hold, each object once.
    public let limit: ByteCount

    /// How many entry requests — `getEntry` and `putEntry` — make one use of the cache, the
    /// unit eviction counts in. B-148's order keeps what the last use touched over what it
    /// did not; an engine closes a use per settle, and a server, which has no settles, closes
    /// one every this many requests. So an entry asked for or written within the last one or
    /// two windows is kept over every entry that was not.
    public let requestsPerUse: Int

    private let database: CacheIndexDatabase
    private let rows: SQLiteCacheStore
    private let objectStore: DataObjectStore

    // MARK: The index, under `indexLock`

    private struct IndexedEntry {
        var cost: Int
        var lastUse: Int
        /// Sorted, each once.
        var objects: [DataObjectHash]
    }

    /// Recursive, because a trim runs inside a `putEntry` and asks the store's own methods.
    private let indexLock = NSRecursiveLock()
    private var entries: [String: IndexedEntry] = [:]
    /// Every object the store holds, with its size: held by an entry or not yet.
    private var objectBytes: [DataObjectHash: Int] = [:]
    /// How many entries hold each object that any entry holds.
    private var holders: [DataObjectHash: Int] = [:]
    /// The bytes of the objects any entry holds, each once: what the limit is held to.
    private var heldBytes = 0
    private var settle = 1
    private var lastUsingSettle = 0
    private var entryRequestsThisUse = 0
    private var hits = 0
    private var misses = 0
    /// Entries written to the queue and not yet to the log: a hit on one is answered from
    /// here, since the database does not have it yet.
    private var pendingContent: [String: (write: UInt64, content: Data)] = [:]
    /// Objects answered as stored whose files are still being written, with their bytes:
    /// served from here meanwhile, and never removed from under the write.
    private var pendingObjects: [DataObjectHash: Data] = [:]
    private var pendingObjectBytes = 0

    private let writer: IndexWriter

    /// Writes objects' files off the request path, several at once: the file system takes
    /// concurrent creates in its stride, and a create is most of what a put costs.
    private let objectWriters: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "semel-cache.objects"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// How many bytes of objects may wait for their files before a put waits with them: the
    /// memory a client faster than the disk can take.
    private static let pendingObjectLimit = 256 * ByteCount.mebibyte

    /// Opens the store over `database` and `objectStore`, and brings the two into step: an
    /// entry whose objects are not all in the store is dropped, and an object no entry holds
    /// — one put for an entry that never came — is removed. Done here, before any client
    /// can be in the middle of putting one.
    public init(database: CacheIndexDatabase, objectStore: DataObjectStore, limit: ByteCount, requestsPerUse: Int) throws {
        let rows = SQLiteCacheStore(database: database)
        self.database       = database
        self.rows           = rows
        self.objectStore    = objectStore
        self.limit          = limit
        self.requestsPerUse = max(1, requestsPerUse)
        self.writer         = IndexWriter(rows: rows, database: database)

        for object in objectStore.objects() {
            objectBytes[object.hash] = object.size
        }
        let stored = try rows.indexRows()
        var incomplete: [CacheIndexOperation] = []
        for row in stored.entries {
            guard row.objects.allSatisfy({ objectBytes[$0] != nil }) else {
                incomplete.append(.delete(hash: row.hash))
                continue
            }
            entries[row.hash] = IndexedEntry(cost: row.cost, lastUse: row.lastUse, objects: row.objects)
            for object in row.objects {
                hold(object)
            }
        }
        try rows.apply(incomplete)
        settle          = stored.account.settle
        lastUsingSettle = stored.account.lastUsingSettle
        for hash in objectBytes.keys.sorted() where holders[hash] == nil {
            try objectStore.remove(hash: hash)
            objectBytes[hash] = nil
        }

        writer.store = self
        writer.start()
    }

    /// Writes what is queued — the objects' files, then the index — checkpoints, and stops
    /// the writers. The store answers nothing after.
    public func close() {
        objectWriters.waitUntilAllOperationsAreFinished()
        writer.stop()
    }

    // MARK: - Answering

    /// Does what `request` asks of the store, in the order requests arrive, and says what
    /// to answer. A write that has to reach the log first is queued here and waited for in
    /// `complete`, so the next request is prepared while this one's batch commits.
    public func prepare(_ request: CacheRequest, body: Data?) -> CacheAnswer {
        do {
            switch request {
            case .getEntry(let key):
                return try getEntry(key)
            case .putEntry(let key, let cost, let objects, let length):
                return try putEntry(key, cost: cost, objects: objects, length: length, body: body ?? Data())
            case .hasObjects(let hashes):
                return hasObjects(hashes)
            case .getObject(let hash):
                return getObject(hash)
            case .putObject(let hash):
                return putObject(hash, body: body ?? Data())
            case .status:
                return CacheAnswer(.status(status()))
            case .purge(let key):
                let (removed, write) = try purge(key)
                return CacheAnswer(.purged(entries: removed ? 1 : 0), awaitedWrite: write)
            case .purgeAll:
                let (removed, write) = purgeAll()
                return CacheAnswer(.purged(entries: removed), awaitedWrite: write)
            }
        } catch {
            return CacheAnswer(error: .cacheStoreFailed(description: "\(error)"))
        }
    }

    /// The answer, once the write it waits for is in the log: the reply, or the failure
    /// that kept the write out of it.
    public func complete(_ answer: CacheAnswer) -> (Response, Data?) {
        guard let awaited = answer.awaitedWrite else {
            return (answer.response, answer.body)
        }
        if let failure = writer.wait(for: awaited) {
            return (.error(.cacheStoreFailed(description: failure)), nil)
        }
        return (answer.response, answer.body)
    }

    // MARK: - Entries

    private func getEntry(_ key: CacheKey) throws -> CacheAnswer {
        let found: (cost: Int, objects: [CachedObject], pending: Data?)? = indexLock.withLock {
            defer { countEntryRequest() }
            guard let entry = entries[key.hash] else {
                misses += 1
                return nil
            }
            var objects: [CachedObject] = []
            for hash in entry.objects {
                guard let bytes = objectBytes[hash] else {
                    misses += 1
                    return nil
                }
                objects.append(CachedObject(hash: hash, bytes: bytes))
            }
            stampUse(key.hash)
            hits += 1
            return (entry.cost, objects, pendingContent[key.hash]?.content)
        }
        guard let found else {
            return CacheAnswer(.miss)
        }
        guard let content = try found.pending ?? rows.content(hash: key.hash) else {
            // Evicted between the index and the read.
            indexLock.withLock {
                hits   -= 1
                misses += 1
            }
            return CacheAnswer(.miss)
        }
        return CacheAnswer(.entry(cost: found.cost, objects: found.objects), body: content)
    }

    private func putEntry(_ key: CacheKey, cost: Int, objects: [DataObjectHash], length: Int, body: Data) throws -> CacheAnswer {
        guard body.count == length else {
            return CacheAnswer(.refused(reason: .lengthMismatch(declared: length, received: body.count)))
        }
        if let malformed = objects.first(where: { !Self.isObjectHash($0) }) {
            return CacheAnswer(.refused(reason: .notAnObjectHash(hash: malformed)))
        }
        return try indexLock.withLock {
            defer { countEntryRequest() }
            let named   = Set(objects.filter { !$0.isEmpty }).sorted()
            let missing = named.filter { objectBytes[$0] == nil }
            guard missing.isEmpty else {
                return CacheAnswer(.refused(reason: .objectsMissing(hashes: missing)))
            }
            let held = named.compactMap { hash in objectBytes[hash].map { CachedObject(hash: hash, bytes: $0) } }
            let write = try record(hash: key.hash, cost: cost, content: body, objects: held)
            if heldBytes > limit.bytes {
                _ = try trim(toLimit: ByteCount(bytes: limit.bytes - limit.bytes / 10))
            }
            return CacheAnswer(.stored, awaitedWrite: write)
        }
    }

    // MARK: - Objects

    private func hasObjects(_ hashes: [DataObjectHash]) -> CacheAnswer {
        if let malformed = hashes.first(where: { !Self.isObjectHash($0) }) {
            return CacheAnswer(.refused(reason: .notAnObjectHash(hash: malformed)))
        }
        let missing = indexLock.withLock {
            hashes.filter { !$0.isEmpty && objectBytes[$0] == nil }
        }
        return CacheAnswer(.missingObjects(hashes: missing))
    }

    /// The file, mapped, as the reply's body: no copy of it is made here, and it is not hashed
    /// again on the way out — the client hashes what it receives.
    private func getObject(_ hash: DataObjectHash) -> CacheAnswer {
        guard Self.isObjectHash(hash) else {
            return CacheAnswer(.refused(reason: .notAnObjectHash(hash: hash)))
        }
        guard !hash.isEmpty else {
            return CacheAnswer(.object, body: Data())
        }
        let held: (present: Bool, pending: Data?) = indexLock.withLock {
            (objectBytes[hash] != nil, pendingObjects[hash])
        }
        guard held.present else {
            return CacheAnswer(.miss)
        }
        if let pending = held.pending {
            return CacheAnswer(.object, body: pending)
        }
        guard let bytes = try? Data(contentsOf: objectStore.objectURL(hash: hash), options: .alwaysMapped) else {
            return CacheAnswer(.miss)
        }
        return CacheAnswer(.object, body: bytes)
    }

    private func putObject(_ hash: DataObjectHash, body: Data) -> CacheAnswer {
        guard Self.isObjectHash(hash) else {
            return CacheAnswer(.refused(reason: .notAnObjectHash(hash: hash)))
        }
        let actual = Sha256.hash(body)
        guard actual == hash else {
            return CacheAnswer(.refused(reason: .hashMismatch(declared: hash, actual: actual)))
        }
        // The empty object is never stored: its hash is the empty string, and every store
        // has it.
        guard !hash.isEmpty else {
            return CacheAnswer(.stored)
        }
        let (alreadyHeld, waiting) = indexLock.withLock { () -> (Bool, Int) in
            guard objectBytes[hash] == nil else {
                return (true, pendingObjectBytes)
            }
            objectBytes[hash] = body.count
            if pendingObjects.updateValue(body, forKey: hash) == nil {
                pendingObjectBytes += body.count
            }
            return (false, pendingObjectBytes)
        }
        guard !alreadyHeld else {
            return CacheAnswer(.stored)
        }
        objectWriters.addOperation { [weak self] in
            self?.writeFile(of: hash)
        }
        if waiting > Self.pendingObjectLimit {
            objectWriters.waitUntilAllOperationsAreFinished()
        }
        return CacheAnswer(.stored)
    }

    /// An object's file, written from the bytes the put left in memory. An object freed
    /// while its file was being written — evicted, purged — has the file removed again,
    /// since nothing removes a file that was not there yet.
    private func writeFile(of hash: DataObjectHash) {
        guard let bytes = indexLock.withLock({ pendingObjects[hash] }) else {
            return
        }
        var failure: Error?
        do {
            try objectStore.store(hash: hash, content: [UInt8](bytes))
        } catch {
            failure = error
        }
        indexLock.withLock {
            if pendingObjects.removeValue(forKey: hash) != nil {
                pendingObjectBytes -= bytes.count
            }
            if objectBytes[hash] == nil {
                try? objectStore.remove(hash: hash)
            }
        }
        if let failure {
            // The index still names the object, so a fetch of it misses and the client
            // builds instead; the log is where a full disk is seen.
            FileHandle.standardError.write(Data("semel-cache: an object could not be written: \(failure)\n".utf8))
        }
    }

    /// Whether `hash` is a name the object store files anything under: hex digits, two to a
    /// byte, at most a SHA-256's worth — an object no longer than a digest is filed under its
    /// own bytes (`Sha256.hash`), and the empty object under the empty string. Checked before
    /// a hash names a path, so nothing a client sends can name a file outside the store.
    static func isObjectHash(_ hash: String) -> Bool {
        hash.utf8.count <= 64 && hash.utf8.count % 2 == 0
            && hash.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // MARK: - Status and purge

    public func status() -> CacheServerStatus {
        indexLock.withLock {
            CacheServerStatus(entries: entries.count, bytes: ByteCount(bytes: heldBytes), limit: limit,
                              hits: hits, misses: misses)
        }
    }

    private func purge(_ key: CacheKey) throws -> (removed: Bool, write: UInt64) {
        try indexLock.withLock {
            let removed = try delete(hash: key.hash)
            return (removed, writer.lastQueued)
        }
    }

    /// Every entry and every object: the index emptied, and every file of the object store
    /// removed once the emptied index is in the log.
    private func purgeAll() -> (removed: Int, write: UInt64) {
        // The files still being written land first, so the sweep finds every one of them.
        objectWriters.waitUntilAllOperationsAreFinished()
        return indexLock.withLock {
            let removed = entries.count
            entries.removeAll()
            holders.removeAll()
            objectBytes.removeAll()
            pendingContent.removeAll()
            heldBytes = 0
            let write = writer.enqueue(.deleteAll)
            writer.requestSweep()
            return (removed, write)
        }
    }

    // MARK: - The index's bookkeeping

    private func hold(_ object: DataObjectHash) {
        let count = holders[object, default: 0]
        if count == 0 {
            heldBytes += objectBytes[object] ?? 0
        }
        holders[object] = count + 1
    }

    /// One holder fewer; an object no entry holds any more leaves the total and the store.
    private func release(_ object: DataObjectHash) {
        let count = holders[object, default: 0]
        guard count > 1 else {
            holders[object] = nil
            heldBytes -= objectBytes[object] ?? 0
            objectBytes[object] = nil
            writer.remove(object)
            return
        }
        holders[object] = count - 1
    }

    private func stampUse(_ hash: String) {
        entries[hash]?.lastUse = settle
        writer.enqueue(.noteUse(hash: hash))
    }

    /// One more entry request; every `requestsPerUse` of them close a use of the cache, as a
    /// settle closes one for an engine — when something was used in it.
    private func countEntryRequest() {
        entryRequestsThisUse += 1
        guard entryRequestsThisUse >= requestsPerUse else {
            return
        }
        entryRequestsThisUse = 0
        if entries.values.contains(where: { $0.lastUse == settle }) {
            lastUsingSettle = settle
            settle += 1
        }
        writer.enqueue(.closeSettle)
    }

    /// Files an entry in the index and queues it for the log. Its new objects are held
    /// before its old ones are released, so an object both hold never leaves the store.
    private func record(hash: String, cost: Int, content: Data, objects: [CachedObject]) throws -> UInt64 {
        let previous = entries[hash]
        for object in objects {
            hold(object.hash)
        }
        for object in previous?.objects ?? [] {
            release(object)
        }
        entries[hash] = IndexedEntry(cost: cost, lastUse: settle, objects: objects.map(\.hash))
        let write = writer.enqueue(.save(hash: hash, nodeType: "", cost: cost, content: content, objects: objects))
        pendingContent[hash] = (write, content)
        return write
    }

    /// Called by the writer once the writes up to `write` are in the log.
    fileprivate func written(through write: UInt64) {
        indexLock.withLock {
            pendingContent = pendingContent.filter { $0.value.write > write }
        }
    }

    /// Called by the writer for an object it was asked to remove: runs `removing` unless the
    /// object was put again since, which a put while the removal waited makes it.
    fileprivate func mayRemove(_ object: DataObjectHash, removing: () throws -> Void) rethrows {
        try indexLock.withLock {
            guard objectBytes[object] == nil, pendingObjects[object] == nil else {
                return
            }
            try removing()
        }
    }

    /// Called by the writer for a sweep: removes every file the index does not know.
    fileprivate func sweep() throws {
        try indexLock.withLock {
            for object in objectStore.objects() where objectBytes[object.hash] == nil && pendingObjects[object.hash] == nil {
                try objectStore.remove(hash: object.hash)
            }
        }
    }

    fileprivate func removeFile(of object: DataObjectHash) throws {
        try mayRemove(object) {
            try objectStore.remove(hash: object)
        }
    }
}

// MARK: - CacheStore

/// The index in memory is a `CacheStore`, so B-148's trim — written once in `SemelCache` —
/// runs over it as it runs over the engine's rows, and needs no query to do it. Every change
/// it makes is queued for the log as it is made.
extension CacheServerStore: CacheStore {

    public func content(hash: String) throws -> Data? {
        if let pending = indexLock.withLock({ pendingContent[hash]?.content }) {
            return pending
        }
        return try rows.content(hash: hash)
    }

    public func save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject]) throws {
        try indexLock.withLock {
            for object in objects where objectBytes[object.hash] == nil {
                objectBytes[object.hash] = object.bytes
            }
            _ = try record(hash: hash, cost: cost, content: content, objects: objects)
        }
    }

    public func noteUse(hash: String) throws {
        indexLock.withLock {
            guard entries[hash] != nil else {
                return
            }
            stampUse(hash)
        }
    }

    public func delete(hash: String) throws -> Bool {
        indexLock.withLock {
            guard let entry = entries.removeValue(forKey: hash) else {
                return false
            }
            for object in entry.objects {
                release(object)
            }
            pendingContent[hash] = nil
            writer.enqueue(.delete(hash: hash))
            return true
        }
    }

    public func account() throws -> CacheAccount {
        indexLock.withLock {
            CacheAccount(bytes: heldBytes, settle: settle, lastUsingSettle: lastUsingSettle)
        }
    }

    /// As `SQLiteCacheStore.sizes()` works them out from its rows: what each entry alone
    /// holds, and its share, rounded up, of what it holds with others. No node stands on an
    /// entry here, and the server knows no entry's node type.
    public func sizes() throws -> [CacheEntrySize] {
        indexLock.withLock {
            entries.keys.sorted().compactMap { hash in
                guard let entry = entries[hash] else {
                    return nil
                }
                var bytes  = 0
                var shared = 0
                for object in entry.objects {
                    let size  = objectBytes[object] ?? 0
                    let count = holders[object, default: 1]
                    if count == 1 {
                        bytes += size
                    } else {
                        shared += (size + count - 1) / count
                    }
                }
                return CacheEntrySize(hash: hash, nodeType: "", cost: entry.cost, lastUse: entry.lastUse,
                                      bytes: bytes, sharedBytes: shared, heldByNode: false)
            }
        }
    }

    public func objects(ofEntry hash: String) throws -> [DataObjectHash] {
        indexLock.withLock { entries[hash]?.objects ?? [] }
    }
}

// MARK: - The writer

/// One thread that commits what the store queues, in batches: whatever is waiting when it
/// looks, as one transaction. A client putting one entry after another has its next entry
/// prepared while the last commits, so the batches grow with the load and the log is written
/// once per batch, not once per entry. When nothing is waiting it checkpoints the log into
/// the database file, which no request then waits on.
private final class IndexWriter {

    weak var store: CacheServerStore?

    private let rows: SQLiteCacheStore
    private let database: CacheIndexDatabase
    private let condition = NSCondition()

    // Under `condition`.
    private var queued: [CacheIndexOperation] = []
    private var removals: [DataObjectHash] = []
    private var sweepRequested = false
    private(set) var lastQueued: UInt64 = 0
    private var processedThrough: UInt64 = 0
    private var failures: [(through: UInt64, from: UInt64, description: String)] = []
    private var stopping = false
    private var stopped = false
    private var checkpointDue = false
    private var batchesSinceCheckpoint = 0

    /// A log that never finds an idle moment is still checkpointed, after this many batches.
    private static let batchesBetweenCheckpoints = 1_000

    init(rows: SQLiteCacheStore, database: CacheIndexDatabase) {
        self.rows     = rows
        self.database = database
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "semel-cache.writer"
        thread.start()
    }

    /// Queues one write, and says which: what an answer waits for.
    @discardableResult
    func enqueue(_ operation: CacheIndexOperation) -> UInt64 {
        condition.withLock {
            queued.append(operation)
            lastQueued += 1
            condition.signal()
            return lastQueued
        }
    }

    /// Queues an object's file for removal, once the writes before it are in the log.
    func remove(_ object: DataObjectHash) {
        condition.withLock {
            removals.append(object)
            condition.signal()
        }
    }

    func requestSweep() {
        condition.withLock {
            sweepRequested = true
            condition.signal()
        }
    }

    /// Blocks until the write `write` is in the log. The failure that kept it out, or nil.
    func wait(for write: UInt64) -> String? {
        condition.withLock {
            while processedThrough < write && !stopped {
                condition.wait()
            }
            return failures.first { $0.from <= write && write <= $0.through }?.description
        }
    }

    func stop() {
        condition.withLock {
            stopping = true
            condition.signal()
            while !stopped {
                condition.wait()
            }
        }
    }

    private func run() {
        while true {
            condition.lock()
            while queued.isEmpty && removals.isEmpty && !sweepRequested && !checkpointDue && !stopping {
                condition.wait()
            }
            if stopping && queued.isEmpty && removals.isEmpty && !sweepRequested {
                stopped = true
                condition.broadcast()
                condition.unlock()
                try? database.checkpoint()
                return
            }
            let batch          = queued
            let batchRemovals  = removals
            let sweep          = sweepRequested
            let through        = lastQueued
            let from           = processedThrough + 1
            let due            = checkpointDue
            queued.removeAll()
            removals.removeAll()
            sweepRequested = false
            condition.unlock()

            let anything = !batch.isEmpty || !batchRemovals.isEmpty || sweep
            if anything {
                commit(batch, removals: batchRemovals, sweep: sweep, from: from, through: through)
            }
            if due || !anything {
                checkpoint()
            }
        }
    }

    private func commit(_ batch: [CacheIndexOperation], removals batchRemovals: [DataObjectHash], sweep: Bool,
                        from: UInt64, through: UInt64) {
        var failure: String?
        do {
            try rows.apply(batch)
            store?.written(through: through)
            for object in batchRemovals {
                try store?.removeFile(of: object)
            }
            if sweep {
                try store?.sweep()
            }
        } catch {
            failure = "\(error)"
        }
        condition.withLock {
            if let failure {
                failures.append((through: through, from: from, description: failure))
            }
            processedThrough = through
            batchesSinceCheckpoint += 1
            checkpointDue = queued.isEmpty || batchesSinceCheckpoint >= Self.batchesBetweenCheckpoints
            condition.broadcast()
        }
    }

    private func checkpoint() {
        // Best effort: a checkpoint that fails leaves the log longer, and the next one
        // moves it.
        try? database.checkpoint()
        condition.withLock {
            checkpointDue = false
            batchesSinceCheckpoint = 0
        }
    }
}
