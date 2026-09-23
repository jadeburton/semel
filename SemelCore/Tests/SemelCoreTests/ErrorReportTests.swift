//
//  ErrorReportTests.swift
//  SemelCoreTests
//
//  How a node's errors read.
//
//  Two callers render this — the engine as it settles, and the CLI's `errors` command on
//  request. They differ in which errors they select, never in how those errors look, and
//  these tests are what keeps that true now that both go through one function.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ErrorReportTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var database: DatabaseLayer { engine.database }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func makeNode(kind: UInt, properties: [String: String] = [:]) throws -> ObjectID {
        try NodeRecord.createNode(database: database, kind: kind,
                            properties: properties, graphSpec: nil).requireID()
    }

    private func port(_ nodeID: ObjectID, _ name: String, _ message: String) throws -> OutputPort {
        OutputPort(nodeID: nodeID,
                   nameSymbolID: name.asSymbolID(),
                   valueKind: .error,
                   dataObjectHash: try message.intern())
    }

    // MARK: - Grouping

    /// A node that fails usually fails on every port at once for the same reason. Naming the
    /// ports together says that in one line; a line per port says the same thing three times
    /// and hides how many distinct problems there actually are.
    func test_portsSharingAMessageAreNamedTogether() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let ports = [try port(nodeID, "output", "boom"),
                     try port(nodeID, "infoLog", "boom"),
                     try port(nodeID, "errorLog", "boom")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["boom"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · errorLog, infoLog, output: boom"])
    }

    func test_distinctMessagesGetTheirOwnLines() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let ports = [try port(nodeID, "output", "first"),
                     try port(nodeID, "infoLog", "second")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["first", "second"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · output: first", "   · infoLog: second"])
    }

    /// Sorted, so the same failure reads the same way twice. Set iteration order is seeded
    /// per process, so without this a report would shuffle between runs.
    func test_messagesAndPortNamesAreSorted() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let ports = [try port(nodeID, "zebra", "b"), try port(nodeID, "alpha", "b"),
                     try port(nodeID, "middle", "a")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["b", "a"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · middle: a", "   · alpha, zebra: b"])
    }

    // MARK: - Multi-line messages

    /// A missing-configuration error spans several lines and is the most common multi-line
    /// case there is, so it has to stay readable rather than being folded onto one line.
    func test_aMultiLineMessageIsIndentedUnderItsPorts() throws {
        let nodeID = try makeNode(kind: Configuration.kind)
        let message = "Missing configuration. Add these:\n\nclang.compiler.target=…\n"
        let ports = [try port(nodeID, "output", message)]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: [message], database: database)

        XCTAssertEqual(Array(lines[1 ..< lines.count - 1]),
                       ["   · output:",
                        "     Missing configuration. Add these:",
                        "     clang.compiler.target=…"])
    }

    // MARK: - Labels

    func test_aNodeWithAPathIsNamedByIt() throws {
        let nodeID = try makeNode(kind: StaticFile.kind, properties: ["path": "input:/a/b.c"])

        XCTAssertEqual(ErrorReport.label(forNodeID: nodeID, database: database),
                       "StaticFile  'input:/a/b.c'")
    }

    /// The internal id is a surrogate integer and means nothing to the reader, so it appears
    /// only when nothing better can be found.
    func test_anUnreadableNodeFallsBackToItsID() throws {
        XCTAssertEqual(ErrorReport.label(forNodeID: 99999, database: database), "Node 99999")
    }

    // MARK: - Remedy text for a stale kind

    /// `TypeRegistryError` lives in `SemelNodeKit`, which cannot name `reset` — it does not
    /// know the engine has one. The engine appends the remedy where it renders the error,
    /// not where `SemelNodeKit` throws it.
    func test_anUnregisteredKindErrorNamesTheRemedy() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let output = node.buildErrorOutput(withError: TypeRegistryError.unknownKind(37))

        guard case .noValue(.error(let messageHash)) = output.outputValues[SampleTool.output] else {
            return XCTFail("expected an error value")
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("no type is registered for kind 37"), message)
        XCTAssertTrue(message.contains("reset"), message)
    }

    // MARK: - A thrown error's own words

    /// What a node throws reaches the report as the sentence the node wrote, not as the
    /// enum case's debug form. The debug form puts the whole message on one line, inside
    /// `other(message: "…")`, with every newline escaped — unreadable, and impossible to
    /// paste the config lines out of.
    func test_aThrownNodeErrorIsReportedAsItsMessage() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))
        let written = "Missing configuration. Add these to a semel.config:\nclang.linker.target=…"

        let output = node.buildErrorOutput(withError: NodeError.other(message: written))

        guard case .noValue(.error(let messageHash)) = output.outputValues[SampleTool.output] else {
            return XCTFail("expected an error value")
        }
        XCTAssertEqual(try messageHash.resolveAsString(), written)
    }

    /// A case with no message of its own still has to read as a sentence, for the same
    /// reason: `inputValueInError` is the enum's spelling, not an explanation.
    func test_aNodeErrorWithoutAMessageIsReportedAsASentence() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let output = node.buildErrorOutput(withError: NodeError.inputValueInError)

        guard case .noValue(.error(let messageHash)) = output.outputValues[SampleTool.output] else {
            return XCTFail("expected an error value")
        }
        XCTAssertEqual(try messageHash.resolveAsString(), "an input is in error")
    }

    /// A tool that cannot be found on this machine is a node failure like any other, and
    /// reaches the report by the same route.
    func test_aMissingToolIsReportedAsASentenceNamingThePath() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let output = node.buildErrorOutput(
            withError: LocalFileSystemToolError.toolNotFound(path: "/usr/bin/nonesuch"))

        guard case .noValue(.error(let messageHash)) = output.outputValues[SampleTool.output] else {
            return XCTFail("expected an error value")
        }
        XCTAssertEqual(try messageHash.resolveAsString(),
                       "no tool exists at '/usr/bin/nonesuch'")
    }

    /// A mistake in a formula the user wrote by hand is the most likely error of all to be
    /// read, and `LocalizedError` alone does not reach it: interpolation asks for
    /// `CustomStringConvertible`, and `errorDescription` answers only `localizedDescription`.
    /// The sentence the parser builds has to be the sentence the port carries.
    ///
    /// A token the lexer rejects is wrapped in a `FormulaLexerError`, which carries the
    /// source location and a description of its own. The errors raised while evaluating a
    /// parsed formula — an unknown name among them — are thrown bare, so they are the ones
    /// that reach the port as the type's own spelling.
    func test_aFormulaErrorIsReportedAsTheParsersSentence() throws {
        let builder = try ProjectBuilder(thisNode: NodeRecord(id: 1, kind: ProjectBuilder.kind))
        let broken = """
            product 'MyProduct' =
                Configuration(moduleName: noSuchName).output
            """
        let input = ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  ["input:/proj/build.fmla": .value(try broken.intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.graphImportsInputPort: [:],
        ])

        do {
            _ = try builder.process(input: input)
            return XCTFail("expected the formula to fail to parse")
        } catch {
            let output = builder.buildErrorOutput(withError: error)
            guard case .noValue(.error(let messageHash)) =
                    output.outputValues[ProjectBuilder.statusOutputPort] else {
                return XCTFail("expected an error value")
            }
            XCTAssertEqual(try messageHash.resolveAsString(), "Undefined identifier 'noSuchName'")
        }
    }

    // MARK: - What counts as reportable

    /// Every node holds "initializing" between being created and first processing, so
    /// reporting it would announce an error for every node in a fresh graph.
    func test_theInitializingPlaceholderIsNotReportable() throws {
        let nodeID = try makeNode(kind: Configuration.kind)

        XCTAssertNil(ErrorReport.reportableMessage(of: try port(nodeID, "output", "initializing")))
        XCTAssertNil(ErrorReport.reportableMessage(of: try port(nodeID, "output", "")))
        XCTAssertEqual(ErrorReport.reportableMessage(of: try port(nodeID, "output", "real")), "real")
    }
}
