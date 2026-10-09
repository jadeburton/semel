//
//  ErrorReportTests.swift
//  SemelCoreTests
//
//  What a node's errors are, as the engine gathers them.
//
//  Two callers gather them — the engine as it settles, and the server's `errors` verb on
//  request — and they differ in which errors they select, never in what an error is. What
//  a node publishes is a typed document; the engine gathers documents and renders none of
//  them, which is the client's to do.
//

@testable import SemelCore
import SemelDatabaseModels
@testable import SemelNodeKit
import XCTest

final class ErrorReportTests: SemelCoreTestCase {

    private var engine: BuildEngine?
    private var database: DatabaseLayer { DatabaseLayer.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        self.engine = engine
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

    private func port(_ nodeID: ObjectID, _ name: String, _ document: ErrorDocument) throws -> OutputPort {
        OutputPort(nodeID: nodeID,
                   nameSymbolID: name.asSymbolID(),
                   valueKind: .error,
                   dataObjectHash: try document.toJSON().intern())
    }

    /// The document a node's output carries, read back.
    private func document(_ output: ProcessOutput, _ port: String) throws -> ErrorDocument {
        try XCTUnwrap(output.outputValues[port]?.errorDocument, "expected an error document on \(port)")
    }

    // MARK: - Grouping

    /// A node that fails usually fails on every port at once with one document. The ports
    /// are gathered onto one item, which is what keeps a report from saying the same thing
    /// three times and hiding how many distinct problems there are.
    func test_portsSharingADocumentAreGatheredOntoOneItem() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let boom = ErrorDocument.failure("boom")
        let ports = [try port(nodeID, "output", boom),
                     try port(nodeID, "infoLog", boom),
                     try port(nodeID, "errorLog", boom)]

        let entry = ErrorReport.entry(forNodeID: nodeID, ports: ports, documents: [boom], database: database)

        XCTAssertEqual(entry.items, [ErrorReport.Item(ports: ["errorLog", "infoLog", "output"], document: boom)])
        XCTAssertEqual(entry.typeName, "SettingsLiteral")
        XCTAssertEqual(entry.nodeIDs, [nodeID])
    }

    /// Two documents are two items, each with the ports that carry it, in one order every
    /// run: set iteration order is seeded per process.
    func test_distinctDocumentsAreDistinctItemsInOneOrder() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let first  = ErrorDocument.failure("first")
        let second = ErrorDocument.failure("second")
        let ports = [try port(nodeID, "output", first), try port(nodeID, "infoLog", second)]

        let entry = ErrorReport.entry(forNodeID: nodeID, ports: ports, documents: [second, first], database: database)

        XCTAssertEqual(entry.items, [ErrorReport.Item(ports: ["output"], document: first),
                                     ErrorReport.Item(ports: ["infoLog"], document: second)])
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

    // MARK: - What a thrown error publishes

    /// A kind no linked type has is the condition naming it, with the type to register as
    /// the remedy: a fact the engine can state, where taking it out of the formula and a
    /// `reset` are the reader's choices.
    func test_anUnregisteredKindIsTheConditionWithItsRemedy() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let published = try document(node.buildErrorOutput(withError: TypeRegistryError.unknownKind(37), input: nil),
                                     SampleTool.output)

        XCTAssertEqual(published.diagnostic, .engine(.unlinkedKind(kind: 37)))
        XCTAssertEqual(published.remedy, .register(kind: 37))
    }

    /// What a node throws reaches its ports as the condition the error names, never as its
    /// description: the client renders the sentence.
    func test_aThrownNodeErrorIsPublishedAsItsCondition() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let published = try document(node.buildErrorOutput(withError: NodeError.severalWiresOnOneWirePort(port: "configuration",
                                                                                                          wires: ["a", "b"]),
                                                           input: nil),
                                     SampleTool.output)

        XCTAssertEqual(published.diagnostic,
                       .engine(.severalWiresOnOneWirePort(type: nil, port: "configuration", wires: ["a", "b"])))
    }

    /// A node that did not run because its input failed has nothing of its own to say, so it
    /// publishes the state rather than a document: the thrown error is control flow, and the
    /// engine turns it into a reason before anything reaches a port.
    func test_aNodeWhoseInputFailedPublishesTheStateRatherThanADocument() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let output = node.buildErrorOutput(withError: NodeError.inputValueInError, input: nil)

        XCTAssertEqual(output.outputValues.count, SampleTool.descriptor.outputPorts.count)
        for (port, value) in output.outputValues {
            guard case .noValue(.inputInError) = value else {
                return XCTFail("expected the input-in-error state on \(port), got \(value)")
            }
        }
    }

    /// A tool that cannot be found on this machine is a node failure like any other, and
    /// reaches the report by the same route.
    func test_aMissingToolIsTheConditionNamingThePath() throws {
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let published = try document(node.buildErrorOutput(withError: LocalFileSystemToolError.toolNotFound(path: "/usr/bin/nonesuch"),
                                                           input: nil),
                                     SampleTool.output)

        XCTAssertEqual(published.diagnostic, .engine(.toolNotFound(path: "/usr/bin/nonesuch")))
    }

    /// A mistake in a formula the user wrote by hand is the most likely error of all to be
    /// read. The builder names the formula on the condition, so its first line is the path a
    /// terminal makes a link of, and the formula is what the failure belongs to.
    func test_aFormulaErrorIsTheParsersConditionOnItsFormula() throws {
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
            let published = try document(builder.buildErrorOutput(withError: error, input: input),
                                         ProjectBuilder.statusOutputPort)
            XCTAssertEqual(published.diagnostic,
                           .engine(.formulaInvalid(path: "input:/proj/build.fmla", problem: .undefinedIdentifier(name: "noSuchName"),
                                                   line: nil, column: nil, lineText: nil)))
            XCTAssertEqual(published.subject, .formula(path: "input:/proj/build.fmla"))
        }
    }

    /// An error the engine has no condition for is published all the same: the last resort,
    /// with its type and its own words, rather than a port with nothing on it.
    func test_anErrorWithNoConditionIsTheLastResort() throws {
        struct Foreign: Error, CustomStringConvertible {
            var description: String { "a foreign failure" }
        }
        let node = try SampleTool(thisNode: NodeRecord(id: 1, kind: SampleTool.kind))

        let published = try document(node.buildErrorOutput(withError: Foreign(), input: nil), SampleTool.output)

        XCTAssertEqual(published.diagnostic, .engine(.unclassified(type: "Foreign", description: "a foreign failure")))
    }

    // MARK: - What counts as reportable

    /// Every node holds the initializing state between being created and first processing,
    /// so reporting it would announce an error for every node in a fresh graph. An error
    /// whose document cannot be read is still an error, said as one that cannot be read.
    func test_aPortThatHasNotBeenProcessedIsNotReportable() throws {
        let nodeID = try makeNode(kind: SettingsLiteral.kind)
        let initializing = try NodeValue.noValue(reason: .initializing)
            .asOutputPort(nodeID: nodeID, outputSymbolID: "output".asSymbolID())
        let unreadable = OutputPort(nodeID: nodeID, nameSymbolID: "output".asSymbolID(), valueKind: .error,
                                    dataObjectHash: try "not a document".intern())

        XCTAssertNil(ErrorReport.reportableDocument(of: initializing))
        XCTAssertEqual(ErrorReport.reportableDocument(of: unreadable)?.diagnostic,
                       .engine(.documentUnreadable(hash: try "not a document".intern())))
        XCTAssertEqual(ErrorReport.reportableDocument(of: try port(nodeID, "output", .failure("real"))), .failure("real"))
    }

    /// The count a settle's summary carries is one per cause, merged as the client merges
    /// blocks: two compilers missing one setting are one error.
    func test_theErrorCountMergesWhatTheReportMerges() {
        let missing = ErrorCondition.settingsMissing(project: [], machine: ["clang.compiler.toolDescriptor.name"], writer: nil)
        let entries = [
            ErrorReport.Entry(label: "a", typeName: "ClangCompiler", nodeIDs: [1],
                              items: [ErrorReport.Item(ports: ["output"], document: .engine(missing, subject: .source(path: "input:/a.c")))]),
            ErrorReport.Entry(label: "b", typeName: "ClangCompiler", nodeIDs: [2],
                              items: [ErrorReport.Item(ports: ["output"], document: .engine(missing, subject: .source(path: "input:/b.c")))]),
            ErrorReport.Entry(label: "c", typeName: "SampleTool", nodeIDs: [3],
                              items: [ErrorReport.Item(ports: ["output"], document: .failure("boom"))]),
        ]

        XCTAssertEqual(ErrorReport.errorCount(of: entries), 2)
    }
}
