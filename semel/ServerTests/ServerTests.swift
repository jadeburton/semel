//
//  ServerTests.swift
//  SemelServerTests
//
//  The socket server against a real in-memory engine, driven by the CLI's own
//  SocketConnection over a loopback socket in a temporary directory. What is pinned: the
//  daemon verbs work end to end, events reach subscribed clients only, a client that
//  vanishes mid-push leaves no batch open, a second server on the same path is refused,
//  stop removes the socket file, and removing it stops the server.
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

        let (response, body) = try daemon(client, .debug(cacheKey: nil))

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

    /// The owner's case (B-137): an `rm` of more paths than one frame's JSON can name. The
    /// reply streams, and the client's whole-reply `send` hands back every path, in order.
    func test_aRemoveOfMorePathsThanOneFrameHoldsArrivesWholeOverTheSocket() throws {
        let paths  = try pushFilesTooManyToNameInOneFrame()
        let client = try connect()

        let (response, _) = try daemon(client, .remove(pattern: "many/*"))

        // Compared, not asserted equal: a failure would print a megabyte of paths.
        XCTAssertTrue(response == .remove(removedFiles: paths, removedFolders: []), "the reply is not every path, in order")
        // And the connection carries the next request.
        XCTAssertEqual(try daemon(client, .wait).0, .ok)
    }

    /// The parts reach the caller as they arrive, in the order the server sent them, and
    /// the last frame is only what came after them.
    func test_theOtherSendHandsEachPartOverInOrder() throws {
        let paths  = try pushFilesTooManyToNameInOneFrame()
        let client = try connect()
        var parts: [[String]] = []

        let (last, _) = try client.send(.daemon(.remove(pattern: "many/*")), body: nil) { part in
            guard case .daemon(.remove(let files, _)) = part else {
                return XCTFail("a part that is not a removal: \(part)")
            }
            parts.append(files)
        }

        guard case .daemon(.remove(let lastFiles, _)) = last else {
            return XCTFail("the last frame is not a removal: \(last)")
        }
        XCTAssertGreaterThan(parts.count, 0, "a reply over the cap streams")
        XCTAssertTrue(parts.flatMap { $0 } + lastFiles == paths, "the parts and the last are every path, in order")
    }

    /// A reply that fits one frame is one frame: nothing reaches `onPart`.
    func test_aSmallReplyIsOneFrame() throws {
        _ = try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("int a;".utf8))
        let client = try connect()
        var partCount = 0

        let (last, _) = try client.send(.daemon(.remove(pattern: "a.c")), body: nil) { _ in partCount += 1 }

        XCTAssertEqual(partCount, 0)
        XCTAssertEqual(last, .daemon(.remove(removedFiles: ["a.c"], removedFolders: [])))
    }

    /// `ls` of a tree too large for one frame streams as `rm` does.
    func test_aListingOfMorePathsThanOneFrameHoldsArrivesWholeOverTheSocket() throws {
        let paths  = try pushFilesTooManyToNameInOneFrame()
        let client = try connect()

        let (response, _) = try daemon(client, .list(fileSystem: .input, pattern: "many/*"))

        guard case .list(let entries) = response else {
            return XCTFail("expected a listing")
        }
        XCTAssertTrue(entries.map(\.path) == paths, "the listing is not every path, in order")
    }

    /// `errors` on a wide failure cascade: many records, each well under the cap, together
    /// well over it. They stream, and arrive in the order the report puts them.
    func test_errorsOfAWideCascadeArriveWholeOverTheSocket() throws {
        let recordCount = 40
        for index in 0..<recordCount {
            let (node, _) = try GraphSpecNode(SettingsLiteral.self, properties: ["role": "wide\(index)"]).findOrCreateMatchingNode()
            let message = "failure \(index): " + String(repeating: "x", count: Int(Frame.maximumJSONLength) / 20)
            try node.writeToOutputPort(SettingsLiteral.outputPort,
                                       value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
        }
        let expected = daemonInParts(.errors)
        let client   = try connect()
        var partCount = 0

        let (last, _) = try client.send(.daemon(.errors), body: nil) { _ in partCount += 1 }
        let (whole, _) = try daemon(client, .errors)

        guard case .errors(let records) = whole else {
            return XCTFail("expected the error records")
        }
        XCTAssertEqual(records.count, recordCount)
        XCTAssertGreaterThan(partCount, 0, "a report over the cap streams")
        XCTAssertEqual(partCount, expected.parts.count, "the client hears every part the handler sent")
        XCTAssertTrue(last == expected.last, "the last frame is the handler's last slice")
    }

    /// One node carrying an error message of a megabyte and a half: the same volume of
    /// `debug` text a few hundred real nodes produce, without the few hundred nodes.
    private func describeSomethingLargerThanTheJSONCap(marker: String) throws {
        let (node, _) = try GraphSpecNode(SettingsLiteral.self, properties: ["role": "big"]).findOrCreateMatchingNode()
        let message = marker + String(repeating: "x", count: 3 * Int(Frame.maximumJSONLength) / 2)
        try node.writeToOutputPort(SettingsLiteral.outputPort,
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

    // MARK: - Requests in flight

    /// Pushes sent without waiting and a `wait` behind them: the wait is answered from a
    /// thread of its own, but only once the connection has handled the pushes ahead of it,
    /// so by its reply every one of them is recorded — whichever reply is collected first.
    func test_aWaitSentBehindPushesInFlightAnswersAfterTheyAreRecorded() throws {
        try withLiveServer { socketPath, _ in
            let client = try SocketConnection.connect(to: socketPath)
            let pushes = try (0..<3).map { index in
                try client.sendWithoutWaiting(.daemon(.pushFile(path: "p\(index).c", mode: 0o644)), body: Data("\(index)".utf8))
            }
            let waited = try client.sendWithoutWaiting(.daemon(.wait), body: nil)

            XCTAssertEqual(try waited.reply().0, .daemon(.ok))
            let observer = try SocketConnection.connect(to: socketPath)
            guard case .daemon(.list(let entries)) = try observer.send(.daemon(.list(fileSystem: .input, pattern: "*.c")),
                                                                       body: nil).0 else {
                return XCTFail("expected a listing")
            }
            XCTAssertEqual(entries.map(\.path), ["p0.c", "p1.c", "p2.c"])
            for push in pushes {
                XCTAssertEqual(try push.reply().0, .daemon(.pushFile(didChange: true)))
            }
        }
    }

    /// A push of a tree over the socket, several batches in flight, one file in the middle
    /// refused by the graph (it is below `tree/m/k`, which the server holds as a file): the
    /// refusal is reported against that file, and every other file is stored.
    func test_aPushWithBatchesInFlightReportsARefusalAgainstItsFile() throws {
        let disk = directory.appendingPathComponent("disk", isDirectory: true)
        var paths = ["tree/m/k/inner.c"]
        for index in 0..<100 {
            paths.append("tree/a/file\(String(format: "%03d", index)).c")
            paths.append("tree/z/file\(String(format: "%03d", index)).c")
        }
        for path in paths {
            let url = disk.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let client = try connect()
        _ = try daemon(client, .pushFile(path: "tree/m/k", mode: 0o644), body: Data("a file".utf8))

        let interpreter = CommandInterpreter(connection: client, baseDirectory: disk.path)
        var lines: [String] = []
        interpreter.output = { lines.append($0) }
        _ = try interpreter.connect(subscribing: false)
        interpreter.handleCommand("push tree")

        let refusals = lines.filter { $0.hasPrefix("push: ") }
        XCTAssertEqual(refusals.count, 1, "\(lines)")
        XCTAssertTrue(refusals.first?.hasPrefix("push: tree/m/k/inner.c: ") == true, "\(refusals)")
        // Every file but the refused one; how many folders the push names depends on which
        // the earlier push of `tree/m/k` left pinned, which is not what this pins.
        XCTAssertTrue(lines.contains { $0.hasPrefix("Pushed 200 files and ") }, "\(lines)")
        XCTAssertEqual(try daemon(client, .fetch(fileSystem: .input, path: "tree/z/file099.c")).1,
                       Data("tree/z/file099.c".utf8))
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

    /// The fixture's engine has no processing loop, so a wait on it settles at once and
    /// would pin nothing about waiting. This runs `body` against a server over an engine
    /// that runs, with the loop's own startup work already settled, so the only wake-ups
    /// outstanding are the ones the test makes.
    private func withLiveServer(_ body: (_ socketPath: String, _ engine: BuildEngine) throws -> Void) throws {
        let fixtureEngine   = BuildEngine.shared
        let fixtureDatabase = DatabaseLayer.shared
        let liveDatabase    = try DatabaseLayer()
        let liveEngine      = try BuildEngine(database: liveDatabase, startProcessingLoop: false)
        BuildEngine.shared = liveEngine
        liveEngine.startProcessingLoop()
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

        liveEngine.waitUntilIdleBlocking()
        try body(livePath, liveEngine)
    }

    /// B-61's documented limit: a wait while another session holds a batch open blocks
    /// until that batch closes, because the batch's work signal is counted and not sent
    /// until `endBatch`. Fail-safe — a wait never reports a settle that has work still
    /// ahead of it — and pinned so the behaviour is deliberate, not accidental.
    func test_waitBlocksWhileAnotherSessionHoldsABatchOpen() throws {
        try withLiveServer { socketPath, _ in
            let holder = try SocketConnection.connect(to: socketPath)
            let waiter = try SocketConnection.connect(to: socketPath)
            _ = try daemon(holder, .beginBatch)
            _ = try daemon(holder, .pushFile(path: "held.c", mode: 0o644), body: Data("int held;".utf8))

            let parked = expectation(description: "the wait returned while the batch was open")
            parked.isInverted = true
            let released = expectation(description: "the wait returned once the batch closed")
            DispatchQueue.global().async {
                _ = try? self.daemon(waiter, .wait)
                parked.fulfill()
                released.fulfill()
            }

            wait(for: [parked], timeout: 1)
            _ = try daemon(holder, .endBatch)
            wait(for: [released], timeout: 5)
        }
    }

    /// A client that opens a batch and a push without waiting for either and goes at once:
    /// its session is ended behind the requests it sent, not in front of them, so no batch
    /// is left open and another client's wait settles.
    func test_aClientThatGoesWithRequestsInFlightLeavesNoBatchOpen() throws {
        try withLiveServer { socketPath, _ in
            let leaver = try SocketConnection.connect(to: socketPath)
            _ = try leaver.sendWithoutWaiting(.daemon(.beginBatch), body: nil)
            _ = try leaver.sendWithoutWaiting(.daemon(.pushFile(path: "left.c", mode: 0o644)), body: Data("int left;".utf8))
            leaver.close()

            let waiter   = try SocketConnection.connect(to: socketPath)
            let released = expectation(description: "the wait returned")
            DispatchQueue.global().async {
                _ = try? self.daemon(waiter, .wait)
                released.fulfill()
            }
            wait(for: [released], timeout: 5)
        }
    }

    /// A parked `wait` belongs to its own connection. The handler answers `wait` off its
    /// request queue, so a client waiting for the graph to settle must not hold another
    /// client's commands behind it.
    func test_aWaitOnOneConnectionLeavesAnotherFree() throws {
        try withLiveServer { socketPath, _ in
            try aWaitOnOneConnectionLeavesAnotherFree(socketPath: socketPath)
        }
    }

    private func aWaitOnOneConnectionLeavesAnotherFree(socketPath livePath: String) throws {
        let commander = try SocketConnection.connect(to: livePath)
        let waiter    = try SocketConnection.connect(to: livePath)
        let returned  = NSLock()
        var waitHasReturned = false
        let waitFinished = expectation(description: "the parked wait returned")

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

    /// B-73. A client that dies without stopping its server leaves nothing else to end the
    /// process; deleting the socket file does. The hook stands in for the executable's
    /// stop so the terminate that follows runs without ending the test process.
    func test_removingTheSocketFileTerminatesTheServer() throws {
        let terminated = expectation(description: "terminate called")
        var code: Int32?
        server.onSocketFileRemoved = { [server] in
            server?.terminate(code: 0) { exitCode in
                code = exitCode
                terminated.fulfill()
            }
        }

        try FileManager.default.removeItem(atPath: socketPath)

        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(server.isStopping)
    }

    /// A socket file put where the deleted one was belongs to whoever put it there — most
    /// likely a second server started after the first lost its file — so the first stops
    /// without unlinking it.
    func test_aSocketFileReplacedByAnotherIsLeftInPlaceByTheStop() throws {
        let terminated = expectation(description: "terminate called")
        server.onSocketFileRemoved = { [server] in
            server?.terminate(code: 0) { _ in terminated.fulfill() }
        }

        try FileManager.default.removeItem(atPath: socketPath)
        FileManager.default.createFile(atPath: socketPath, contents: Data())

        wait(for: [terminated], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    /// The socket file is there from the bind, a moment before the server watches it, and
    /// a client waiting for it can remove it — or the whole home it is in — inside that
    /// moment. Either way it is gone, and the server stops as though it had been watching.
    func test_aSocketFileRemovedBeforeTheWatchBeginsStillStopsTheServer() throws {
        let removals: [(String, (URL) throws -> Void)] = [
            ("the socket file", { home in try FileManager.default.removeItem(at: home.appendingPathComponent("early.sock")) }),
            ("its directory",   { home in try FileManager.default.removeItem(at: home) }),
        ]
        for (what, remove) in removals {
            let home = directory.appendingPathComponent("early", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let earlyHandler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
            let early = Server(handler: earlyHandler, socketPath: home.appendingPathComponent("early.sock").path)
            let reported = expectation(description: "removal of \(what) reported")
            early.onSocketFileRemoved = { reported.fulfill() }
            early.socketFileWatchWillStart = {
                do {
                    try remove(home)
                } catch {
                    XCTFail("removing \(what): \(error)")
                }
            }

            try early.start()

            wait(for: [reported], timeout: 5)
            early.stop()
            try? FileManager.default.removeItem(at: home)
        }
    }

    /// The server's own stop removes the file too; that removal must not come back as a
    /// second stop.
    func test_stopDoesNotReportItsOwnRemovalOfTheSocketFile() {
        let reported = expectation(description: "socket file removal reported")
        reported.isInverted = true
        server.onSocketFileRemoved = { reported.fulfill() }

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        wait(for: [reported], timeout: 1)
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
