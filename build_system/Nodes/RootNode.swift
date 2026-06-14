//
//  RootNode.swift
//  build_system
//
//  Created by Jade Burton on 28.02.26.
//

import Foundation

struct RootNode: NodeFunction {

    static let kind: UInt = 10

    enum CodingKeys: CodingKey {
    }

    init() {
    }

    init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    // MARK: Ports

    // Receives partial or complete schemas from multiple Nodes, merges them and synchronizes the actual Wires and Nodes with the schemas.
    // Note that all Nodes with a schemaOutput are automatically wired to RootNode.schemaInput when they are created.
    /*
     
    ClangCompiler rootNode/buildGraph/compiler(src/blah/hello.c)
     
    Wire rootNode/buildGraph/compiler(src/blah/hello.c) --> rootNode/buildGraph/inputFileSystem/src/blah/hello.c
     
     */
    
//    static let schemaInputPort = InputPort(index: 0,
//                                                              name: "schemaInput",
//                                                              kind: .value(dataType: .utf8Text),
//                                                              maximumConnections: nil,
//                                                              minimumConnections: 0,
//                                                              cascadingDelete: false)

    /*

    Contains a full merged schema of all Wires and Nodes. There are no NodeIDs or WireIDs.

     */
//    static let schemaOutputPort = OutputPort(index: 0,
//                                                                name: "schemaOutput",
//                                                                kind: .value(dataType: .utf8Text))
//
//    static let descriptor = NodeFunctionDescriptor(kind: kind, inputs: [schemaInputPort], outputs: [schemaOutputPort])

//    func didSave() throws {
        // TODO!
//        try nodeContext.processingCycle.connectWire(fromNode: try inputFileSystem,
//                                                    fromPort: FolderNode.folderManifestOutputPort,
//                                                    toNode: try formulaFinder,
//                                                    toPort: ProjectFinder.folderManifestInputPort)
 //   }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }
/*
    var inputFileSystem: Node {
        get throws {
            try child(named: "inputFileSystem", createIfNotExist: true)!
        }
    }

    var outputFileSystem: Node {
        get throws {
            try child(named: "outputFileSystem", createIfNotExist: true)!
        }
    }

    var projectFinder: Node {
        get throws {
            try child(named: "projectFinder", createIfNotExist: true)!
        }
    }
*/
    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [], dynamicInputPorts: [])

    func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.processNotSupported
    }

    // MARK: Debug
/*
    func debugPrintTree() {
        do {
            let projectFinder = try projectFinder
            let topLevelOutputNodes = try nodeContext.processingCycle.allChildNodes(nodeID: projectFinder.nodeID)

            print("- build tree")
            for outputNode in topLevelOutputNodes {
                printDependencyTree(node: outputNode, indentLevel: 1)
            }
        } catch {
            print("- build tree (error: \(error))")
        }
    }

    private func printDependencyTree(node: NodeFunction, indentLevel: Int) {
        let indent = String(repeating: "  ", count: indentLevel)
        let kindName = (try? PolyFactory.type(kind: type(of: node).kind))
            .map { String(describing: $0) } ?? "Node"
        let nodeName = node.nodeContext.name ?? "?"
        print("\(indent)- \(kindName)(\(nodeName))")

        let database = nodeContext.processingCycle.database
        guard let nodeID = node.nodeContext.nodeID else { return }

        do {
            let incomingWires = try database.selectWires(goingToNodeID: nodeID)

            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [NodeFunction]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let rawNode = try? database.selectNodeByID(wire.fromNodeID),
                   let dependencyNode = try? nodeContext.processingCycle.nodeFunction(nodeRaw: rawNode) {
                    dependencyNodes.append(dependencyNode)
                }
            }

            for dependencyNode in dependencyNodes {
                printDependencyTree(node: dependencyNode, indentLevel: indentLevel + 1)
            }
        } catch {
            print("\(indent)  (error loading dependencies: \(error))")
        }
    }*/
}
