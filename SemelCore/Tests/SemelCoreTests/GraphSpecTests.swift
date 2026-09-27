//
//  GraphSpecTests.swift
//  semel_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class GraphSpecTests: SemelCoreTestCase {

    // MARK: - Leaf node

    func test_leafNode_parsesTypeName() throws {
        let node = try GraphSpecNode.parse("StaticFile(path: 'src/hello.c').output")
        XCTAssertEqual(node.typeName, "StaticFile")
    }

    func test_leafNode_parsesArg() throws {
        let node = try GraphSpecNode.parse("StaticFile(path: 'src/hello.c').output")
        XCTAssertEqual(node.properties, [GraphSpecProperty(key: "path", value: "src/hello.c")])
    }

    func test_leafNode_parsesOutputPort() throws {
        let node = try GraphSpecNode.parse("StaticFile(path: 'src/hello.c').output")
        XCTAssertEqual(node.outputPort, "output")
    }

    func test_leafNode_roundTrip() throws {
        let input = "StaticFile(path: 'src/hello.c').output"
        let node = try GraphSpecNode.parse(input)
        XCTAssertEqual(node.asString(omitOutputPort: false), input)
    }

    // MARK: - Node without output port (graphSpec form)

    func test_nodeWithoutOutputPort_parsesNilPort() throws {
        let node = try GraphSpecNode.parse("StaticFile(path: 'hello.c')")
        XCTAssertNil(node.outputPort)
    }

    func test_nodeWithoutOutputPort_roundTrip() throws {
        let input = "StaticFile(path: 'hello.c')"
        let node = try GraphSpecNode.parse(input)
        XCTAssertEqual(node.asString(omitOutputPort: false), input)
    }

    func test_omitOutputPort_suppressesSuffix() throws {
        let node = try GraphSpecNode.parse("StaticFile(path: 'hello.c').output")
        XCTAssertEqual(node.asString(omitOutputPort: true), "StaticFile(path: 'hello.c')")
    }

    // MARK: - Input port

    func test_inputPort_parsesPortName() throws {
        let node = try GraphSpecNode.parse(
            "ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(node.inputs.count, 1)
        XCTAssertEqual(node.inputs[0].portName, "input")
    }

    func test_inputPort_parsesWireName() throws {
        let node = try GraphSpecNode.parse(
            "ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(node.inputs[0].wires[0].name, "hello.c")
    }

    func test_inputPort_parsesUpstreamNode() throws {
        let node = try GraphSpecNode.parse(
            "ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertEqual(node.inputs[0].wires[0].node.typeName, "StaticFile")
    }

    func test_inputPort_roundTrip() throws {
        let input = "ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        let node = try GraphSpecNode.parse(input)
        XCTAssertEqual(node.asString(omitOutputPort: false), input)
    }

    // MARK: - Multiple input wires on one port

    func test_multipleWires_parsesCount() throws {
        let node = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        )
        XCTAssertEqual(node.inputs[0].wires.count, 2)
    }

    func test_multipleWires_parsesFirstWireName() throws {
        let node = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        )
        XCTAssertEqual(node.inputs[0].wires[0].name, "a")
    }

    func test_multipleWires_parsesSecondWireName() throws {
        let node = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        )
        XCTAssertEqual(node.inputs[0].wires[1].name, "b")
    }

    /// The rendered string is a node's identity, so two demands that differ only in the
    /// order their wires are written in are one node, not two.
    func test_multipleWires_renderInTheSameOrderWhateverOrderTheyAreWrittenIn() throws {
        let first = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        )
        let second = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"b\": StaticFile(path: 'b.c').output, \"a\": StaticFile(path: 'a.c').output]).output"
        )

        XCTAssertEqual(first.asString(omitOutputPort: true), second.asString(omitOutputPort: true))
    }

    func test_multipleWires_roundTrip() throws {
        let input = "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        XCTAssertEqual(try GraphSpecNode.parse(input).asString(omitOutputPort: false), input)
    }

    // MARK: - Multiple input ports

    func test_multipleInputPorts_parsesCount() throws {
        let node = try GraphSpecNode.parse(
            "ClangCompiler(configuration: [\"config\": SettingsLiteral(tool: 'compiler').output], input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
        )
        XCTAssertEqual(node.inputs.count, 2)
    }

    func test_multipleInputPorts_portNames() throws {
        let node = try GraphSpecNode.parse(
            "ClangCompiler(configuration: [\"config\": SettingsLiteral(tool: 'compiler').output], input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
        )
        let portNames = node.inputs.map(\.portName)
        XCTAssertTrue(portNames.contains("configuration"))
        XCTAssertTrue(portNames.contains("input"))
    }

    func test_multipleInputPorts_roundTrip() throws {
        let input = "ClangCompiler(configuration: [\"config\": SettingsLiteral(tool: 'compiler').output], input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
        XCTAssertEqual(try GraphSpecNode.parse(input).asString(omitOutputPort: false), input)
    }

    // MARK: - Double-quoted args (backward compat)

    func test_doubleQuotedArg_parsesValue() throws {
        let node = try GraphSpecNode.parse("StaticFile(path: \"hello.c\")")
        XCTAssertEqual(node.properties[0].value, "hello.c")
    }

    // MARK: - asString pretty

    func test_asString_pretty_containsNewlines() throws {
        let node = try GraphSpecNode.parse(
            "ClangCompiler(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertTrue(node.asString(pretty: true, omitOutputPort: false).contains("\n"))
    }

    func test_asString_compact_noNewlines() throws {
        let node = try GraphSpecNode.parse(
            "ClangCompiler(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertFalse(node.asString(pretty: false, omitOutputPort: false).contains("\n"))
    }

    func test_asString_pretty_parsesBackToTheSameTree() throws {
        let input = "ClangCompiler(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        let original = try GraphSpecNode.parse(input)
        let prettyString = original.asString(pretty: true, omitOutputPort: false)
        XCTAssertEqual(try GraphSpecNode.parse(prettyString), original)
    }

    // MARK: - identity (B-115)
    //
    // The types here are ones the engine registers, since an identity is taken over a
    // kind; the ports need not exist, since the hash is of the tree and not of the graph.

    private func identity(_ spec: String) throws -> String {
        try GraphSpecNode.parse(spec).identity()
    }

    func test_identity_isTheSameForTheSameTree() throws {
        XCTAssertEqual(try identity("StaticFile(path: 'hello.c').output"), try identity("StaticFile(path: 'hello.c').output"))
        XCTAssertEqual(try identity("StaticFile(path: 'hello.c').output").count, 64)
    }

    /// A node's own output port is where a consumer reads it, not what it is.
    func test_identity_ignoresTheNodesOwnOutputPort() throws {
        XCTAssertEqual(try identity("StaticFile(path: 'hello.c').output"), try identity("StaticFile(path: 'hello.c').otherPort"))
    }

    func test_identity_differsWithAProperty() throws {
        XCTAssertNotEqual(try identity("StaticFile(path: 'hello.c')"), try identity("StaticFile(path: 'main.c')"))
    }

    func test_identity_differsWithTheType() throws {
        XCTAssertNotEqual(try identity("SettingsLiteral(path: 'x')"), try identity("StaticFile(path: 'x')"))
    }

    func test_identity_isPortAndWireOrderIndependent() throws {
        let configuration = GraphSpecInputPort(portName: "configuration", wires: [
            GraphSpecWire(name: "config", node: GraphSpecNode(typeName: "SettingsLiteral",
                                                              properties: [GraphSpecProperty(key: "tool", value: "compiler")],
                                                              outputPort: "output")),
        ])
        let input = GraphSpecInputPort(portName: "input", wires: [
            GraphSpecWire(name: "b.c", node: GraphSpecNode(typeName: "StaticFile", properties: [GraphSpecProperty(key: "path", value: "b.c")], outputPort: "output")),
            GraphSpecWire(name: "a.c", node: GraphSpecNode(typeName: "StaticFile", properties: [GraphSpecProperty(key: "path", value: "a.c")], outputPort: "output")),
        ])
        let reversedInput = GraphSpecInputPort(portName: "input", wires: input.wires.reversed())

        let one = GraphSpecNode(typeName: "SampleTool", inputs: [configuration, input], outputPort: "output")
        let other = GraphSpecNode(typeName: "SampleTool", inputs: [reversedInput, configuration], outputPort: "output")

        XCTAssertEqual(try one.identity(), try other.identity())
    }

    func test_identity_differsWithAWireName() throws {
        XCTAssertNotEqual(try identity("TreeMerger(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).files"),
                          try identity("TreeMerger(input: [\"main.c\": StaticFile(path: 'hello.c').output]).files"))
    }

    func test_identity_differsWithTheSourcesOutputPort() throws {
        XCTAssertNotEqual(try identity("TreeMerger(input: [\"w\": StaticFile(path: 'a.c').output]).files"),
                          try identity("TreeMerger(input: [\"w\": StaticFile(path: 'a.c').metadata]).files"))
    }

    func test_identity_differsWithTheWireCount() throws {
        XCTAssertNotEqual(try identity("TreeMerger(input: [\"a\": StaticFile(path: 'a.c').output]).files"),
                          try identity("TreeMerger(input: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).files"))
    }

    /// A change anywhere below moves every identity above it: the Merkle property that
    /// makes one hash stand for a whole subgraph.
    func test_identity_differsWithAChangeDeepInTheTree() throws {
        let shallow = "TreeMerger(input: [\"m\": TreeMerger(input: [\"f\": StaticFile(path: 'hello.c').output]).files]).files"
        let changed = "TreeMerger(input: [\"m\": TreeMerger(input: [\"f\": StaticFile(path: 'other.c').output]).files]).files"

        XCTAssertEqual(try identity(shallow), try identity(shallow))
        XCTAssertNotEqual(try identity(shallow), try identity(changed))
    }

    func test_identity_needsARegisteredType() {
        XCTAssertThrowsError(try identity("NoSuchType(path: 'x').output")) { error in
            XCTAssertEqual("\(error)", "no node type is registered under the name 'NoSuchType'")
        }
    }

    func test_identity_needsAnOutputPortOnEveryWire() {
        XCTAssertThrowsError(try identity("TreeMerger(input: [\"w\": StaticFile(path: 'a.c')]).files"))
    }

    // MARK: - adding(property:value:where:)

    /// The property lands on every node the predicate admits, at every depth, and on no
    /// other; a node that already has it keeps its value. Rendering sorts properties, so
    /// the new one appears where its key sorts.
    func test_addingAPropertyReachesEveryAdmittedNodeAndNoOther() throws {
        let spec = try GraphSpecNode.parse(
            "Tool(a: '1', in: ['x': StaticFile(path: 'p').output, 'y': Tool(projectRoot: 'kept', in: ['z': Other().output]).output]).output")

        let stamped = spec.adding(property: "projectRoot", value: "input:/repo") { $0.typeName != "StaticFile" }

        XCTAssertEqual(stamped.asString(omitOutputPort: false),
                       "Tool(a: '1', projectRoot: 'input:/repo', in: [\"x\": StaticFile(path: 'p').output, "
                       + "\"y\": Tool(projectRoot: 'kept', in: [\"z\": Other(projectRoot: 'input:/repo').output]).output]).output")
    }

    // MARK: - Parse errors

    func test_parse_emptyString_throws() {
        XCTAssertThrowsError(try GraphSpecNode.parse(""))
    }

    func test_parse_missingClosingParen_throws() {
        XCTAssertThrowsError(try GraphSpecNode.parse("StaticFile(path: 'hello.c'"))
    }

    func test_parse_unknownOperator_throws() {
        XCTAssertThrowsError(try GraphSpecNode.parse("Foo(bar = 'baz')"))
    }
}
