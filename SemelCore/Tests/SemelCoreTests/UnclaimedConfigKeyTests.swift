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
        let fileShape = try GraphShapeNode.parse("StaticFile(path: '\(path)')")
        let (fileNode, _) = try fileShape.findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(fileNode.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try file.intern())

        for prefix in prefixes {
            let shape = try GraphShapeNode.parse(
                "ConfigSubset(prefix: '\(prefix)', input: ['config': StaticFile(path: '\(path)').output]).output")
            _ = try shape.findOrCreateMatchingNode()
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
}
