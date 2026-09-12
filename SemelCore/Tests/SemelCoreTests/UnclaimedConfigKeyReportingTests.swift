//
//  UnclaimedConfigKeyReportingTests.swift
//  SemelCoreTests
//
//  The idle-time reporting wrapper around `unclaimedConfigKeys`.
//
//  Suppression is the feature under test here, not the key-matching logic covered by
//  UnclaimedConfigKeyTests: a report that fires on every settle is noise that trains people
//  to ignore it, so a config file's unclaimed set is only printed when it changes.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class UnclaimedConfigKeyReportingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        captured = []
        engine.unclaimedConfigKeyReporter = { [weak self] message in self?.captured.append(message) }
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    /// Writes (or rewrites) a config file at `path` and wires `prefixes` to it. Calling this
    /// again for a path already in the graph finds the same `StaticFile` node — the same
    /// spec-matching `findOrCreateMatchingNode` uses everywhere else — so a second call is
    /// how a test simulates editing the file rather than creating an unrelated one.
    private func writeConfigFile(path: String, content: String, prefixes: [String]) throws {
        let fileShape = try GraphSpecNode.parse("StaticFile(path: '\(path)')")
        let (fileNode, _) = try fileShape.findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(fileNode.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try content.intern())

        for prefix in prefixes {
            let spec = try GraphSpecNode.parse(
                "ConfigFilter(prefix: '\(prefix)', input: ['config': StaticFile(path: '\(path)').output]).output")
            _ = try spec.findOrCreateMatchingNode()
        }
    }

    func test_aStandingBadPrefixPrintsOnceNotOnASecondCall() throws {
        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compier.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])

        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1)

        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1, "an unchanged unclaimed set must not be reported a second time")
    }

    func test_fixingTheFileAndReportingAgainPrintsNothing() throws {
        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compier.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1)

        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compiler.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1, "a fix must not itself generate a new line")
    }

    func test_breakingItAgainAfterAFixPrintsAgain() throws {
        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compier.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1)

        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compiler.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1)

        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compier.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 2,
                       "a regression must be reported again — the earlier suppression must not swallow it forever")
    }

    func test_suppressionIsPerConfigFileNotGlobal() throws {
        try writeConfigFile(path: "input:/semel.config",
                            content: "swift.compier.sdkVersion=26.5",
                            prefixes: ["swift.compiler"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 1)

        // A second, unrelated config file with its own bad prefix. If suppression state were
        // keyed globally instead of per file, this would be silently swallowed by the first
        // file's already-reported state.
        try writeConfigFile(path: "input:/other.config",
                            content: "clang.liner.target=arm64",
                            prefixes: ["clang.linker"])
        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 2, "the second file's bad prefix must not be masked by the first")

        engine.reportUnclaimedConfigKeys()
        XCTAssertEqual(captured.count, 2, "both files are unchanged now, so neither should repeat")
    }
}
