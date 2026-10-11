// CacheRoleMessageTests.swift
// SemelProtocolTests
//
// The cache role's messages (B-153): representative ones as exact text, every case by round
// trip, and the hello a cache reads `wantsWrite` from, which has to decode from a peer that
// never sent one.

@testable import SemelProtocol
import SemelCache
import SemelNodeKit
import XCTest

final class CacheRoleMessageTests: XCTestCase {

    private let key = CacheKey(hash: String(repeating: "a", count: 64))

    // MARK: - Hello

    func test_aHelloSaysWhetherItMeansToWrite() throws {
        XCTAssertEqual(try json(Hello(protocolVersion: 30, role: .cache, wantsWrite: true)),
                       #"{"protocolVersion":30,"role":"cache","wantsWrite":true}"#)
        XCTAssertFalse(Hello(role: .cache).wantsWrite, "a client writes only when it says so")
        XCTAssertTrue(Hello(role: .cache, wantsWrite: true).wantsWrite)
    }

    /// The name an engine gives itself (`cache.identity`), and none when its home names none:
    /// the key is then absent, as an older peer's hello has it.
    func test_aHelloCarriesTheIdentityTheClientGivesWhenItGivesOne() throws {
        XCTAssertEqual(try json(Hello(protocolVersion: 30, role: .cache, wantsWrite: true, identity: "ci")),
                       #"{"identity":"ci","protocolVersion":30,"role":"cache","wantsWrite":true}"#)
        XCTAssertEqual(try roundTrip(Hello(role: .cache, wantsWrite: true, identity: "jade-laptop")).identity, "jade-laptop")
        XCTAssertNil(try MessageCoder.decode(Hello.self, from: Data(#"{"protocolVersion":30,"role":"cache"}"#.utf8)).identity)
    }

    /// An older peer sends no `wantsWrite`; its hello still decodes, so the server can tell
    /// it the versions differ rather than that its hello was malformed.
    func test_aHelloWithoutWantsWriteDecodesAsReadOnly() throws {
        let hello = try MessageCoder.decode(Hello.self, from: Data(#"{"protocolVersion":27,"role":"cache"}"#.utf8))

        XCTAssertEqual(hello, Hello(protocolVersion: 27, role: .cache, wantsWrite: false))
    }

    func test_aCacheAcceptsWithTheAccessItGrants() throws {
        XCTAssertEqual(try json(HelloResponse.cacheAccepted(access: .readOnly)),
                       #"{"cacheAccepted":{"access":"readOnly"}}"#)
        for access in [CacheAccess.readWrite, .readOnly] {
            XCTAssertEqual(try roundTrip(Response.hello(.cacheAccepted(access: access))),
                           .hello(.cacheAccepted(access: access)))
        }
    }

    // MARK: - Requests

    func test_encodesAKeyAsItsHexUnderTheCacheRole() throws {
        XCTAssertEqual(try json(Request.cache(.getEntry(key: key))),
                       #"{"cache":{"getEntry":{"key":"\#(key.hash)"}}}"#)
    }

    /// What the server files an entry by travels as fields; the entry itself does not
    /// appear in the JSON at all.
    func test_encodesAPutEntryAsItsFieldsWithoutTheEntry() throws {
        let request = Request.cache(.putEntry(key: key, cost: 900, objects: ["0a0b", "ff"], length: 512))

        XCTAssertEqual(try json(request),
                       #"{"cache":{"putEntry":{"cost":900,"key":"\#(key.hash)","length":512,"objects":["0a0b","ff"]}}}"#)
    }

    func test_roundTripsEveryCacheRequest() throws {
        let requests: [CacheRequest] = [
            .getEntry(key: key),
            .putEntry(key: key, cost: 12, objects: ["0a"], length: 3),
            .hasObjects(hashes: ["0a", "0b"]),
            .getObject(hash: "0a"),
            .putObject(hash: "0a"),
            .status,
            .purge(key: key),
            .purgeAll,
        ]
        for request in requests {
            XCTAssertEqual(try roundTrip(Request.cache(request)), .cache(request))
        }
    }

    func test_whatWritesIsSaidPerCase() {
        XCTAssertEqual([CacheRequest.putEntry(key: key, cost: 1, objects: [], length: 0), .putObject(hash: "0a"),
                        .purge(key: key), .purgeAll].filter(\.writes).count, 4)
        XCTAssertEqual([CacheRequest.getEntry(key: key), .hasObjects(hashes: []), .getObject(hash: "0a"), .status]
                        .filter(\.writes).count, 0)
    }

    // MARK: - Responses

    /// A hit carries what the client weighs a fetch by: the build's cost and every object the
    /// entry holds with its size.
    func test_encodesAHitAsItsCostAndItsObjects() throws {
        XCTAssertEqual(try json(Response.cache(.entry(cost: 900, objects: [CachedObject(hash: "0a0b", bytes: 512)]))),
                       #"{"cache":{"entry":{"cost":900,"objects":[{"bytes":512,"hash":"0a0b"}]}}}"#)
    }

    func test_encodesAHashMismatchNamingBothHashes() throws {
        XCTAssertEqual(try json(CacheResponse.refused(reason: .hashMismatch(declared: "0a", actual: "0b"))),
                       #"{"refused":{"reason":{"hashMismatch":{"actual":"0b","declared":"0a"}}}}"#)
    }

    func test_roundTripsEveryCacheResponse() throws {
        let status = CacheServerStatus(entries: 3, bytes: ByteCount(bytes: 4_096), limit: ByteCount.gibibytes(10),
                                       hits: 7, misses: 2)
        let responses: [CacheResponse] = [
            .entry(cost: 900, objects: [CachedObject(hash: "0a", bytes: 1)]),
            .miss,
            .stored,
            .missingObjects(hashes: ["0a"]),
            .object,
            .status(status),
            .purged(entries: 2),
            .refused(reason: .helloRequired),
            .refused(reason: .readOnly),
            .refused(reason: .hashMismatch(declared: "0a", actual: "0b")),
            .refused(reason: .lengthMismatch(declared: 10, received: 9)),
            .refused(reason: .objectsMissing(hashes: ["0a"])),
            .refused(reason: .notAnObjectHash(hash: "../x")),
        ]
        for response in responses {
            XCTAssertEqual(try roundTrip(Response.cache(response)), .cache(response))
        }
    }

    /// A cache reply is one frame, always: its bytes go in the body, whatever their size.
    func test_noCacheReplyStreams() {
        XCTAssertFalse(Response.cache(.miss).mayStream)
        XCTAssertFalse(Response.cache(.entry(cost: 1, objects: [])).mayStream)
    }

    // MARK: - Helpers

    private func json<Message: Encodable>(_ message: Message) throws -> String {
        String(decoding: try MessageCoder.encode(message), as: UTF8.self)
    }

    private func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try MessageCoder.decode(Message.self, from: try MessageCoder.encode(message))
    }
}
