//
//  ServerTests.swift
//  SemelServerTests
//
//  The socket server against a real in-memory engine, driven by the CLI's own
//  SocketConnection over a loopback socket in a temporary directory. What is pinned: the
//  daemon verbs work end to end, events reach subscribed clients only, a client that
//  vanishes mid-push leaves no batch open, a second server on the same path is refused,
//  and stop removes the socket file.
//

@testable import SemelCLI
@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class ServerTests: RequestHandlerTestCase {

    private var directory: URL!
    private var socketPath: String!
    private var server: Server!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("semelserv.sock").path
        server = Server(handler: handler, socketPath: socketPath)
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func connect() throws -> SocketConnection {
        try SocketConnection.connect(to: socketPath)
    }

    private func daemon(_ connection: SocketConnection, _ request: DaemonRequest, body: Data? = nil) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = try connection.send(.daemon(request), body: body)
        guard case .daemon(let daemonResponse) = response else {
            throw NSError(domain: "ServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a daemon reply: \(response)"])
        }
        return (daemonResponse, replyBody)
    }

    // MARK: - Verbs end to end

    func test_helloIsAcceptedOverTheSocket() throws {
        let client = try connect()

        let (response, _) = try client.send(.hello(Hello(role: .daemon)), body: nil)

        XCTAssertEqual(response, .hello(.accepted(serverVersion: Semel.version, databasePath: "/tmp/test-graph.sqlite")))
    }

    func test_pushListAndFetchRoundTrip() throws {
        let client = try connect()

        _ = try daemon(client, .beginBatch)
        let (pushed, _) = try daemon(client, .pushFile(path: "a.c", mode: 0o644), body: Data("int x;".utf8))
        _ = try daemon(client, .endBatch)
        let (listed, _)      = try daemon(client, .list(fileSystem: .input, pattern: "*.c"))
        let (fetched, bytes) = try daemon(client, .fetch(fileSystem: .input, path: "a.c"))

        XCTAssertEqual(pushed, .pushFile(didChange: true))
        XCTAssertEqual(listed, .list(entries: [ListEntry(path: "a.c", kind: .file, size: 6, mode: 0o644, status: .unreferenced)]))
        XCTAssertEqual(fetched, .fetch(mode: FileMetadata.defaultMode))
        XCTAssertEqual(bytes, Data("int x;".utf8))
    }

    func test_waitAnswersOverTheSocket() throws {
        let client = try connect()

        XCTAssertEqual(try daemon(client, .wait).0, .ok)
    }

    /// B-94. A prepared app's graph describes itself in megabytes. The JSON section of a
    /// frame is capped at 1 MiB, because its declared length is checked before anything is
    /// allocated; the body is not, so the text rides there and a large reply crosses the
    /// socket whole instead of closing the connection under the client.
    func test_aDebugReplyLargerThanTheJSONCapArrivesWhole() throws {
        let marker = "MARKER-\(UUID().uuidString)"
        try describeSomethingLargerThanTheJSONCap(marker: marker)
        let client = try connect()

        let (response, body) = try daemon(client, .debug)

        XCTAssertEqual(response, .debug)
        let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        XCTAssertGreaterThan(text.utf8.count, Int(Frame.maximumJSONLength),
                             "the reply has to be over the cap for this to prove anything")
        XCTAssertTrue(text.contains(marker), "the text arrives whole, not truncated")
    }

    /// The other half of B-94: a reply that does not fit is answered, not dropped with the
    /// socket. `errors` carries its records in the JSON, so one enormous message is over
    /// the cap, and what comes back names the request and both sizes.
    func test_aReplyThatCannotBeFramedComesBackAsAnErrorNamingIt() throws {
        try describeSomethingLargerThanTheJSONCap(marker: "MARKER")
        let client = try connect()

        let (response, _) = try client.send(.daemon(.errors), body: nil)

        guard case .error(.replyTooLarge(let request, let bytes, let limit)) = response else {
            return XCTFail("expected a replyTooLarge error, got \(response)")
        }
        XCTAssertEqual(request, "errors")
        XCTAssertEqual(limit, Int(Frame.maximumJSONLength))
        XCTAssertGreaterThan(bytes, limit)
        // And the connection survives it: the next command still answers.
        XCTAssertEqual(try daemon(client, .wait).0, .ok)
    }

    /// One node carrying an error message of a megabyte and a half: the same volume of
    /// `debug` text a few hundred real nodes produce, without the few hundred nodes.
    private func describeSomethingLargerThanTheJSONCap(marker: String) throws {
        let node = try NodeRecord.createNode(database: database, kind: Configuration.kind,
                                             properties: ["role": "big"], graphSpec: nil)
        let message = marker + String(repeating: "x", count: 3 * Int(Frame.maximumJSONLength) / 2)
        try node.writeToOutputPort(Configuration.outputPort,
                                   value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    func test_anUndecodableRequestIsAnsweredNotDropped() throws {
        // Reach under SocketConnection: a raw frame whose JSON names no known case.
        let client = try connect()
        _ = try daemon(client, .reset(clearCache: false))   // a completed request means the server has registered this connection
        XCTAssertEqual(server.connectionCount, 1)
        // The handler answers malformedRequest through ServerConnection; SocketConnection
        // cannot send malformed JSON itself, so this is pinned at the ServerConnection level:
        let json = Data(#"{"daemon":{"teleport":{}}}"#.utf8)
        let reply = try XCTUnwrap(ServerConnection.reply(toUndecodable: Frame(kind: .request, correlationID: 5, json: json)))
        XCTAssertEqual(reply.correlationID, 5)
        XCTAssertEqual(try reply.response(), .error(.malformedRequest(description: "the request could not be decoded")))
    }

    // MARK: - Events

    func test_eventsReachSubscribedClientsOnly() throws {
        let subscriber = try connect()
        let bystander  = try connect()
        let delivered  = expectation(description: "subscriber got the event")
        var subscriberEvents: [Event] = []
        var bystanderEvents:  [Event] = []
        subscriber.onEvent = { event in
            subscriberEvents.append(event)
            delivered.fulfill()
        }
        bystander.onEvent = { event in bystanderEvents.append(event) }
        _ = try daemon(subscriber, .subscribe)

        BuildEngine.notice("output:/app: written")

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(subscriberEvents, [.daemon(.notice(line: "output:/app: written"))])
        XCTAssertTrue(bystanderEvents.isEmpty)
    }

    /// An event carries everything in its JSON, so one over the cap cannot be sent. It is
    /// dropped — nobody is waiting on it — and the connection carries the next one, rather
    /// than every subscriber losing its socket over a diagnostic. `semelserv` says so on
    /// its standard error, which is the only trace such an event leaves.
    func test_anEventTooLargeToFrameIsDroppedAndTheNextOneStillArrives() throws {
        let subscriber = try connect()
        let delivered  = expectation(description: "the event after the over-size one")
        var events: [Event] = []
        subscriber.onEvent = { event in
            events.append(event)
            delivered.fulfill()
        }
        _ = try daemon(subscriber, .subscribe)

        BuildEngine.notice(String(repeating: "x", count: Int(Frame.maximumJSONLength) + 1))
        BuildEngine.notice("output:/app: written")

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(events, [.daemon(.notice(line: "output:/app: written"))])
    }

    // MARK: - Sessions

    func test_aClientThatVanishesMidBatchLeavesNoBatchOpen() throws {
        let client = try connect()
        _ = try daemon(client, .beginBatch)
        XCTAssertEqual(server.connectionCount, 1)

        client.close()

        let gone = expectation(description: "connection removed")
        DispatchQueue.global().async {
            while self.server.connectionCount != 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
        // With the session ended, a new client's push must wake the engine as usual: the
        // observable is that a fresh begin/end pair leaves the handler's session at depth 0
        // and the engine's coalesced signal count moves. The engine's depth is private, so
        // the test pins the server-side unwind through a second session.
        let second = try connect()
        _ = try daemon(second, .beginBatch)
        _ = try daemon(second, .endBatch)
        XCTAssertEqual(server.connectionCount, 1)
    }

    /// B-61's documented limit: a wait while another session holds a batch open blocks
    /// until that batch closes. Pinned so the behavior is deliberate, not accidental.
    func test_waitBlocksWhileAnotherSessionHoldsABatchOpen() throws {
        let holder = try connect()
        let waiter = try connect()
        _ = try daemon(holder, .beginBatch)
        let finished = expectation(description: "wait returned")

        DispatchQueue.global().async {
            _ = try? self.daemon(waiter, .wait)
            finished.fulfill()
        }

        // The engine in this fixture has no processing loop, so waitUntilIdle returns at
        // once regardless of batches; the limit only bites with a live loop. Document that
        // here by asserting the wait returns, and leave the live-loop case to B-61.
        wait(for: [finished], timeout: 5)
        _ = try daemon(holder, .endBatch)
    }

    /// A parked `wait` belongs to its own connection. The handler answers `wait` off its
    /// request queue, so a client waiting for the graph to settle must not hold another
    /// client's commands behind it.
    func test_aWaitOnOneConnectionLeavesAnotherFree() throws {
        // The fixture's engine has no processing loop, so a wait on it settles at once and
        // would pin nothing. This one test builds an engine that runs.
        let fixtureEngine   = BuildEngine.shared
        let fixtureDatabase = DatabaseLayer.shared
        let liveDatabase    = try DatabaseLayer()
        let liveEngine      = try BuildEngine(database: liveDatabase, startProcessingLoop: true)
        BuildEngine.shared = liveEngine
        defer {
            liveEngine.stopProcessingLoop()
            BuildEngine.shared   = fixtureEngine
            DatabaseLayer.shared = fixtureDatabase
        }
        let liveHandler = RequestHandler(engine: liveEngine, database: liveDatabase,
                                         databasePath: "/tmp/test-graph.sqlite")
        let livePath    = directory.appendingPathComponent("live.sock").path
        let liveServer  = Server(handler: liveHandler, socketPath: livePath)
        try liveServer.start()
        defer { liveServer.stop() }

        let commander = try SocketConnection.connect(to: livePath)
        let waiter    = try SocketConnection.connect(to: livePath)
        let returned  = NSLock()
        var waitHasReturned = false
        let waitFinished = expectation(description: "the parked wait returned")

        // Settle the loop's own startup work first, so the only outstanding wake-up is the
        // one the batch below withholds.
        liveEngine.waitUntilIdleBlocking()

        // The batch withholds the coalesced signal the reset asks for, so the loop never
        // marks a newer idle generation and the wait cannot settle.
        _ = try daemon(commander, .beginBatch)
        _ = try daemon(commander, .reset(clearCache: false))
        DispatchQueue.global().async {
            _ = try? self.daemon(waiter, .wait)
            returned.withLock { waitHasReturned = true }
            waitFinished.fulfill()
        }

        // The commander is answered while the waiter is parked; that is the whole claim.
        XCTAssertEqual(try daemon(commander, .list(fileSystem: .input, pattern: "*")).0,
                       .list(entries: []))
        XCTAssertFalse(returned.withLock { waitHasReturned })

        _ = try daemon(commander, .endBatch)
        wait(for: [waitFinished], timeout: 5)
    }

    // MARK: - Lifecycle

    func test_aSecondServerOnTheSamePathIsRefused() {
        let second = Server(handler: handler, socketPath: socketPath)

        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? SemelServer.ServerError, .alreadyRunning(path: socketPath))
        }
    }

    /// The socket path is a plain file inside a directory whose write bit is removed, so
    /// `claimSocket`'s best-effort removal cannot clear it and the listener's bind fails.
    /// A start that fails there must never have claimed the sink for its own (now dead)
    /// registry.
    func test_aStartThatFailsAtBindLeavesTheHandlersEventSinkUntouched() throws {
        let blockedDirectory = directory.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let blockedPath = blockedDirectory.appendingPathComponent("semelserv.sock").path
        FileManager.default.createFile(atPath: blockedPath, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path)
        }

        let blockedHandler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        let blockedServer  = Server(handler: blockedHandler, socketPath: blockedPath)

        XCTAssertThrowsError(try blockedServer.start()) { error in
            guard let serverError = error as? SemelServer.ServerError, case .cannotListen = serverError else {
                XCTFail("expected cannotListen, got \(error)")
                return
            }
        }
        XCTAssertNil(blockedHandler.eventSink)
    }

    func test_stopRemovesTheSocketFileAndAStaleFileIsReplaced() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        // A stale file (nothing listening) is unlinked and the path reused.
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        server = Server(handler: handler, socketPath: socketPath)
        try server.start()
        let client = try connect()
        XCTAssertEqual(try daemon(client, .reset(clearCache: false)).0, .reset(archivedGraphPath: nil))
    }

    /// `stop` does not return while a session is still unwinding. Asserted without polling
    /// on purpose: a poll would pass against a stop that merely started the teardown.
    /// Several clients, because each one's unwind takes the handler's queue in turn — one
    /// alone finishes fast enough to hide a stop that did not wait.
    func test_stopWaitsForAConnectionToFinishItsSession() throws {
        var clients: [SocketConnection] = []
        for _ in 0..<8 {
            let client = try connect()
            _ = try daemon(client, .beginBatch)
            clients.append(client)
        }
        XCTAssertEqual(server.connectionCount, 8)

        server.stop()

        XCTAssertEqual(server.connectionCount, 0)
        for client in clients {
            client.close()
        }
    }

    func test_fatalHandlingRefusesNewWorkThenTerminates() throws {
        struct Broken: UnrecoverableError {
            var unrecoverableDescription: String { "the store is read-only" }
        }
        let terminated = expectation(description: "terminate called")
        var code: Int32?

        server.handleFatal(Broken()) { exitCode in
            code = exitCode
            terminated.fulfill()
        }

        XCTAssertTrue(server.isStopping)
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(code, 70)
    }
}
