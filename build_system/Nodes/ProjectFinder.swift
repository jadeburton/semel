// ProjectFinder.swift
// build_system
//
// ProjectFinder monitors a directory for .yml formula files and wires each one
// up to a FormulaExtractor, which in turn feeds the formula text to BuildGraph.
// FormulaExtractor reads a formula file and passes its content through to BuildGraph.

import Foundation

// MARK: - ProjectFinder

/// Watches an input file-list stream and creates a FormulaExtractor child for
/// every formula.json file that appears, wiring it into the BuildGraph's formulae input.
final class ProjectFinder: NodeFunction {
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

    static let folderManifestInputPort = "folderManifest"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [folderManifestInputPort], staticOutputPorts: [])

    private func ensureExtractorExists(folderManifestEntry: FolderManifestEntry, folderNode: FolderNode) throws {

        guard folderManifestEntry.name.hasSuffix(".json") else {
            return
        } // HACK

        let extractor = try childPoly(path: folderManifestEntry.name, kind: FormulaExtractor.kind, createIfNotExist: true)! as! FormulaExtractor

        let fileNode = try folderNode.childPoly(path: folderManifestEntry.name, kind: StaticFileNode.kind) as! StaticFileNode

        try nodeContext.processingCycle.connectWire(
            fromNodeID: fileNode.nodeID,
            fromPortNameID: StaticFileNode.outputPort.asPortNameID(),
            toNodeID: extractor.nodeID,
            toPortNameID: FormulaExtractor.formulaFileInputPort.asPortNameID(),
            name: folderManifestEntry.name.asPortNameID())

        #warning("TODO")
//        try nodeContext.processingCycle.connectWire(
//            fromNodeID: extractor.nodeID,
//            fromPortNameID: FormulaExtractor.formulaOutputPort.asPortNameID(),
//            toNodeID: try nodeContext.processingCycle.rootNode.buildGraph.nodeID,
//            toPortNameID: BuildGraph.formulaeInputPort.asPortNameID())
    }

    func process() throws {
        let oneValue = try readOneValueFromInputPort(Self.folderManifestInputPort)
        let folderNode: FolderNode = try nodeContext.processingCycle.node(nodeID: oneValue.originNodeID)
        let object = try PolyFactory.decode(encodedJSON: oneValue.dataObjectHash.resolveAsString())

        guard let folderManifest = object as? FolderManifest else {
            throw NodeError.other(message: "Could not decode FolderManifest")
        }

        for entry in folderManifest.entries {
            try ensureExtractorExists(folderManifestEntry: entry, folderNode: folderNode)
        }

        for formulaExtractorChild in try allChildren().filter({ node in node is FormulaExtractor }) {
            if !folderManifest.entries.contains(where: { $0.name == formulaExtractorChild.nodeContext.name }) {
                try formulaExtractorChild.delete()
            }
        }

    }
}

// MARK: - FormulaExtractor

/// Reads a single formula.json file and passes its text content through to
/// BuildGraph's formulae input port.
final class FormulaExtractor: NodeFunction {
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

    static let formulaFileInputPort = "formulaFile"
    static let formulaOutputPort = "formula"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [formulaFileInputPort], staticOutputPorts: [formulaOutputPort])

    func process() throws {
        for formulaFileValue in try readAllValuesFromInputPort(Self.formulaFileInputPort) {
            switch formulaFileValue.value.kind {
            case .noValue:
                break
            case .value(let dataObjectHash):
                // Pass the formula content through unchanged.
                try writeToOutputPort(Self.formulaOutputPort, value: .value(dataObjectHash))
            }
        }
    }
}
