@testable import SemelCore
import XCTest
import SemelNodeKit

final class NodeDescriptorTests: SemelCoreTestCase {

    // MARK: - InputPort.name

    func test_requiredPort_name() {
        XCTAssertEqual(NodeDescriptor.InputPort.required("foo").name, "foo")
    }

    func test_optionalPort_name() {
        XCTAssertEqual(NodeDescriptor.InputPort.optional("bar").name, "bar")
    }

    func test_dynamicPort_name() {
        XCTAssertEqual(NodeDescriptor.InputPort.dynamic("baz").name, "baz")
    }

    // MARK: - staticInputPorts

    func test_requiredPort_appearsInStaticInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.required("input")], outputPorts: [])
        XCTAssertEqual(desc.staticInputPorts, ["input"])
    }

    func test_optionalPort_appearsInStaticInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.optional("config")], outputPorts: [])
        XCTAssertEqual(desc.staticInputPorts, ["config"])
    }

    func test_dynamicPort_absentFromStaticInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.dynamic("files")], outputPorts: [])
        XCTAssertTrue(desc.staticInputPorts.isEmpty)
    }

    func test_staticInputPorts_includesBothRequiredAndOptional() {
        let desc = NodeDescriptor(
            inputPorts: [.required("input"), .optional("config"), .dynamic("files")],
            outputPorts: ["output"]
        )
        XCTAssertTrue(desc.staticInputPorts.contains("input"))
        XCTAssertTrue(desc.staticInputPorts.contains("config"))
        XCTAssertFalse(desc.staticInputPorts.contains("files"))
    }

    func test_staticInputPorts_preservesDeclarationOrder() {
        let desc = NodeDescriptor(
            inputPorts: [.required("a"), .required("b"), .optional("c")],
            outputPorts: []
        )
        XCTAssertEqual(desc.staticInputPorts, ["a", "b", "c"])
    }

    // MARK: - requiredInputPorts

    func test_requiredPort_appearsInRequiredInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.required("input")], outputPorts: [])
        XCTAssertEqual(desc.requiredInputPorts, ["input"])
    }

    func test_optionalPort_absentFromRequiredInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.optional("config")], outputPorts: [])
        XCTAssertTrue(desc.requiredInputPorts.isEmpty)
    }

    /// A dynamic port is wired by the node itself while it runs, so it is not something
    /// the graph owes it at creation.
    func test_dynamicPort_absentFromRequiredInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.dynamic("files")], outputPorts: [])
        XCTAssertTrue(desc.requiredInputPorts.isEmpty)
    }

    func test_requiredInputPorts_preservesDeclarationOrder() {
        let desc = NodeDescriptor(
            inputPorts: [.required("a"), .optional("c"), .dynamic("files"), .required("b")],
            outputPorts: []
        )
        XCTAssertEqual(desc.requiredInputPorts, ["a", "b"])
    }

    /// The three views agree: the required ports are exactly the static ones the optional
    /// list does not claim. `GraphCheck` reads the first, the applier the second and the
    /// engine's readiness gate the third, and all three must mean one set.
    func test_requiredInputPorts_areTheStaticPortsThatAreNotOptional() {
        let desc = NodeDescriptor(
            inputPorts: [.required("input"), .optional("config"), .dynamic("files"), .required("metadata")],
            outputPorts: ["output"]
        )
        XCTAssertEqual(desc.requiredInputPorts,
                       desc.staticInputPorts.filter { !desc.optionalStaticInputPorts.contains($0) })
    }

    // MARK: - optionalStaticInputPorts

    func test_requiredPort_absentFromOptionalStaticInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.required("input")], outputPorts: [])
        XCTAssertTrue(desc.optionalStaticInputPorts.isEmpty)
    }

    func test_optionalPort_appearsInOptionalStaticInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.optional("config")], outputPorts: [])
        XCTAssertEqual(desc.optionalStaticInputPorts, ["config"])
    }

    func test_dynamicPort_absentFromOptionalStaticInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.dynamic("files")], outputPorts: [])
        XCTAssertTrue(desc.optionalStaticInputPorts.isEmpty)
    }

    func test_optionalStaticInputPorts_containsOnlyOptionalPorts() {
        let desc = NodeDescriptor(
            inputPorts: [.required("input"), .optional("config"), .dynamic("files")],
            outputPorts: ["output"]
        )
        XCTAssertFalse(desc.optionalStaticInputPorts.contains("input"))
        XCTAssertTrue(desc.optionalStaticInputPorts.contains("config"))
        XCTAssertFalse(desc.optionalStaticInputPorts.contains("files"))
    }

    // MARK: - dynamicInputPorts

    func test_requiredPort_absentFromDynamicInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.required("input")], outputPorts: [])
        XCTAssertTrue(desc.dynamicInputPorts.isEmpty)
    }

    func test_optionalPort_absentFromDynamicInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.optional("config")], outputPorts: [])
        XCTAssertTrue(desc.dynamicInputPorts.isEmpty)
    }

    func test_dynamicPort_appearsInDynamicInputPorts() {
        let desc = NodeDescriptor(inputPorts: [.dynamic("files")], outputPorts: [])
        XCTAssertEqual(desc.dynamicInputPorts, ["files"])
    }

    func test_dynamicInputPorts_containsOnlyDynamicPorts() {
        let desc = NodeDescriptor(
            inputPorts: [.required("input"), .optional("config"), .dynamic("files")],
            outputPorts: ["output"]
        )
        XCTAssertFalse(desc.dynamicInputPorts.contains("input"))
        XCTAssertFalse(desc.dynamicInputPorts.contains("config"))
        XCTAssertTrue(desc.dynamicInputPorts.contains("files"))
    }

    // MARK: - Empty descriptor

    func test_emptyDescriptor_allPortsEmpty() {
        let desc = NodeDescriptor(inputPorts: [], outputPorts: [])
        XCTAssertTrue(desc.staticInputPorts.isEmpty)
        XCTAssertTrue(desc.optionalStaticInputPorts.isEmpty)
        XCTAssertTrue(desc.dynamicInputPorts.isEmpty)
    }

    // MARK: - Multiple dynamic ports

    func test_multipleDynamicPorts_allAppearInDynamicInputPorts() {
        let desc = NodeDescriptor(
            inputPorts: [.dynamic("sources"), .dynamic("headers")],
            outputPorts: []
        )
        XCTAssertEqual(desc.dynamicInputPorts, ["sources", "headers"])
    }
}
