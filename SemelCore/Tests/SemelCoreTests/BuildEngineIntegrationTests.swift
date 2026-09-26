//
//  BuildEngineIntegrationTests.swift
//  semel_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

// MARK: - Helpers

private func makeEngine() throws -> BuildEngine {
    let database = try DatabaseLayer()
    let engine   = try BuildEngine(database: database, startProcessingLoop: false)
    BuildEngine.shared = engine
    return engine
}

// MARK: - Cascade deletion

/// Verifies that `processPendingDeletions` cascades upward through the dependency
/// graph: when a consumer node is removed, source nodes that have no remaining
/// consumers are also cleaned up.
final class CascadeDeletionTests: SemelCoreTestCase {

    var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try makeEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // Creates a Configuration node with the given role property so tests can
    // build distinguishable nodes without the file-system plumbing that
    // StaticFile requires.
    private func makeConfiguration(role: String) throws -> NodeRecord {
        let spec = try GraphSpecNode.parse("Configuration(role: '\(role)').output")
        let (node, _) = try spec.findOrCreateMatchingNode()
        return node
    }

    private func wire(_ source: NodeRecord, to consumer: NodeRecord, name: String) throws {
        try Wire.connectWire(database: engine.database,
                             fromNodeID: source.id!,
                             fromSymbolID: "output".asSymbolID(),
                             toNodeID:   consumer.id!,
                             toSymbolID: "base".asSymbolID(),
                             name: name.asSymbolID())
    }

    private func runCleanup() throws {
        var processed = 0
        repeat {
            processed = try engine.processPendingDeletions()
        } while processed > 0
    }

    private func nodeExists(_ node: NodeRecord) -> Bool {
        (try? engine.database.node.select(nodeID: node.id!)) != nil
    }

    // When a consumer is marked pendingDeletion, processPendingDeletions
    // should delete it and mark its (now-orphaned) source for deletion too.
    func test_cascadeDeletion_orphansUpstreamNode() throws {
        let source   = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")

        try wire(source, to: consumer, name: "link")

        try engine.database.node.updatePendingDeletion(nodeID: consumer.id!, pendingDeletion: true)
        try runCleanup()

        XCTAssertFalse(nodeExists(consumer), "consumer should be deleted")
        XCTAssertFalse(nodeExists(source),   "orphaned source should cascade-delete")
    }

    // A three-node chain A → B → C: removing C should cascade all the way to A.
    func test_cascadeDeletion_threeNodeChain_allRemoved() throws {
        let nodeA = try makeConfiguration(role: "A")
        let nodeB = try makeConfiguration(role: "B")
        let nodeC = try makeConfiguration(role: "C")

        try wire(nodeA, to: nodeB, name: "a_b")
        try wire(nodeB, to: nodeC, name: "b_c")

        try engine.database.node.updatePendingDeletion(nodeID: nodeC.id!, pendingDeletion: true)
        try runCleanup()

        XCTAssertFalse(nodeExists(nodeC), "C should be deleted")
        XCTAssertFalse(nodeExists(nodeB), "B should cascade-delete after C is gone")
        XCTAssertFalse(nodeExists(nodeA), "A should cascade-delete after B is gone")
    }

    // A source shared by two consumers must not be deleted when only one
    // consumer is removed; it still has a live downstream wire.
    func test_cascadeDeletion_sharedSource_survivesPartialRemoval() throws {
        let source    = try makeConfiguration(role: "shared")
        let consumer1 = try makeConfiguration(role: "c1")
        let consumer2 = try makeConfiguration(role: "c2")

        try wire(source, to: consumer1, name: "to_c1")
        try wire(source, to: consumer2, name: "to_c2")

        try engine.database.node.updatePendingDeletion(nodeID: consumer1.id!, pendingDeletion: true)
        try runCleanup()

        XCTAssertFalse(nodeExists(consumer1), "consumer1 should be deleted")
        XCTAssertTrue(nodeExists(source),     "shared source should survive (consumer2 still wired)")
        XCTAssertTrue(nodeExists(consumer2),  "consumer2 should be unaffected")
    }

    // Removing both consumers of a shared source should eventually clean it up.
    func test_cascadeDeletion_sharedSource_deletedAfterAllConsumersRemoved() throws {
        let source    = try makeConfiguration(role: "shared")
        let consumer1 = try makeConfiguration(role: "c1")
        let consumer2 = try makeConfiguration(role: "c2")

        try wire(source, to: consumer1, name: "to_c1")
        try wire(source, to: consumer2, name: "to_c2")

        try engine.database.node.updatePendingDeletion(nodeID: consumer1.id!, pendingDeletion: true)
        try engine.database.node.updatePendingDeletion(nodeID: consumer2.id!, pendingDeletion: true)
        try runCleanup()

        XCTAssertFalse(nodeExists(consumer1), "consumer1 should be deleted")
        XCTAssertFalse(nodeExists(consumer2), "consumer2 should be deleted")
        XCTAssertFalse(nodeExists(source),    "source should cascade-delete once both consumers are gone")
    }
}

// MARK: - findMatchingNode invariant
//
// The false-positive topology fix in applySpecs relies on a
// guarantee: parsing the same spec string twice must produce a spec
// whose findMatchingNode() returns the node that was created the first time.
// These tests verify that guarantee holds.

final class FindMatchingNodeTests: SemelCoreTestCase {

    var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try makeEngine()
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // Parsing the same spec string twice must return the same node.
    func test_findMatchingNode_sameString_returnsSameNode() throws {
        let spec = "Configuration(env: 'test').output"
        let (node, portID) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        let match = try GraphSpecNode.parse(spec).findMatchingNode()

        XCTAssertEqual(match?.fromNodeID,    node.id!, "findMatchingNode must return the same node")
        XCTAssertEqual(match?.fromSymbolID,  portID,   "output port symbol must match")
    }

    // Two nodes with different args must produce different graph specs and
    // therefore not collide.
    func test_findMatchingNode_differentArgs_returnsDifferentNodes() throws {
        let (nodeA, _) = try GraphSpecNode.parse("Configuration(env: 'debug').output").findOrCreateMatchingNode()
        let (nodeB, _) = try GraphSpecNode.parse("Configuration(env: 'release').output").findOrCreateMatchingNode()

        XCTAssertNotEqual(nodeA.id!, nodeB.id!)

        let matchA = try GraphSpecNode.parse("Configuration(env: 'debug').output").findMatchingNode()
        let matchB = try GraphSpecNode.parse("Configuration(env: 'release').output").findMatchingNode()

        XCTAssertEqual(matchA?.fromNodeID, nodeA.id!)
        XCTAssertEqual(matchB?.fromNodeID, nodeB.id!)
    }

    // A node that has not been created yet must not be found.
    func test_findMatchingNode_unknownNode_returnsNil() throws {
        let match = try GraphSpecNode.parse("Configuration(env: 'nonexistent').output").findMatchingNode()
        XCTAssertNil(match)
    }

    // After a node is cascade-deleted it must no longer be findable.
    func test_findMatchingNode_deletedNode_returnsNil() throws {
        let spec = "Configuration(env: 'temporary').output"
        let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        // Mark the node pendingDeletion and run cleanup.
        try engine.database.node.updatePendingDeletion(nodeID: node.id!, pendingDeletion: true)
        var processed = 0
        repeat { processed = try engine.processPendingDeletions() } while processed > 0

        let match = try GraphSpecNode.parse(spec).findMatchingNode()
        XCTAssertNil(match, "deleted node must not be found by findMatchingNode")
    }
}

// MARK: - Formula parsing error handling

final class FormulaMalformedTests: SemelCoreTestCase {

    private func parse(_ source: String) throws -> [String: GraphSpecNode] {
        try FormulaFile.parse(source, basePath: Path("."), wildcardExpander: { _ in [] })
    }

    func test_parse_unterminatedString_throws() {
        XCTAssertThrowsError(try parse("product \"X\" = StaticFile(path: 'missing_quote)"))
    }

    func test_parse_missingClosingParen_throws() {
        XCTAssertThrowsError(try parse("product \"X\" = StaticFile(path: 'hello.c'"))
    }

    func test_parse_unknownTopLevelToken_throws() {
        XCTAssertThrowsError(try parse("notAKeyword stuff"))
    }

    func test_parse_productResolvesToNonNodeValue_throws() {
        XCTAssertThrowsError(try parse("""
            func raw() = 'just a string'
            product "X" = raw()
            """))
    }

    func test_parse_undefinedIdentifier_throws() {
        XCTAssertThrowsError(try parse("product \"X\" = StaticFile(path: missing)"))
    }

    // A formula with no products at all is valid (empty result map).
    func test_parse_emptyFormula_returnsEmptyDict() throws {
        let result = try parse("// only comments\n")
        XCTAssertTrue(result.isEmpty)
    }

    // Products defined after a syntax error in a separate product still parse
    // the valid part — but currently the whole parse fails.  This test documents
    // the current behaviour (all-or-nothing parse).
    func test_parse_syntaxErrorInOneProduct_failsEntireFile() {
        XCTAssertThrowsError(try parse("""
            product "Good" = StaticFile(path: 'ok').output
            product "Bad"  = StaticFile(path: 'unterminated)
            """))
    }
}
