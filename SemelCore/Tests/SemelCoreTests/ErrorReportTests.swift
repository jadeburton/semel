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
        try GraphSpecNode(try TypeRegistry.type(kind: kind), properties: properties)
            .findOrCreateMatchingNode().fromNode.requireID()
    }

    private func port(_ nodeID: ObjectID, _ name: String, _ message: String) throws -> OutputPort {
        OutputPort(nodeID: nodeID,
                   nameSymbolID: name.asSymbolID(),
                   valueKind: .error,
                   dataObjectHash: try message.intern())
    }

    // MARK: - Grouping

    /// A node that fails usually fails on every port at once for the same reason. The ports
    /// are gathered onto one item rather than onto a line each, which is what keeps a
    /// report from saying the same thing three times and hiding how many distinct problems
    /// there are.
    func test_portsSharingAMessageAreGatheredOntoOneItem() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let ports = [try port(nodeID, "output", "boom"),
                     try port(nodeID, "infoLog", "boom"),
                     try port(nodeID, "errorLog", "boom")]

        let entry = ErrorReport.entry(forNodeID: nodeID, ports: ports,
                                      messages: ["boom"], database: database)

        XCTAssertEqual(entry.items,
                       [ErrorReport.Item(ports: ["errorLog", "infoLog", "output"], message: "boom")])
    }

    // MARK: - The port prefix

    /// B-104. The port names tell one item from another and say which of a node's ports a
    /// message came from. A lone port on a lone item does neither, so the prefix repeats
    /// the heading in the engine's own vocabulary and is left out.
    func test_oneItemCarryingOnePortIsWrittenWithoutIt() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let ports = [try port(nodeID, "output", "boom")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["boom"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") }, ["   · boom"])
    }

    /// Two messages are two items, and then the ports say which is which.
    func test_theirPortsAreNamedAsSoonAsThereIsMoreThanOneItem() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let ports = [try port(nodeID, "output", "boom"),
                     try port(nodeID, "errorLog", "bang")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["boom", "bang"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") },
                       ["   · errorLog: bang", "   · output: boom"])
    }

    /// One message across several ports keeps their names too. The counts printed beside a
    /// report are sums of ports, so a heading saying two errors sits above a line naming
    /// two ports; dropping the names there would leave the number unaccounted for.
    func test_onePortIsTheConditionRatherThanOneItem() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let ports = [try port(nodeID, "output", "boom"),
                     try port(nodeID, "errorLog", "boom")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: ["boom"], database: database)

        XCTAssertEqual(lines.filter { $0.contains("·") }, ["   · errorLog, output: boom"])
    }

    func test_distinctMessagesGetTheirOwnLines() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
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
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
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
    /// With no ports to announce, the first line sits on the bullet and the rest are
    /// indented under it.
    func test_aMultiLineMessageIsIndentedUnderItsFirstLine() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let message = "Missing configuration. Add these:\n\nclang.compiler.target=…\n"
        let ports = [try port(nodeID, "output", message)]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: [message], database: database)

        XCTAssertEqual(Array(lines[1 ..< lines.count - 1]),
                       ["   · Missing configuration. Add these:",
                        "     clang.compiler.target=…"])
    }

    /// With the ports announced, the block is indented under them.
    func test_aMultiLineMessageBesideAnotherIsIndentedUnderItsPorts() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let message = "Missing configuration. Add these:\n\nclang.compiler.target=…\n"
        let ports = [try port(nodeID, "output", message),
                     try port(nodeID, "errorLog", "boom")]

        let lines = ErrorReport.lines(forNodeID: nodeID, ports: ports,
                                      messages: [message, "boom"], database: database)

        XCTAssertEqual(Array(lines[1 ..< lines.count - 1]),
                       ["   · output:",
                        "     Missing configuration. Add these:",
                        "     clang.compiler.target=…",
                        "   · errorLog: boom"])
    }

    // MARK: - Labels

    func test_aNodeWithAPathIsNamedByIt() throws {
        let nodeID = try makeNode(kind: StaticFile.kind, properties: ["path": "input:/a/b.c"])

        XCTAssertEqual(ErrorReport.label(forNodeID: nodeID, database: database),
                       "StaticFile #\(nodeID) 'input:/a/b.c'")
    }

    /// The form a `check` finding names a node by, so that a node reads the same in both.
    func test_aLabelNamesANodeTheWayCheckDoes() throws {
        let nodeID = try makeNode(kind: StaticFile.kind, properties: ["path": "input:/a/b.c"])
        let node   = try XCTUnwrap(try database.node.find(nodeID: nodeID))

        XCTAssertEqual(ErrorReport.label(forNodeID: nodeID, database: database),
                       GraphCheck.subject(node, path: "input:/a/b.c"))
    }

    func test_aNodeWithNoPathIsNamedByItsTypeAndID() throws {
        let nodeID = try makeNode(kind: SampleTool.kind)

        XCTAssertEqual(ErrorReport.label(forNodeID: nodeID, database: database), "SampleTool #\(nodeID)")
    }

    func test_aNodeWithNoRowIsNamedByItsID() throws {
        XCTAssertEqual(ErrorReport.label(forNodeID: 99999, database: database), "node #99999")
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

    /// A node that did not run because its input failed has nothing of its own to say, so it
    /// publishes the state rather than a sentence: the thrown error is control flow, and the
    /// engine turns it into a reason before anything reaches a port.
    func test_aNodeWhoseInputFailedPublishesTheStateRatherThanAMessage() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let output = node.buildErrorOutput(withError: NodeError.inputValueInError)

        XCTAssertEqual(output.outputValues.count, SampleTool.descriptor.outputPorts.count)
        for (port, value) in output.outputValues {
            guard case .noValue(.inputInError) = value else {
                return XCTFail("expected the input-in-error state on \(port), got \(value)")
            }
        }
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
                SettingsLiteral(moduleName: noSuchName).output
            """
        let input = ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  ["input:/proj/build.fmla": .value(try broken.intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.folderTreesInputPort:  [:],
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

    /// Every node holds the initializing state between being created and first processing,
    /// so reporting it would announce an error for every node in a fresh graph.
    func test_aPortThatHasNotBeenProcessedIsNotReportable() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let initializing = try NodeValue.noValue(reason: .initializing)
            .asOutputPort(nodeID: nodeID, outputSymbolID: "output".asSymbolID())

        XCTAssertNil(ErrorReport.reportableMessage(of: initializing))
        XCTAssertEqual(ErrorReport.reportableMessage(of: try port(nodeID, "output", "")), ErrorReport.emptyMessage)
        XCTAssertEqual(ErrorReport.reportableMessage(of: try port(nodeID, "output", "real")), "real")
    }
}
