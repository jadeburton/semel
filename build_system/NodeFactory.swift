//
//  NodeFactory.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

final class NodeFactory {
    func makeNode(kind: UInt, encodedJSON: String?) throws -> NodeType {
        switch kind {

        case CommandInterpreter.kind: return try CommandInterpreter.fromJSONString(encodedJSON)
        case Product.kind: return try Product.fromJSONString(encodedJSON)
        case StaticFileNode.kind: return try StaticFileNode.fromJSONString(encodedJSON)

        default:
            fatalError("Unknown Node kind: \(kind)")
            break
        }
    }
}
