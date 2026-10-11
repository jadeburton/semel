// CacheRequestHandlerTests.swift
// SemelCacheServerTests
//
// The cache's protocol handlers with no socket: an index in memory, objects in a test's
// home, and a client that is a session and a handler. Each request kind, each refusal,
// eviction at the limit and purge.

import Foundation
import SemelCache
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import XCTest

final class CacheRequestHandlerTests: CacheServerTestCase {

    // MARK: - Hello

    func test_aClientThatAsksToWriteMayWhenEveryoneMay() throws {
        let store = try makeStore()
        defer { store.close() }

        XCTAssertEqual(HandlerClient(store: store, writers: .all).hello(wantsWrite: true), .hello(.cacheAccepted(access: .readWrite)))
        XCTAssertEqual(HandlerClient(store: store, writers: .all).hello(wantsWrite: false), .hello(.cacheAccepted(access: .readOnly)))
        XCTAssertEqual(HandlerClient(store: store, writers: .none).hello(wantsWrite: true), .hello(.cacheAccepted(access: .readOnly)))
    }

    func test_aHelloOfAnotherVersionOrRoleIsRejectedByName() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)

        let (older, _) = client.handler.handle(.hello(Hello(protocolVersion: 27, role: .cache)), body: nil, session: client.session)
        XCTAssertEqual(older, .hello(.rejected(reason: .versionMismatch(client: 27, server: ProtocolVersion.current))))
        let (daemon, _) = client.handler.handle(.hello(Hello(role: .daemon)), body: nil, session: client.session)
        XCTAssertEqual(daemon, .hello(.rejected(reason: .roleNotOffered(role: .daemon))))
        XCTAssertEqual(client.send(.status).0, .cache(.refused(reason: .helloRequired)), "a rejected hello grants nothing")
    }

    func test_aDaemonRequestIsRefusedByRole() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)

        XCTAssertEqual(client.handler.handle(.daemon(.collect), body: nil, session: client.session).0,
                       .error(.roleNotOffered(role: .daemon)))
    }

    func test_nothingIsAnsweredBeforeAHello() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)

        XCTAssertEqual(client.send(.getEntry(key: key("a"))).0, .cache(.refused(reason: .helloRequired)))
    }

    // MARK: - Entries

    func test_aKeyNothingIsFiledUnderIsAMiss() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .none)
        client.hello(wantsWrite: false)

        XCTAssertEqual(client.send(.getEntry(key: key("a"))).0, .cache(.miss))
        XCTAssertEqual(store.status().misses, 1)
    }

    func test_anEntryPutIsAHitWithItsBytesAndItsCost() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let first = object("first")
        let second = object("second")
        XCTAssertEqual(client.putObject(first), .cache(.stored))
        XCTAssertEqual(client.putObject(second), .cache(.stored))

        XCTAssertEqual(client.putEntry(key("a"), cost: 900, objects: [first.hash, second.hash], bytes: entryBytes("a")),
                       .cache(.stored))

        let (reply, body) = client.send(.getEntry(key: key("a")))
        XCTAssertEqual(reply, .cache(.entry(cost: 900)))
        XCTAssertEqual(body, entryBytes("a"), "the bytes come back as they were put, unread")
        XCTAssertEqual(store.status().hits, 1)
        XCTAssertEqual(store.status().entries, 1)
        XCTAssertEqual(store.status().bytes, ByteCount(bytes: first.bytes.count + second.bytes.count))
    }

    func test_anEntryReferencingObjectsTheServerLacksIsRefusedNamingThem() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let held = object("held")
        let absent = object("absent")
        _ = client.putObject(held)

        XCTAssertEqual(client.putEntry(key("a"), cost: 1, objects: [held.hash, absent.hash], bytes: entryBytes("a")),
                       .cache(.refused(reason: .objectsMissing(hashes: [absent.hash]))))
        XCTAssertEqual(client.send(.getEntry(key: key("a"))).0, .cache(.miss))
    }

    func test_anEntryWhoseBodyIsNotTheLengthItSaysIsRefused() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)

        let (reply, _) = client.send(.putEntry(key: key("a"), cost: 1, objects: [], length: 99), body: entryBytes("a"))

        XCTAssertEqual(reply, .cache(.refused(reason: .lengthMismatch(declared: 99, received: entryBytes("a").count))))
    }

    /// The two tiers evict apart in a store that loses an object — a file removed by hand,
    /// or a crash between the two — and a hit the client could not complete is no hit. The
    /// store drops such an entry when it opens.
    func test_aHitWhoseObjectsAreMissingIsAMiss() throws {
        let only = object("only")
        do {
            let store = try openStore()
            let client = HandlerClient(store: store, writers: .all)
            client.hello(wantsWrite: true)
            _ = client.putObject(only)
            _ = client.putEntry(key("a"), cost: 1, objects: [only.hash], bytes: entryBytes("a"))
            store.close()
        }
        try FileManager.default.removeItem(at: DataObjectStore(storeRoot: home.objectsFolder).objectURL(hash: only.hash))

        let reopened = try openStore()
        defer { reopened.close() }
        let client = HandlerClient(store: reopened, writers: .none)
        client.hello(wantsWrite: false)

        XCTAssertEqual(client.send(.getEntry(key: key("a"))).0, .cache(.miss))
        XCTAssertEqual(reopened.status().entries, 0)
    }

    func test_whatIsPutSurvivesTheStoreClosing() throws {
        let kept = object("kept")
        do {
            let store = try openStore()
            let client = HandlerClient(store: store, writers: .all)
            client.hello(wantsWrite: true)
            _ = client.putObject(kept)
            _ = client.putEntry(key("a"), cost: 40, objects: [kept.hash], bytes: entryBytes("a"))
            store.close()
        }

        let reopened = try openStore()
        defer { reopened.close() }
        let client = HandlerClient(store: reopened, writers: .none)
        client.hello(wantsWrite: false)

        let (reply, body) = client.send(.getEntry(key: key("a")))
        XCTAssertEqual(reply, .cache(.entry(cost: 40)))
        XCTAssertEqual(body, entryBytes("a"))
        XCTAssertEqual(client.send(.hasObjects(hashes: [kept.hash])).0, .cache(.missingObjects(hashes: [])))
    }

    /// An object put for an entry that never came holds nothing and nobody can reach it:
    /// the store removes it when it opens, before any client is in the middle of a put.
    func test_anObjectNoEntryHoldsIsRemovedWhenTheStoreOpens() throws {
        let orphan = object("orphan")
        do {
            let store = try openStore()
            let client = HandlerClient(store: store, writers: .all)
            client.hello(wantsWrite: true)
            _ = client.putObject(orphan)
            store.close()
        }

        let reopened = try openStore()
        defer { reopened.close() }

        XCTAssertFalse(DataObjectStore(storeRoot: home.objectsFolder).exists(hash: orphan.hash))
    }

    // MARK: - Objects

    func test_anObjectPutIsGotBackByItsHash() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let megabyte = object("large", count: 1_048_576)

        XCTAssertEqual(client.putObject(megabyte), .cache(.stored))

        let (reply, body) = client.send(.getObject(hash: megabyte.hash))
        XCTAssertEqual(reply, .cache(.object))
        XCTAssertEqual(body, megabyte.bytes)
        XCTAssertEqual(client.send(.getObject(hash: object("never").hash)).0, .cache(.miss))
    }

    /// The hash is a claim about the bytes, and the server checks it: a body that hashes to
    /// something else is refused naming both, and nothing is filed.
    func test_anObjectWhoseBytesDoNotHashToItsNameIsRefusedNamingBoth() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let claimed = object("claimed")
        let sent = object("sent")

        let (reply, _) = client.send(.putObject(hash: claimed.hash), body: sent.bytes)

        XCTAssertEqual(reply, .cache(.refused(reason: .hashMismatch(declared: claimed.hash, actual: sent.hash))))
        XCTAssertEqual(client.send(.hasObjects(hashes: [claimed.hash])).0, .cache(.missingObjects(hashes: [claimed.hash])))
    }

    func test_hasObjectsAnswersTheMissingOnesInTheOrderAsked() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let held = object("held")
        let first = object("first")
        let second = object("second")
        _ = client.putObject(held)

        XCTAssertEqual(client.send(.hasObjects(hashes: [second.hash, held.hash, "", first.hash])).0,
                       .cache(.missingObjects(hashes: [second.hash, first.hash])),
                       "the empty object is in every store")
    }

    /// A hash names a file in the store, so one that could name anything else is refused
    /// before it is used.
    func test_aHashThatIsNotOneTheStoreFilesUnderIsRefused() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)

        XCTAssertEqual(client.send(.getObject(hash: "../../etc/passwd")).0,
                       .cache(.refused(reason: .notAnObjectHash(hash: "../../etc/passwd"))))
        XCTAssertEqual(client.send(.hasObjects(hashes: ["ABCD"])).0, .cache(.refused(reason: .notAnObjectHash(hash: "ABCD"))))
        XCTAssertEqual(client.putEntry(key("a"), cost: 1, objects: ["abc"], bytes: entryBytes("a")),
                       .cache(.refused(reason: .notAnObjectHash(hash: "abc"))))
    }

    // MARK: - Read-only

    func test_aReadOnlyClientIsRefusedEveryWrite() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .none)
        client.hello(wantsWrite: true)
        let bytes = object("bytes")

        XCTAssertEqual(client.putObject(bytes), .cache(.refused(reason: .readOnly)))
        XCTAssertEqual(client.putEntry(key("a"), cost: 1, objects: [], bytes: entryBytes("a")), .cache(.refused(reason: .readOnly)))
        XCTAssertEqual(client.send(.purge(key: key("a"))).0, .cache(.refused(reason: .readOnly)))
        XCTAssertEqual(client.send(.purgeAll).0, .cache(.refused(reason: .readOnly)))
        XCTAssertEqual(client.send(.hasObjects(hashes: [bytes.hash])).0, .cache(.missingObjects(hashes: [bytes.hash])),
                       "nothing was filed")
        XCTAssertEqual(client.send(.status).0, .cache(.status(store.status())), "reading is still allowed")
    }

    // MARK: - Eviction

    /// B-148's order, with uses counted in requests: an entry used in the last use is kept
    /// over every one that was not, and among the rest the cheapest build per byte goes
    /// first. The store trims to nine tenths of its limit, so one put over it does not leave
    /// the next one over it too.
    func test_atTheLimitTheCheapestBuildPerByteGoesFirstAndARecentUseIsKept() throws {
        let store = try makeStore(limit: ByteCount(bytes: 1_000), requestsPerUse: 3)
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let cheap     = object("cheap", count: 300)
        let costly    = object("costly", count: 300)
        let recent    = object("recent", count: 300)
        let newcomer  = object("newcomer", count: 300)
        for item in [cheap, costly, recent, newcomer] {
            _ = client.putObject(item)
        }
        _ = client.putEntry(key("cheap"), cost: 10, objects: [cheap.hash], bytes: entryBytes("cheap"))
        _ = client.putEntry(key("costly"), cost: 5_000, objects: [costly.hash], bytes: entryBytes("costly"))
        _ = client.putEntry(key("recent"), cost: 1, objects: [recent.hash], bytes: entryBytes("recent"))
        // Three entry requests make a use: the puts were one, and these hits are the next,
        // which leaves `recent` the one entry the last use touched.
        for _ in 0..<3 {
            XCTAssertEqual(client.send(.getEntry(key: key("recent"))).0, .cache(.entry(cost: 1)))
        }

        XCTAssertEqual(client.putEntry(key("newcomer"), cost: 100, objects: [newcomer.hash], bytes: entryBytes("newcomer")),
                       .cache(.stored))

        XCTAssertEqual(client.send(.getEntry(key: key("cheap"))).0, .cache(.miss), "the cheapest per byte went")
        XCTAssertEqual(client.send(.getEntry(key: key("costly"))).0, .cache(.entry(cost: 5_000)))
        XCTAssertEqual(client.send(.getEntry(key: key("recent"))).0, .cache(.entry(cost: 1)),
                       "the cheapest of all, but used by the last use")
        XCTAssertEqual(client.send(.hasObjects(hashes: [cheap.hash])).0, .cache(.missingObjects(hashes: [cheap.hash])),
                       "an evicted entry's objects leave with it")
        XCTAssertLessThanOrEqual(store.status().bytes.bytes, 1_000)
    }

    /// The index in memory and the rows behind it keep one account: the sizes and the total
    /// eviction reads from memory are the ones the rows give once written.
    func test_theIndexInMemoryAccountsAsTheRowsDo() throws {
        let store = try openStore()
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let shared = object("shared", count: 301)
        let alone  = object("alone", count: 200)
        let other  = object("other", count: 50)
        for item in [shared, alone, other] {
            _ = client.putObject(item)
        }
        _ = client.putEntry(key("a"), cost: 10, objects: [shared.hash, alone.hash], bytes: entryBytes("a"))
        _ = client.putEntry(key("b"), cost: 20, objects: [shared.hash], bytes: entryBytes("b"))
        _ = client.putEntry(key("c"), cost: 30, objects: [other.hash], bytes: entryBytes("c"))
        _ = client.putEntry(key("c"), cost: 31, objects: [shared.hash], bytes: entryBytes("c2"))
        _ = client.send(.getEntry(key: key("b")))
        _ = client.send(.purge(key: key("a")))
        let inMemory = (sizes: try store.sizes(), account: try store.account())
        store.close()

        let database = try CacheIndexDatabase(filePath: home.indexFile.path)
        let rows = SQLiteCacheStore(database: database)
        try withExtendedLifetime(database) {
            XCTAssertEqual(try rows.sizes(), inMemory.sizes)
            XCTAssertEqual(try rows.account(), inMemory.account)
            XCTAssertEqual(try rows.bytesByObjectRows(), inMemory.account.bytes)
        }
    }

    // MARK: - Purge

    func test_purgeRemovesOneEntryAndTheObjectsOnlyItHeld() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let shared = object("shared")
        let own    = object("own")
        _ = client.putObject(shared)
        _ = client.putObject(own)
        _ = client.putEntry(key("poisoned"), cost: 1, objects: [shared.hash, own.hash], bytes: entryBytes("poisoned"))
        _ = client.putEntry(key("good"), cost: 1, objects: [shared.hash], bytes: entryBytes("good"))

        XCTAssertEqual(client.send(.purge(key: key("poisoned"))).0, .cache(.purged(entries: 1)))
        XCTAssertEqual(client.send(.purge(key: key("poisoned"))).0, .cache(.purged(entries: 0)))

        XCTAssertEqual(client.send(.getEntry(key: key("poisoned"))).0, .cache(.miss))
        XCTAssertEqual(client.send(.getEntry(key: key("good"))).0, .cache(.entry(cost: 1)))
        XCTAssertEqual(client.send(.hasObjects(hashes: [shared.hash, own.hash])).0, .cache(.missingObjects(hashes: [own.hash])))
    }

    func test_purgeAllRemovesEveryEntryAndEveryObject() throws {
        let store = try makeStore()
        defer { store.close() }
        let client = HandlerClient(store: store, writers: .all)
        client.hello(wantsWrite: true)
        let held   = object("held")
        let loose  = object("loose")
        _ = client.putObject(held)
        _ = client.putObject(loose)
        _ = client.putEntry(key("a"), cost: 1, objects: [held.hash], bytes: entryBytes("a"))

        XCTAssertEqual(client.send(.purgeAll).0, .cache(.purged(entries: 1)))

        XCTAssertEqual(client.send(.getEntry(key: key("a"))).0, .cache(.miss))
        XCTAssertEqual(client.send(.hasObjects(hashes: [held.hash, loose.hash])).0,
                       .cache(.missingObjects(hashes: [held.hash, loose.hash])))
        XCTAssertEqual(DataObjectStore(storeRoot: home.objectsFolder).objects(), [], "the files went too")
        XCTAssertEqual(store.status().bytes, ByteCount(bytes: 0))
    }
}
