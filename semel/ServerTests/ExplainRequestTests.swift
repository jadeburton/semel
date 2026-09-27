//
//  ExplainRequestTests.swift
//  SemelServerTests
//
//  B-91. `explain` against a real engine with its loop running, since the record it reads
//  is the last settle's: a pushed config file, a `ConfigFilter` selecting one prefix of
//  it, and a product publishing what the filter passes on. The file is pushed through the
//  handler, as a client pushes it.
//

@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class ExplainRequestTests: XCTestCase {

    private var engine:  BuildEngine!
    private var handler: RequestHandler!
    private let session = Session()

    private let product = "OutputFile(path: 'output:/cfg/selected', input: ['selected': "
                        + "ConfigFilter(prefix: 'a', input: ['config': StaticFile(path: 'input:/cfg/semel.config').output]).output])"

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-server-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let database = try DatabaseLayer()
        engine  = try BuildEngine(database: database, startProcessingLoop: true)
        BuildEngine.shared = engine
        handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        BuildEngine.shared = nil
        engine  = nil
        handler = nil
        super.tearDown()
    }

    private func respond(_ request: DaemonRequest, body: Data? = nil) -> Response {
        handler.handle(.daemon(request), body: body, session: session).0
    }

    private func push(_ contents: String) {
        XCTAssertEqual(respond(.pushFolder(path: "cfg")), .daemon(.ok))
        _ = respond(.pushFile(path: "cfg/semel.config", mode: 0o644), body: Data(contents.utf8))
        XCTAssertEqual(respond(.wait), .daemon(.ok))
    }

    private func explain(_ fileSystem: FileSystemKind, _ path: String) throws -> Explanation {
        let response = respond(.explain(fileSystem: fileSystem, path: path))
        guard case .daemon(.explain(let explanation)) = response else {
            XCTFail("expected an explain reply, got \(response)")
            throw NSError(domain: "ExplainRequestTests", code: 1)
        }
        return try XCTUnwrap(explanation, "a settle did work, so there is a record")
    }

    /// The product, the filter behind it, and the file the push changed — each with what
    /// it did and the wire that reached it.
    func test_explainWalksFromTheProductToThePushedFile() throws {
        push("a.x=1\n")
        _ = try GraphSpecNode.parse(product).findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        engine.waitUntilIdleBlocking()

        push("a.x=2\n")
        let explanation = try explain(.output, "cfg/selected")

        XCTAssertEqual(explanation.nodes.map(\.outcome), [.computed, .computed, .changed])
        XCTAssertTrue(explanation.nodes[0].label.hasPrefix("OutputFile #"), explanation.nodes[0].label)
        XCTAssertTrue(explanation.nodes[0].label.hasSuffix("'output:/cfg/selected'"), explanation.nodes[0].label)
        XCTAssertTrue(explanation.nodes[1].label.hasPrefix("ConfigFilter #"), explanation.nodes[1].label)
        XCTAssertTrue(explanation.nodes[2].label.hasSuffix("'input:/cfg/semel.config'"), explanation.nodes[2].label)
        XCTAssertEqual(explanation.nodes[0].causes,
                       [ExplainedCause(port: "input", wire: "selected", change: .changed,
                                       sourceLabel: explanation.nodes[1].label, source: 1)])
        XCTAssertEqual(explanation.nodes[1].causes.map(\.source), [2])
        XCTAssertEqual(explanation.nodes.map(\.isNew), [false, false, false])
        XCTAssertEqual(explanation.omittedNodes, 0)
        XCTAssertEqual(explanation.nodeLimit, SettleExplanation.nodeLimit)
        XCTAssertEqual(explanation.depthLimit, SettleExplanation.depthLimit)
    }

    /// A key outside the selected prefix: the filter runs and passes on what it passed
    /// before, so the product is woken by a wire that brought nothing new — and the walk
    /// still goes up it, to the push that made the filter run.
    func test_aProductWokenByAnUnchangedValueSaysSoAndNamesWhatWokeIt() throws {
        push("a.x=1\nb.y=1\n")
        _ = try GraphSpecNode.parse(product).findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        engine.waitUntilIdleBlocking()

        push("a.x=1\nb.y=2\n")
        let explanation = try explain(.output, "cfg/selected")

        XCTAssertEqual(explanation.nodes.count, 3)
        XCTAssertEqual(explanation.nodes[0].causes.map(\.change), [.unchanged])
        XCTAssertEqual(explanation.nodes[0].causes.map(\.source), [1])
        XCTAssertEqual(explanation.nodes[1].outcome, .computed)
        XCTAssertEqual(explanation.nodes[1].causes.map(\.change), [.changed])
        XCTAssertEqual(explanation.nodes[2].outcome, .changed)
    }

    func test_aPathNotInTheGraphIsAnErrorNamingIt() {
        push("a.x=1\n")

        XCTAssertEqual(respond(.explain(fileSystem: .output, path: "cfg/nothing-here")),
                       .error(.pathNotFound(path: "output:/cfg/nothing-here")))
    }

    /// A server that has settled nothing since it started has no record, and says so
    /// rather than answering as if nothing had touched the node.
    func test_withNoSettleBehindItTheAnswerIsNil() throws {
        let fresh = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = fresh
        let freshHandler = RequestHandler(engine: fresh, database: fresh.database, databasePath: "/tmp/fresh.sqlite")
        defer { BuildEngine.shared = engine }
        _ = freshHandler.handle(.daemon(.pushFile(path: "a.txt", mode: 0o644)), body: Data("a".utf8), session: session)

        let (response, _) = freshHandler.handle(.daemon(.explain(fileSystem: .input, path: "a.txt")), body: nil,
                                                session: session)

        XCTAssertEqual(response, .daemon(.explain(explanation: nil)))
    }
}
