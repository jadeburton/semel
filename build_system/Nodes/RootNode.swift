//
//  RootNode.swift
//  build_system
//
//  Created by Jade Burton on 28.02.26.
//

import Foundation

struct RootNode: InputlessNodeFunction {

    static let kind: UInt = 10

    enum CodingKeys: CodingKey {
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [], dynamicInputPorts: [])

    // MARK: Debug

    func debugPrintTree() {
        do {
            print("- build tree")
            printDependencyTree(node: try Node.projectFinder, indentLevel: 1)
        } catch {
            print("- build tree (error: \(error))")
        }
    }

    private func printDependencyTree(node: Node, indentLevel: Int) {
        let indent = String(repeating: "  ", count: indentLevel)
        let nodeFunction = try! node.nodeFunction()

        let kindName = (try? PolyFactory.type(kind: type(of: nodeFunction).kind))
            .map { String(describing: $0) } ?? "Node"

        let nodeName = node.name ?? "?"
        print("\(indent)- \(kindName)(\(nodeName))")

        guard let nodeID = node.id else { return }

        do {
            let incomingWires = try DatabaseLayer.shared.selectWires(goingToNodeID: nodeID)

            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [Node]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let rawNode = try? DatabaseLayer.shared.selectNodeByID(wire.fromNodeID) {
                    dependencyNodes.append(rawNode)
                }
            }

            for dependencyNode in dependencyNodes {
                printDependencyTree(node: dependencyNode, indentLevel: indentLevel + 1)
            }
        } catch {
            print("\(indent)  (error loading dependencies: \(error))")
        }
    }
}
