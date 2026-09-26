//
//  InProcessConnectionTests.swift
//  SemelServerTests
//
//  The pretend socket. It must put every message through the real codec — the point of
//  running one process in phase 2 is that the wire is exercised by every CLI test before
//  a socket exists — and it must let several threads have requests outstanding at once.
//

@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class InProcessConnectionTests: RequestHandlerTestCase {

    private var connection: InProcessConnection!

    override func setUpWithError() throws {
        try super.setUpWithError()
        connection = InProcessConnection(handler: handler)
    }

    override func tearDown() {
        connection = nil
        super.tearDown()
    }

    func test_aRequestGetsItsReplyAndBodyThroughTheCodec() throws {
        _ = try connection.send(.daemon(.pushFile(path: "a.c", mode: 0o644)), body: Data("hi".utf8))

        let (response, body) = try connection.send(.daemon(.fetch(fileSystem: .input, path: "a.c")), body: nil)

        XCTAssertEqual(response, .daemon(.fetch(mode: FileMetadata.defaultMode)))
        XCTAssertEqual(body, Data("hi".utf8))
    }

    func test_helloIsAnsweredLikeAnyRequest() throws {
        let (response, _) = try connection.send(.hello(Hello(role: .daemon)), body: nil)

        XCTAssertEqual(response, .hello(.accepted(serverVersion: Semel.version, databasePath: "/tmp/test-graph.sqlite")))
    }

    func test_eventsReachOnEventOnlyAfterSubscribing() throws {
        var received: [Event] = []
        connection.onEvent = { received.append($0) }

        BuildEngine.notice("before")
        _ = try connection.send(.daemon(.subscribe), body: nil)
        BuildEngine.notice("after")

        XCTAssertEqual(received, [.daemon(.notice(line: "after"))])
    }

    /// Two threads, each sending its own kind of request repeatedly, must each get only
    /// its own kind of reply back. The handler is serial; the connection must still keep
    /// callers apart.
    func test_interleavedSendsFromSeparateThreadsGetTheirOwnReplies() throws {
        let group = DispatchGroup()
        let lock  = NSLock()
        var mismatches = 0

        for kind in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for _ in 0..<50 {
                    let request: Request = kind == 0 ? .daemon(.tools(platform: "macos")) : .daemon(.debug(cacheKey: nil))
                    guard let (response, _) = try? self.connection.send(request, body: nil) else {
                        lock.withLock { mismatches += 1 }
                        continue
                    }
                    let matches: Bool
                    switch (kind, response) {
                    case (0, .daemon(.tools)): matches = true
                    case (1, .daemon(.debug)): matches = true
                    default:                   matches = false
                    }
                    if !matches {
                        lock.withLock { mismatches += 1 }
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(mismatches, 0)
    }
}
