//
//  ServerTestSupport.swift
//  SemelServerTests
//
//  A real in-memory engine behind a real handler. The only boundary faked anywhere in
//  these tests is the object store, redirected to a temporary directory so a test can
//  never write into the user's real one.
//

@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

/// Records every event the handler delivers.
final class RecordingSink: EventSink {
    private(set) var events: [Event] = []

    func deliver(_ event: Event) {
        events.append(event)
    }
}

/// Records the parts of a streamed reply as the handler sends them (B-137).
final class PartRecorder: ReplyStream {
    private(set) var parts: [Response] = []

    func send(part: Response) throws {
        parts.append(part)
    }
}

extension RequestHandler {

    /// The whole answer as one value, its parts joined in order: what a client asking for
    /// the whole reply gets. Parts that do not join are a malformed reply.
    func handle(_ request: Request, body: Data?, session: Session) -> (Response, Data?) {
        let recorder = PartRecorder()
        let (last, replyBody) = handle(request, body: body, session: session, replyStream: recorder)
        var parts = ReplyParts()
        do {
            for part in recorder.parts {
                try parts.append(part)
            }
            return (try parts.whole(endingWith: last), replyBody)
        } catch {
            return (.error(.malformedRequest(description: "\(error)")), replyBody)
        }
    }
}

class RequestHandlerTestCase: XCTestCase {

    var engine:   BuildEngine!
    var database: DatabaseLayer!
    var handler:  RequestHandler!
    var session:  Session!
    var sink:     RecordingSink!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-server-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        database = try DatabaseLayer()
        engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        sink     = RecordingSink()
        handler.eventSink = sink
        session  = Session()
    }

    override func tearDown() {
        BuildEngine.shared = nil
        handler  = nil
        engine   = nil
        database = nil
        session  = nil
        sink     = nil
        super.tearDown()
    }

    /// Sends a daemon request and unwraps the daemon reply; fails the test on anything else.
    @discardableResult
    func daemon(_ request: DaemonRequest, body: Data? = nil,
                file: StaticString = #filePath, line: UInt = #line) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = handler.handle(.daemon(request), body: body, session: session)
        guard case .daemon(let daemonResponse) = response else {
            XCTFail("expected a daemon response, got \(response)", file: file, line: line)
            throw NSError(domain: "RequestHandlerTestCase", code: 1)
        }
        return (daemonResponse, replyBody)
    }

    /// The parts a daemon request's reply streamed, and its last frame, as the handler
    /// sent them.
    func daemonInParts(_ request: DaemonRequest) -> (parts: [Response], last: Response) {
        let recorder = PartRecorder()
        let (last, _) = handler.handle(.daemon(request), body: nil, session: session, replyStream: recorder)
        return (recorder.parts, last)
    }

    /// Pushes enough files below `many/` that a reply naming every one of them is over the
    /// JSON section's cap: a name of four kilobytes each, and more of them than a megabyte holds.
    /// Returns their paths in the order a listing gives them, which the zero-padded index
    /// makes name order.
    @discardableResult
    func pushFilesTooManyToNameInOneFrame() throws -> [String] {
        let padding = String(repeating: "x", count: 4_000)
        let count   = Int(Frame.maximumJSONLength) / padding.count + 40
        let paths   = (0..<count).map { "many/\(String(format: "%05d", $0))-\(padding).c" }
        try daemon(.beginBatch)
        for path in paths {
            try daemon(.pushFile(path: path, mode: 0o644), body: Data("int x;".utf8))
        }
        try daemon(.endBatch)
        return paths
    }

    /// Sends a daemon request and expects an error reply.
    func daemonError(_ request: DaemonRequest, body: Data? = nil,
                     file: StaticString = #filePath, line: UInt = #line) -> ErrorResponse? {
        let (response, _) = handler.handle(.daemon(request), body: body, session: session)
        guard case .error(let error) = response else {
            XCTFail("expected an error response, got \(response)", file: file, line: line)
            return nil
        }
        return error
    }
}
