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
