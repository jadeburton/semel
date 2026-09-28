//
//  DependencyTreeWalkTests.swift
//  SemelCoreTests
//
//  B-94. `debug`'s dependency tree walks a graph, and a graph is not a tree: a header
//  wired into a thousand compiles is one node reached a thousand ways. A visited set kept
//  per node makes the walk enumerate the graph's *paths*, whose number grows with every
//  shared dependency, and the walk stops being something a prompt can wait for. These
//  pin the cost in visits, which a counter can assert, and pin the rendering: a node
//  appears in full once and is referenced afterwards.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class DependencyTreeWalkTests: SemelCoreTestCase {

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

    // MARK: - Helpers

    private var database: DatabaseLayer { engine.database }

    /// A node with no file system behind it, so a test graph is exactly the nodes it asks
    /// for, reading `inputs` by wire name.
    private func node(_ role: String, reading inputs: [String: GraphSpecNode] = [:]) -> GraphSpecNode {
        GraphSpecNode(TreeMerger.self, properties: ["role": role],
                      inputs: inputs.isEmpty ? [:] : [TreeMerger.inputPort: inputs]).port(TreeMerger.outputPort)
    }

    /// The node a tree describes, made as the engine makes it, with every node below it.
    private func make(_ specNode: GraphSpecNode) throws -> ObjectID {
        try specNode.findOrCreateMatchingNode().fromNode.requireID()
    }

    /// The graph's root for the walk: `debug` starts at the project finder, so a test
    /// graph reaches it by wiring its sink there.
    private func attachToProjectFinder(_ nodeID: ObjectID, name: String) throws {
        try Wire.connectWire(database: database,
                             fromNodeID: nodeID,
                             fromSymbolID: TreeMerger.outputPort.asSymbolID(),
                             toNodeID: try engine.projectFinder.requireID(),
                             toSymbolID: TreeMerger.inputPort.asSymbolID(),
                             name: name.asSymbolID())
    }

    private func walkTheTree() -> (lines: [String], walk: DependencyTreeWalk) {
        let text = TextBuffer()
        let walk = engine.appendDependencyTree(to: text)
        return (text.lines, walk)
    }

    private func count(_ treeLines: [String], endingWith suffix: String) -> Int {
        treeLines.filter { $0.hasSuffix(suffix) }.count
    }

    // MARK: - Sharing

    /// One node, two hundred consumers, one sink. The shared node belongs in the tree
    /// once; the other 199 encounters are references to it.
    func test_aSharedDependencyIsRenderedOnceAndReferencedAfterwards() throws {
        let consumerCount = 200
        let sharedTree = node("shared")
        var consumers: [String: GraphSpecNode] = [:]
        for index in 0..<consumerCount {
            consumers["consumer\(index)"] = node("consumer\(index)", reading: ["shared\(index)": sharedTree])
        }
        let sink   = try make(node("sink", reading: consumers))
        let shared = try make(sharedTree)
        try attachToProjectFinder(sink, name: "sink")

        let (lines, walk) = walkTheTree()

        XCTAssertEqual(count(lines, endingWith: ") \(shared)"), 1,
                       "the shared node belongs in the tree once")
        XCTAssertEqual(count(lines, endingWith: ") \(shared)  (see above)"), consumerCount - 1,
                       "every later encounter is a reference to it")

        // Nodes and wires, not paths: 202 nodes of this test's own, 400 wires between
        // them, and the project finder above the sink.
        XCTAssertLessThan(walk.visits, 4 * (consumerCount + 400),
                          "the walk must visit nodes, not paths")
    }

    /// A chain of diamonds: ten levels, each one doubling the number of distinct paths
    /// from the sink down to the source. 31 nodes, 41 wires, 1,024 paths — a walk that
    /// counts paths does about four thousand visits here, and about a million at twenty
    /// levels, which is what a prepared app's graph looks like.
    func test_theWalkCostsNodesAndWiresRatherThanPaths() throws {
        let levels = 10
        var current = node("level0")
        var nodeCount = 1
        var wireCount = 0

        for level in 1...levels {
            let left  = node("left\(level)", reading: ["left\(level)": current])
            let right = node("right\(level)", reading: ["right\(level)": current])
            current    = node("join\(level)", reading: ["joinLeft\(level)": left, "joinRight\(level)": right])
            nodeCount += 3
            wireCount += 4
        }
        try attachToProjectFinder(try make(current), name: "top")
        wireCount += 1

        let (lines, walk) = walkTheTree()

        XCTAssertLessThan(walk.visits, 4 * (nodeCount + wireCount),
                          "\(nodeCount) nodes and \(wireCount) wires, but \(walk.visits) visits")
        XCTAssertLessThan(lines.count, 4 * nodeCount,
                          "a node is rendered once, so the tree is as long as the graph")
    }

    // MARK: - Acceptance

    /// B-94's acceptance, in the shape that produced it: 1,019 nodes in layers, each one
    /// depending on two of the layer below, so every node is shared by two consumers and
    /// the paths from the sink number in the tens of thousands. The whole `debug` text —
    /// node dump and tree — has to come back in a time a prompt can wait for, and the walk
    /// behind it has to cost nodes and wires. The visit bound is what proves the second;
    /// the clock is loose enough for a shared runner and still four times under the twelve
    /// seconds this fixture took when the walk counted paths.
    func test_describesAThousandNodeGraphInATimeAPromptCanWaitFor() throws {
        let width  = 113
        let layers = 9
        let shared = node("sharedHeader")

        var previousLayer = [GraphSpecNode]()
        for layer in 0..<layers {
            var thisLayer = [GraphSpecNode]()
            for index in 0..<width {
                let inputs = layer == 0
                    ? ["header": shared]
                    : ["left": previousLayer[index], "right": previousLayer[(index + 1) % width]]
                thisLayer.append(node("layer\(layer)-\(index)", reading: inputs))
            }
            previousLayer = thisLayer
        }

        var top: [String: GraphSpecNode] = [:]
        for (index, layerNode) in previousLayer.enumerated() {
            top["top\(index)"] = layerNode
        }
        try attachToProjectFinder(try make(node("sink", reading: top)), name: "sink")

        let nodeCount = try database.node.selectAll().count
        let wireCount = try database.wire.selectAll().count
        XCTAssertGreaterThanOrEqual(nodeCount, 1019, "the fixture is the size B-94 names")

        let start = Date.now
        let text  = try engine.graphDescription()
        let taken = Date.now.timeIntervalSince(start)

        XCTAssertFalse(text.isEmpty)
        // The counter is the proof: it holds on any machine at any load, where the clock
        // below is a sanity check with room for a shared CI runner.
        let (_, walk) = walkTheTree()
        XCTAssertLessThan(walk.visits, 4 * (nodeCount + wireCount),
                          "\(nodeCount) nodes and \(wireCount) wires, but \(walk.visits) visits")
        XCTAssertLessThan(taken, 3.0, "describing \(nodeCount) nodes took \(taken)s")
    }
}
