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

    func test_multipleWires_roundTrip() throws {
        let input = "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        XCTAssertEqual(try GraphSpecNode.parse(input).asString(omitOutputPort: false), input)
    }

    // MARK: - Multiple input ports

    func test_multipleInputPorts_parsesCount() throws {
        let node = try GraphSpecNode.parse(
            "ClangCompiler(configuration: [\"config\": Configuration(tool: 'compiler').output], input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
        )
        XCTAssertEqual(node.inputs.count, 2)
    }

    func test_multipleInputPorts_portNames() throws {
        let node = try GraphSpecNode.parse(
            "ClangCompiler(configuration: [\"config\": Configuration(tool: 'compiler').output], input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
        )
        let portNames = node.inputs.map(\.portName)
        XCTAssertTrue(portNames.contains("configuration"))
        XCTAssertTrue(portNames.contains("input"))
    }

    func test_multipleInputPorts_roundTrip() throws {
        let input = "ClangCompiler(configuration: [\"config\": Configuration(tool: 'compiler').output], input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
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

    func test_asString_pretty_parsesBackToSameTopology() throws {
        let input = "ClangCompiler(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        let original = try GraphSpecNode.parse(input)
        let prettyString = original.asString(pretty: true, omitOutputPort: false)
        let reparsed = try GraphSpecNode.parse(prettyString)
        XCTAssertNoThrow(try original.expectTopologyMatch(reparsed))
    }

    // MARK: - topologyMatches

    func test_topologyMatches_identicalNodes() throws {
        let a = try GraphSpecNode.parse("StaticFile(path: 'hello.c').output")
        let b = try GraphSpecNode.parse("StaticFile(path: 'hello.c').output")
        XCTAssertNoThrow(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_outputPortIgnored() throws {
        let a = try GraphSpecNode.parse("StaticFile(path: 'hello.c').output")
        let b = try GraphSpecNode.parse("StaticFile(path: 'hello.c').otherPort")
        XCTAssertNoThrow(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_differentArg_doesNotMatch() throws {
        let a = try GraphSpecNode.parse("StaticFile(path: 'hello.c')")
        let b = try GraphSpecNode.parse("StaticFile(path: 'main.c')")
        XCTAssertThrowsError(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_differentTypeName_doesNotMatch() throws {
        let a = try GraphSpecNode.parse("ClangCompiler()")
        let b = try GraphSpecNode.parse("ClangLinker()")
        XCTAssertThrowsError(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_portOrderIndependent() throws {
        let a = GraphSpecNode(
            typeName: "ClangCompiler",
            inputs: [
                GraphSpecInputPort(portName: "configuration", wires: [
                    GraphSpecWire(name: "config",
                                   node: GraphSpecNode(typeName: "Configuration",
                                                        properties: [GraphSpecProperty(key: "tool", value: "compiler")]))
                ]),
                GraphSpecInputPort(portName: "input", wires: [
                    GraphSpecWire(name: "hello.c",
                                   node: GraphSpecNode(typeName: "StaticFile",
                                                        properties: [GraphSpecProperty(key: "path", value: "hello.c")]))
                ])
            ],
            outputPort: "output"
        )
        let b = GraphSpecNode(
            typeName: "ClangCompiler",
            inputs: [
                GraphSpecInputPort(portName: "input", wires: [
                    GraphSpecWire(name: "hello.c",
                                   node: GraphSpecNode(typeName: "StaticFile",
                                                        properties: [GraphSpecProperty(key: "path", value: "hello.c")]))
                ]),
                GraphSpecInputPort(portName: "configuration", wires: [
                    GraphSpecWire(name: "config",
                                   node: GraphSpecNode(typeName: "Configuration",
                                                        properties: [GraphSpecProperty(key: "tool", value: "compiler")]))
                ])
            ],
            outputPort: "output"
        )
        XCTAssertNoThrow(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_differentWireName_doesNotMatch() throws {
        let a = try GraphSpecNode.parse(
            "ClangCompiler(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output"
        )
        let b = try GraphSpecNode.parse(
            "ClangCompiler(input: [\"main.c\": StaticFile(path: 'hello.c').output]).output"
        )
        XCTAssertThrowsError(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_differentWireCount_doesNotMatch() throws {
        let a = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output]).output"
        )
        let b = try GraphSpecNode.parse(
            "ClangLinker(objectFiles: [\"a\": StaticFile(path: 'a.c').output, \"b\": StaticFile(path: 'b.c').output]).output"
        )
        XCTAssertThrowsError(try a.expectTopologyMatch(b))
    }

    func test_topologyMatches_nestedNodesMatch() throws {
        let input = "ClangCompiler(input: [\"hello.c.p\": ClangPreprocessor(input: [\"hello.c\": StaticFile(path: 'hello.c').output]).output]).output"
        let a = try GraphSpecNode.parse(input)
        let b = try GraphSpecNode.parse(input)
        XCTAssertNoThrow(try a.expectTopologyMatch(b))
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
