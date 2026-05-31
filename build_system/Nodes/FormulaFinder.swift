// FormulaFinder.swift
// build_system
//
// FormulaFinder monitors a directory for .yml formula files and wires each one
// up to a FormulaExtractor, which in turn feeds the formula text to BuildGraph.
// FormulaExtractor reads a formula file and passes its content through to BuildGraph.

import Foundation

// MARK: - FormulaFinder

/// Watches an input file-list stream and creates a FormulaExtractor child for
/// every formula.jsonl file that appears, wiring it into the BuildGraph's formulae input.
final class FormulaFinder: NodeType {
    static let kind: UInt = 5

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {}

    required init() {}

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    static let fileListInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                name: "fileList",
                                                                kind: .stream(dataType: .utf8Text),
                                                                maximumConnections: 1,
                                                                minimumConnections: 1,
                                                                cascadingDelete: false)

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.fileListInputPort], outputs: [])
    }

    func didAddFile(nodeID: ObjectID, name: String) throws {
        // Only handle .yml formula files.
        guard name.hasSuffix(".json") else { return } // HACK

        let extractor = try nodeContext.processingCycle.makeNode(name: name,
                                                                 parentNodeID: nodeContext.nodeID) as FormulaExtractor

        try nodeContext.processingCycle.connectWire(
            fromNode: try nodeContext.processingCycle.node(nodeID: nodeID) as StaticFileNode,
            fromPort: StaticFileNode.outputPort,
            toNode: extractor,
            toPort: FormulaExtractor.formulaFileInputPort)

        try nodeContext.processingCycle.connectWire(
            fromNode: extractor,
            fromPort: FormulaExtractor.formulaOutputPort,
            toNode: try nodeContext.processingCycle.rootNode.buildGraph,
            toPort: BuildGraph.formulaeInputPort)
    }

    func process() throws {
        guard let fileListStreamCursor = try readOneValueFromInputPort(Self.fileListInputPort) else {
            throw NodeError.missingInput
        }

        let data = try fileListStreamCursor.readBytesFromStream(nodeContext: nodeContext)

        guard !data.isEmpty else {
            throw NodeError.missingInput
        }

        let str = String(data: data, encoding: .utf8)!
        let chunks = str.split(separator: "\n\n")

        for chunk in chunks {
            print("\(chunk)")
            let object = try PolyFactory.decode(encodedJSON: String(chunk))
            
            if let folderEvent = object as? FolderEvent {
                switch folderEvent.folderEventKind {

                case .childAdded(let nodeID, let name):
                    try didAddFile(nodeID: nodeID, name: name)
                    break

                default:
                    break
                }
            }
        }

        // TODO: read folder-event messages from fileListInputPort and call didAddFile
        // for each .childAdded event. See the commented-out implementation for a sketch
        // of the stream-reading logic needed here.
    }
}

extension NodeValueAndWire {

    var currentLengthIfStream: UInt64? {
        switch kind {
        case .value(let payload, _):
            switch payload {
            case .stream(_, let currentLength):
                return currentLength
            case .dataObjectHash:
                return nil
            }
        case .noValue:
            return nil
        }
    }

    func readBytesFromStream(nodeContext: NodeContext) throws -> Data {
        let currentLength = currentLengthIfStream!
        var wire = wire

        let nodeOutputValue = try nodeContext.processingCycle.database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)!

        let data = try nodeOutputValue.readBytesFromStream(offset: UInt64(wire.streamPosition ?? 0), length: currentLength - UInt64(wire.streamPosition ?? 0))

        // Save new offset
        wire.streamPosition = Int64(currentLength)

        try nodeContext.processingCycle.database.updateWire(wire)
        return data
    }
}

// MARK: - FormulaExtractor

/// Reads a single formula.json file and passes its text content through to
/// BuildGraph's formulae input port.
final class FormulaExtractor: NodeType {
    static let kind: UInt = 6

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {}

    required init() {}

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    static let formulaFileInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                   name: "formulaFile",
                                                                   kind: .value(dataType: .json),
                                                                   maximumConnections: 1,
                                                                   minimumConnections: 1,
                                                                   cascadingDelete: true)

    static let formulaOutputPort = NodeKindDescriptor.OutputPort(index: 0,
                                                                 name: "formula",
                                                                 kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.formulaFileInputPort], outputs: [Self.formulaOutputPort])
    }

    func process() throws {
        for formulaFileValue in try readAllValuesFromInputPort(Self.formulaFileInputPort) {
            switch formulaFileValue.kind {
            case .noValue:
                break
            case .value(let payload, _):
                // Pass the formula content through unchanged.
                try writeToOutputPort(Self.formulaOutputPort,
                                      value: .value(.dataObjectHash(payload.expectDataObjectHash()),
                                                    metadata: FileMetadata(name: "formula")))
            }
        }
    }
}
