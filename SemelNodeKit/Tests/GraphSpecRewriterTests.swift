//
//  GraphSpecRewriterTests.swift
//  SemelNodeKitTests
//
//  B-155. A rewrite of every node of a demanded tree visits each distinct subtree once and
//  gives every occurrence of it the one rewritten copy, so the tree it returns shares what
//  the tree it was given shared. A walk that rebuilt each occurrence returned the tree
//  spelled out, six gigabytes of it for Sequel Ace's products.
//

@testable import SemelNodeKit
import XCTest

final class GraphSpecRewriterTests: XCTestCase {

    /// A node with `role: <name>` and the given wires on one port, read at `output`.
    private func node(_ name: String, _ wires: [String: GraphSpecNode] = [:]) -> GraphSpecNode {
        GraphSpecNode(typeName: "Tool", properties: [GraphSpecProperty(key: "role", value: name)],
                      inputs: wires.isEmpty ? [] : [GraphSpecInputPort(portName: "input", wires: wires
                          .sorted { $0.key < $1.key }
                          .map { GraphSpecWire(name: $0.key, node: $0.value) })],
                      outputPort: "output")
    }

    /// The node a wire named `name` of `specNode` comes from.
    private func source(_ name: String, of specNode: GraphSpecNode) throws -> GraphSpecNode {
        try XCTUnwrap(specNode.inputs.first?.wires.first { $0.name == name }?.node)
    }

    /// Whether two nodes hold their inputs in one array's storage: what a copy of one value
    /// does, and what two values built apart never do.
    private func shareStorage(_ lhs: GraphSpecNode, _ rhs: GraphSpecNode) -> Bool {
        lhs.inputs.withUnsafeBufferPointer { left in
            rhs.inputs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    /// The rewrite every test here makes: the node's role marked, so a node rewritten is
    /// told from one that was not.
    private func marking() -> GraphSpecRewriter {
        GraphSpecRewriter { $0.addingToItself(property: "marked", value: "yes", where: { _ in true }) }
    }

    /// A chain of 48 levels, each wired twice to the one below, is 2^48 occurrences of the
    /// bottom node: a walk that rebuilt each occurrence would never finish. Rewriting each
    /// distinct subtree once is 49 rewrites.
    func test_aSubtreeMetAgainIsRewrittenOnce() throws {
        let depth = 48
        var level = node("bottom")
        for index in 0..<depth {
            level = node("level \(index)", ["left": level, "right": level])
        }
        var rewriter = marking()

        let rewritten = rewriter.rewrite(level)

        XCTAssertEqual(rewriter.rewrittenCount, depth + 1)
        XCTAssertTrue(rewritten.properties.contains(GraphSpecProperty(key: "marked", value: "yes")))
    }

    /// The two occurrences of a recurring subtree come back as one value, its storage
    /// shared, as they went in.
    func test_aRecurringSubtreeComesBackAsOneSharedCopy() throws {
        let shared = node("shared", ["leaf": node("leaf")])
        var rewriter = marking()

        let rewritten = rewriter.rewrite(node("top", ["left": shared, "right": shared]))

        let left  = try source("left", of: rewritten)
        let right = try source("right", of: rewritten)
        XCTAssertTrue(shareStorage(left, right))
        XCTAssertTrue(left.properties.contains(GraphSpecProperty(key: "marked", value: "yes")))
    }

    /// Two equal subtrees built apart are rewritten once and come back sharing: what two
    /// products that each call one formula function give a builder.
    func test_equalSubtreesBuiltApartAreRewrittenOnce() throws {
        let first  = node("shared", ["leaf": node("leaf")])
        let second = node("shared", ["leaf": node("leaf")])
        XCTAssertFalse(shareStorage(first, second))
        var rewriter = marking()

        let rewritten = rewriter.rewrite(node("top", ["left": first, "right": second]))

        XCTAssertEqual(rewriter.rewrittenCount, 3)
        XCTAssertTrue(shareStorage(try source("left", of: rewritten), try source("right", of: rewritten)))
    }

    /// What the rewrite returns is what rewriting every occurrence would: the sharing is the
    /// only difference, and it is invisible to `==`.
    func test_theRewriteIsTheOneEveryOccurrenceRewrittenGives() throws {
        let shared = node("shared", ["leaf": node("leaf")])
        let tree   = node("top", ["left": shared, "right": node("middle", ["inner": shared])])
        func rewrittenEachTime(_ specNode: GraphSpecNode) -> GraphSpecNode {
            let inputs = specNode.inputs.map { port in
                GraphSpecInputPort(portName: port.portName,
                                   wires: port.wires.map { GraphSpecWire(name: $0.name, node: rewrittenEachTime($0.node)) })
            }
            return GraphSpecNode(typeName: specNode.typeName, properties: specNode.properties, inputs: inputs,
                                 outputs: specNode.outputs, outputPort: specNode.outputPort)
                .addingToItself(property: "marked", value: "yes", where: { _ in true })
        }
        var rewriter = marking()

        XCTAssertEqual(rewriter.rewrite(tree), rewrittenEachTime(tree))
    }

    /// `adding(property:)` goes through the rewrite, so a chain that would never finish
    /// node by node is stamped at once.
    func test_addingAPropertyToARecurringChainFinishes() throws {
        var level = node("bottom")
        for index in 0..<48 {
            level = node("level \(index)", ["left": level, "right": level])
        }

        let stamped = level.adding(property: "projectRoot", value: "input:/repo") { _ in true }

        XCTAssertTrue(stamped.properties.contains(GraphSpecProperty(key: "projectRoot", value: "input:/repo")))
        XCTAssertTrue(shareStorage(try source("left", of: stamped), try source("right", of: stamped)))
    }
}
