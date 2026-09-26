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

    /// A file that reaches its selector through a `ConfigMerger` is a config file too
    /// (B-109): found by walking up from the selector, and named by its own path.
    func test_aFileBehindAMergerIsFoundAndNamed() throws {
        let project = "input:/semel.config"
        let (fileNode, _) = try GraphSpecNode.parse("StaticFile(path: '\(project)')").findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(fileNode.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try "swift.compier.sdkVersion=26.5".intern())
        let merged = "ConfigMerger(base: ['machine': StaticFile(path: 'input:/semel.machine.config').output], "
                   + "override: ['project': StaticFile(path: '\(project)').output]).output"
        _ = try GraphSpecNode.parse("ConfigFilter(prefix: 'swift.compiler', input: ['config': \(merged)]).output")
            .findOrCreateMatchingNode()

        engine.reportUnclaimedConfigKeys()

        XCTAssertEqual(captured.count, 1, "\(captured)")
        XCTAssertTrue(captured.first?.contains(project) == true, "\(captured)")
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

    /// Several config files with standing unclaimed keys, reported in the one call: the
    /// warnings come out in path order, whatever order their files entered the graph in.
    /// The files are gathered into a `Set`, whose iteration order is seeded per process,
    /// and their node ids are the order the graph was written rather than anything about
    /// the files — so a walk of either prints the same warnings in a different order in
    /// another build of the same tree, and someone comparing two builds reads that as a
    /// change (B-04). The files here are created out of path order to tell the two apart.
    func test_severalFilesAreReportedInPathOrder() throws {
        let creationOrder = [6, 3, 1, 5, 2, 4].map { "input:/f\($0).config" }
        for path in creationOrder {
            try writeConfigFile(path: path,
                                content: "swift.compier.sdkVersion=26.5",
                                prefixes: ["swift.compiler"])
        }

        engine.reportUnclaimedConfigKeys()

        XCTAssertEqual(captured.count, creationOrder.count)
        XCTAssertEqual(captured.compactMap { line in creationOrder.first { line.contains($0) } },
                       creationOrder.sorted())
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
