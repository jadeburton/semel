// ProjectFinder.swift
// build_system
//
// ProjectFinder monitors a directory for .yml formula files and wires each one
// up to a ProjectBuilder, which in turn feeds the formula text to BuildGraph.
// ProjectBuilder reads a formula file and passes its content through to BuildGraph.

import Foundation

// MARK: - ProjectFinder

/// Watches an input file-list stream and creates a ProjectBuilder child for
/// every formula.json file that appears, wiring it into the BuildGraph's formulae input.
struct ProjectFinder: NodeFunction {
    static let kind: UInt = 5

    enum CodingKeys: CodingKey {
    }

    static let folderManifestInputPort = "folderManifest"
    static let projectBuildersInputPort = "projectBuilders"

    // ProjectFinder uses all dynamic ports because there is nobody to wire up static input ports, as it is the first.
    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [], dynamicInputPorts: [folderManifestInputPort, projectBuildersInputPort])
/*
    private func ensureExtractorExists(folderManifestEntry: FolderManifestEntry, folderNode: Folder) throws {

        guard folderManifestEntry.name.hasSuffix(".json") else {
            return
        } // HACK

        let extractor = try childPoly(path: folderManifestEntry.name, kind: ProjectBuilder.kind, createIfNotExist: true)! as! ProjectBuilder

        let fileNode = try folderNode.childPoly(path: folderManifestEntry.name, kind: StaticFile.kind) as! StaticFile

        try connectWire(
            fromNodeID: fileNode.nodeID,
            fromSymbolID: StaticFile.outputPort.asSymbolID(),
            toNodeID: extractor.nodeID,
            toSymbolID: ProjectBuilder.formulaFileInputPort.asSymbolID(),
            name: folderManifestEntry.name.asSymbolID())

        #warning("TODO")
//        try connectWire(
//            fromNodeID: extractor.nodeID,
//            fromSymbolID: ProjectBuilder.formulaOutputPort.asSymbolID(),
//            toNodeID: try rootNode.buildGraph.nodeID,
//            toSymbolID: BuildGraph.formulaeInputPort.asSymbolID())
    }
*/
    func process(input: ProcessInput) throws -> ProcessOutput {
        return .init(outputValues: [:],
                     inputWireExpectations: [Self.folderManifestInputPort: ["/": "Folder().folderManifest"],
                                             Self.projectBuildersInputPort: ["/formula.json": "ProjectBuilder(projectFile=StaticFile('formula.json').output).status"]])

        // wire name="mylib.dylib" Product(input=Linker(config: LinkerConfig(kind: library).output, input=[Compiler(input=Preprocessor(input=StaticFile('/hello.c').output).output).output, Compiler().output])).status
        #warning("TODO")
//        let oneValue = try readOneValueFromInputPort(Self.folderManifestInputPort)
//        let folderNode: FolderNode = try node(nodeID: oneValue.originNodeID)
//        let object = try PolyFactory.decode(encodedJSON: oneValue.1.expectValue().resolveAsString())
//
//        guard let folderManifest = object as? FolderManifest else {
//            throw NodeError.other(message: "Could not decode FolderManifest")
//        }
//
//        for entry in folderManifest.entries {
//            try ensureExtractorExists(folderManifestEntry: entry, folderNode: folderNode)
//        }
//
//        for formulaExtractorChild in try allChildren().filter({ node in node is ProjectBuilder }) {
//            if !folderManifest.entries.contains(where: { $0.name == formulaExtractorChild.nodeContext.name }) {
//                try formulaExtractorChild.delete()
//            }
//        }

    }
}

// MARK: - ProjectBuilder

/// Reads a single formula.json file and passes its text content through to
/// BuildGraph's formulae input port.
final class ProjectBuilder: NodeFunction {
    static let kind: UInt = 6

    enum CodingKeys: CodingKey {}

    required init() {}

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    static let projectFileInputPort = "projectFile"
    static let statusOutputPort = "status"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [projectFileInputPort], outputPorts: [statusOutputPort], dynamicInputPorts: [])

    func process(input: ProcessInput) throws -> ProcessOutput {
        .init(outputValues: [Self.statusOutputPort: .value("OK".intern())], inputWireExpectations: [:])
//        for formulaFileValue in try readAllValuesFromInputPort(Self.formulaFileInputPort) {
//            // Pass the formula content through unchanged.
//            try writeToOutputPort(Self.formulaOutputPort, value: .value(formulaFileValue.expectValue()))
//        }
    }
}
