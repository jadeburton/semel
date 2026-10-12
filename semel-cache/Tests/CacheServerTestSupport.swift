// CacheServerTestSupport.swift
// SemelCacheServerTests
//
// A temporary home for each test, removed after it, and the few values every test puts:
// an object with its hash, and an entry's bytes. The entry is opaque to the server, so any
// bytes will do; these are not an engine's encoding and the server never finds out.

import Foundation
import SemelCache
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import XCTest

class CacheServerTestCase: XCTestCase {

    /// A folder of the test's own — XCTest makes an instance per test — under `/tmp`, so a
    /// path in it stays short.
    let homeFolder = URL(fileURLWithPath: "/tmp/semel-cache-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: homeFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: homeFolder)
        // The folder all tests share goes with the last of them: `rmdir` takes only an
        // empty one.
        rmdir(homeFolder.deletingLastPathComponent().path)
        super.tearDown()
    }

    var home: CacheHome {
        CacheHome(folder: homeFolder)
    }

    /// A store over an index in memory and an object store in the test's home.
    func makeStore(limit: ByteCount = ByteCount.gibibytes(1), requestsPerUse: Int = 1_000) throws -> CacheServerStore {
        try CacheServerStore(database: CacheIndexDatabase(),
                             objectStore: DataObjectStore(storeRoot: home.objectsFolder),
                             limit: limit,
                             requestsPerUse: requestsPerUse)
    }

    /// A store over an index on disk in the test's home: one that survives being closed.
    func openStore(limit: ByteCount = ByteCount.gibibytes(1), requestsPerUse: Int = 1_000) throws -> CacheServerStore {
        try CacheServerStore(database: CacheIndexDatabase(filePath: home.indexFile.path),
                             objectStore: DataObjectStore(storeRoot: home.objectsFolder),
                             limit: limit,
                             requestsPerUse: requestsPerUse)
    }

    /// `count` bytes no other call with another `seed` gives, and their hash.
    func object(_ seed: String, count: Int = 100) -> (hash: DataObjectHash, bytes: Data) {
        var bytes = Data("\(seed)\n".utf8)
        if bytes.count < count {
            bytes.append(Data(repeating: UInt8(ascii: "."), count: count - bytes.count))
        }
        let trimmed = Data(bytes.prefix(count))
        return (Sha256.hash(trimmed), trimmed)
    }

    /// The objects an entry holds as the server answers them: by hash, each once, with its
    /// size.
    func held(_ objects: (hash: DataObjectHash, bytes: Data)...) -> [CachedObject] {
        held(objects)
    }

    func held(_ objects: some Sequence<(hash: DataObjectHash, bytes: Data)>) -> [CachedObject] {
        Set(objects.map { CachedObject(hash: $0.hash, bytes: $0.bytes.count) }).sorted { $0.hash < $1.hash }
    }

    /// A key for `seed`, as an engine's would look.
    func key(_ seed: String) -> CacheKey {
        CacheKey(hash: Sha256.hash(Data("key material for \(seed), long enough to be hashed".utf8)))
    }

    /// The bytes of an entry, opaque to the server.
    func entryBytes(_ seed: String) -> Data {
        Data("{\"entry\":\"\(seed)\"}".utf8)
    }
}

/// One connection's worth of a handler, sending as a client would.
final class HandlerClient {
    let handler: CacheRequestHandler
    let session = CacheSession()

    init(store: CacheServerStore, writers: CacheWriters) {
        handler = CacheRequestHandler(store: store, writers: writers)
    }

    @discardableResult
    func hello(wantsWrite: Bool) -> Response {
        handler.handle(.hello(Hello(role: .cache, wantsWrite: wantsWrite)), body: nil, session: session).0
    }

    func send(_ request: CacheRequest, body: Data? = nil) -> (Response, Data?) {
        handler.handle(.cache(request), body: body, session: session)
    }

    func putObject(_ object: (hash: DataObjectHash, bytes: Data)) -> Response {
        send(.putObject(hash: object.hash), body: object.bytes).0
    }

    func putEntry(_ key: CacheKey, cost: Int, objects: [DataObjectHash], bytes: Data) -> Response {
        send(.putEntry(key: key, cost: cost, objects: objects, length: bytes.count), body: bytes).0
    }
}
