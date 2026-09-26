//
//  UnclaimedConfigKeyTests.swift
//  SemelCoreTests
//
//  A key in a config file that no node selected.
//
//  A misspelt setting changes nothing and says nothing, which is the failure the old per-tool
//  check existed to prevent. A selector cannot see it — it only knows what it was asked for —
//  but the graph can: the wires from a config file lead to every node that claimed part of it.
//
//  This reports a key only when it matches no selector's prefix at all. It cannot also catch a
//  misspelt key *under* a correct prefix (`swift.compiler.sdkVerison` when `swift.compiler` IS
//  selected) — telling those apart would require knowing which keys each tool actually reads,
//  which is exactly the per-type key list this design deleted.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class UnclaimedConfigKeyTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    /// Builds a config file with two selectors reading it, and returns what nobody claimed.
    private func unclaimed(file: String, prefixes: [String]) throws -> [String] {
        let path = "input:/semel.config"
        let fileShape = try GraphSpecNode.parse("StaticFile(path: '\(path)')")
        let (fileNode, _) = try fileShape.findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(fileNode.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try file.intern())

        for prefix in prefixes {
            let spec = try GraphSpecNode.parse(
                "ConfigFilter(prefix: '\(prefix)', input: ['config': StaticFile(path: '\(path)').output]).output")
            _ = try spec.findOrCreateMatchingNode()
        }

        return try engine.unclaimedConfigKeys(inFileNodeID: fileNode.requireID())
    }

    func test_aKeyUnderAClaimedPrefixIsNotReported() throws {
        let result = try unclaimed(file: "swift.compiler.sdkVersion=26.5",
                                   prefixes: ["swift.compiler"])

        XCTAssertEqual(result, [])
    }

    /// A misspelt prefix, which the old per-tool accepted-set check could never have seen.
    func test_aKeyUnderAPrefixNobodySelectedIsReported() throws {
        let result = try unclaimed(file: "swift.compier.sdkVersion=26.5",
                                   prefixes: ["swift.compiler"])

        XCTAssertEqual(result, ["swift.compier.sdkVersion"])
    }

    /// A file that reaches its selectors through a `ConfigMerger` — the shape every prelude
    /// formula has, the project's file over the machine's (B-109) — is read through it:
    /// the filter below the merger claims its prefix, and only the misspelt key is left.
    func test_aFileIsFollowedThroughAMergerToItsSelectors() throws {
        let project = "input:/semel.config"
        let (fileNode, _) = try GraphSpecNode.parse("StaticFile(path: '\(project)')").findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(fileNode.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try "swift.compiler.sdkVersion=26.5\nswift.compier.target=arm64".intern())

        let merged = "ConfigMerger(base: ['machine': StaticFile(path: 'input:/semel.machine.config').output], "
                   + "override: ['project': StaticFile(path: '\(project)').output]).output"
        _ = try GraphSpecNode.parse("ConfigFilter(prefix: 'swift.compiler', input: ['config': \(merged)]).output")
            .findOrCreateMatchingNode()

        XCTAssertEqual(try engine.unclaimedConfigKeys(inFileNodeID: fileNode.requireID()), ["swift.compier.target"])
    }
}
