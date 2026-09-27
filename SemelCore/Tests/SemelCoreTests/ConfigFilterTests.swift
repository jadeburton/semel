//
//  ConfigFilterTests.swift
//  SemelCoreTests
//
//  Selecting one node's settings out of a config file that holds everyone's.
//
//  The selection is what keeps an edit local. A node wired to `swift.compiler` must produce a
//  byte-identical value when `clang.linker.target` changes, because an identical value is what
//  stops writeToOutputPort from scheduling anything downstream — and downstream here is every
//  compiler in the project.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ConfigFilterTests: SemelCoreTestCase {

    private func subset(prefix: String, file: String) throws -> String {
        let node = try ConfigFilter(thisNode: NodeRecord(id: 1, kind: ConfigFilter.kind,
                                                   properties: ["prefix": prefix]))
        let output = try node.process(input: ProcessInput(inputValues: [
            ConfigFilter.inputPort: ["config": .value(try file.intern())]
        ]))
        return try XCTUnwrap(output.outputValues[ConfigFilter.outputPort])
            .expectValue().resolveAsString()
    }

    private func subset(prefix: String, wires: [String: NodeValue]) throws -> String {
        let node = try ConfigFilter(thisNode: NodeRecord(id: 1, kind: ConfigFilter.kind,
                                                   properties: ["prefix": prefix]))
        let output = try node.process(input: ProcessInput(inputValues: [
            ConfigFilter.inputPort: wires
        ]))
        return try XCTUnwrap(output.outputValues[ConfigFilter.outputPort])
            .expectValue().resolveAsString()
    }

    private let everyones = """
        swift.compiler.sdkVersion=26.5
        swift.compiler.optimisationLevel=speed
        swift.linker.sdkVersion=26.5
        clang.linker.target=arm64-apple-macos14.0
        """

    func test_keepsOnlyTheKeysUnderItsPrefix() throws {
        let result = try subset(prefix: "swift.compiler", file: everyones)

        XCTAssertEqual(result, "optimisationLevel=speed\nsdkVersion=26.5")
    }

    /// The whole point. An unrelated edit must leave this value untouched, because equality is
    /// what stops the cascade.
    func test_anUnrelatedKeyChangingLeavesTheValueIdentical() throws {
        let before = try subset(prefix: "swift.compiler", file: everyones)
        let after = try subset(prefix: "swift.compiler",
                               file: everyones.replacingOccurrences(of: "arm64-apple-macos14.0",
                                                                    with: "x86_64-apple-macos14.0"))

        XCTAssertEqual(before, after)
    }

    /// A prefix match is on whole segments. `swift.compiler` must not swallow
    /// `swift.compilerPlugin`, or two unrelated tools would share a slice.
    func test_matchesWholeSegmentsOnly() throws {
        let result = try subset(prefix: "swift.compiler", file: """
            swift.compiler.sdkVersion=26.5
            swift.compilerPlugin.sdkVersion=99.0
            """)

        XCTAssertEqual(result, "sdkVersion=26.5")
    }

    /// Keys may be dotted themselves. Stripping is not parsing: whatever follows the prefix is
    /// the key, however many dots it has.
    func test_keepsDottedKeysWhole() throws {
        let result = try subset(prefix: "swift.compiler", file: """
            swift.compiler.toolDescriptor.version=6.3.3
            """)

        XCTAssertEqual(result, "toolDescriptor.version=6.3.3")
    }

    /// Sorted, because this becomes a wire value that is compared for equality. Two runs
    /// producing the same settings in different orders would look like a change.
    func test_outputIsSorted() throws {
        let result = try subset(prefix: "p", file: "p.zebra=1\np.alpha=2\np.middle=3")

        XCTAssertEqual(result, "alpha=2\nmiddle=3\nzebra=1")
    }

    func test_aPrefixThatMatchesNothingProducesAnEmptyConfiguration() throws {
        XCTAssertEqual(try subset(prefix: "rust.compiler", file: everyones), "")
    }

    /// The prefix on its own is not a key — there is nothing left after stripping it.
    func test_ignoresAnExactMatchWithNoRemainder() throws {
        XCTAssertEqual(try subset(prefix: "swift.compiler", file: "swift.compiler=x"), "")
    }

    // MARK: - A config file that has not arrived

    /// A `StaticFile` for a config file nobody wrote publishes an error, not a pending value —
    /// and that must not fail this node. The tool that actually needs a setting is what can
    /// say which one is missing; a selector with no file to read contributes nothing rather
    /// than failing every node downstream of it.
    func test_aWireWithNoValueYieldsAnEmptyConfiguration() throws {
        let result = try subset(prefix: "swift.compiler", wires: [
            "config": .noValue(reason: .error(messageDataObjectHash: try "absent".intern())),
        ])

        XCTAssertEqual(result, "")
    }

    // MARK: - One wire

    /// A selector is not where two sets of settings meet (B-120): two wires on its port
    /// would be merged in the order of two names nobody chose for their order. The error
    /// names the port and both wires, so the formula line to change is findable.
    func test_twoWiresAreAnErrorNamingThePortAndTheWires() throws {
        XCTAssertThrowsError(try subset(prefix: "swift.compiler", wires: [
            "input:/semel.config":   .value(try "swift.compiler.sdkVersion=26.5".intern()),
            "input:/a/semel.config": .value(try "swift.compiler.sdkVersion=26.4".intern()),
        ])) { error in
            guard case NodeError.severalWiresOnOneWirePort(let port, let wires) = error else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(port, ConfigFilter.inputPort)
            XCTAssertEqual(wires, ["input:/a/semel.config", "input:/semel.config"])
            XCTAssertEqual("\(error)", "input port 'input' takes one wire, and 2 are wired to it: "
                                    + "'input:/a/semel.config', 'input:/semel.config'. Settings from two places "
                                    + "meet in a ConfigMerger, whose base and override say which wins")
        }
    }

    /// Two wires with nothing on either are still two wires: what the formula wired is the
    /// error, whatever has arrived on it so far.
    func test_twoWiresAreAnErrorEvenWithNoValueOnEither() throws {
        let absent = NodeValue.noValue(reason: .error(messageDataObjectHash: try "absent".intern()))

        XCTAssertThrowsError(try subset(prefix: "swift.compiler", wires: ["a": absent, "b": absent]))
    }
}
