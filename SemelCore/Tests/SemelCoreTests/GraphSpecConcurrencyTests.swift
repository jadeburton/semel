//
//  GraphSpecConcurrencyTests.swift
//  SemelCoreTests
//
//  findOrCreateMatchingNode resolves an existing node without entering a transaction, and
//  enters one only to create. The two halves have opposite hazards, so both are exercised
//  here under real threads rather than reasoned about.
//
//  The create half has a recorded history: doing the find outside a transaction and then
//  inserting is what produced "UNIQUE constraint failed: Node.identity", because two tasks
//  both saw nil and both inserted. The read added in front must not bring that back.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class GraphSpecConcurrencyTests: SemelCoreTestCase {

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

    /// Collects results from concurrent threads without racing on the collection itself.
    private final class Collected {
        private let lock = NSLock()
        private(set) var ids: [ObjectID] = []
        private(set) var failures: [String] = []

        func record(_ id: ObjectID) { lock.lock(); ids.append(id); lock.unlock() }
        func record(error: Error) { lock.lock(); failures.append("\(error)"); lock.unlock() }
    }

    /// Many threads asking for the same spec must produce one node, not one each and not a
    /// unique-constraint crash. This is the case the transaction exists for.
    func test_concurrentResolutionOfOneShapeCreatesExactlyOneNode() throws {
        let specText = "SettingsLiteral(role: 'contended').output"
        let collected = Collected()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                let spec = try GraphSpecNode.parse(specText)
                collected.record(try spec.findOrCreateMatchingNode().fromNode.requireID())
            } catch {
                collected.record(error: error)
            }
        }

        XCTAssertEqual(collected.failures, [], "no resolution should fail")
        XCTAssertEqual(collected.ids.count, 64)
        XCTAssertEqual(Set(collected.ids).count, 1,
                       "every caller must get the same node, got \(Set(collected.ids).count) distinct")
    }

    /// Different specs at the same time, so the create path is genuinely contended rather
    /// than one insert and sixty-three fast-path reads.
    func test_concurrentResolutionOfDistinctShapesCreatesOneNodeEach() throws {
        let collected = Collected()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                let spec = try GraphSpecNode.parse("SettingsLiteral(role: 'r\(index)').output")
                collected.record(try spec.findOrCreateMatchingNode().fromNode.requireID())
            } catch {
                collected.record(error: error)
            }
        }

        XCTAssertEqual(collected.failures, [])
        XCTAssertEqual(Set(collected.ids).count, 32, "each distinct spec is its own node")
    }

    /// The root cache is a mutable static reached from every one of these threads. Reading a
    /// Dictionary while another thread writes it is undefined rather than merely stale, so
    /// this exercises it under contention alongside everything else.
    func test_concurrentRootResolutionIsStable() throws {
        let collected = Collected()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                collected.record(try Folder.inputFileSystem.requireID())
            } catch {
                collected.record(error: error)
            }
        }

        XCTAssertEqual(collected.failures, [])
        XCTAssertEqual(Set(collected.ids).count, 1, "there is one input file system root")
    }
}
