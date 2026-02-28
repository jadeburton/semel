//
//  NodeFactory.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

final class NodeFactory {
    func makeNode(kind: UInt, encodedJSON: String?) throws -> NodeType {
        switch kind {

        case RootNode.kind: return try RootNode.fromJSONString(encodedJSON)
        case CommandInterpreter.kind: return try CommandInterpreter.fromJSONString(encodedJSON)
        case FormulaFinder.kind: return try FormulaFinder.fromJSONString(encodedJSON)
        case FormulaExtractor.kind: return try FormulaExtractor.fromJSONString(encodedJSON)
        case BuildGraph.kind: return try BuildGraph.fromJSONString(encodedJSON)
        case StaticFileNode.kind: return try StaticFileNode.fromJSONString(encodedJSON)
        case FolderNode.kind: return try FolderNode.fromJSONString(encodedJSON)

        default:
            fatalError("Unknown Node kind: \(kind)")
            break
        }
    }
}
