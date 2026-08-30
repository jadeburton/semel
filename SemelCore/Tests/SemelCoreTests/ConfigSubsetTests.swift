//
//  ConfigSubsetTests.swift
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

final class ConfigSubsetTests: SemelCoreTestCase {

    private func subset(prefix: String, file: String) throws -> String {
        let node = try ConfigSubset(thisNode: Node(id: 1, kind: ConfigSubset.kind,
                                                   properties: ["prefix": prefix]))
        let output = try node.process(input: ProcessInput(inputValues: [
            ConfigSubset.inputPort: ["config": .value(try file.intern())]
        ]))
        return try XCTUnwrap(output.outputValues[ConfigSubset.outputPort])
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
}
