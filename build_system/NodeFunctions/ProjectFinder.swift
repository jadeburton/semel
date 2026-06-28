// ProjectFinder.swift
// build_system
//
// ProjectFinder monitors a directory for .yml formula files and wires each one
// up to a ProjectBuilder, which in turn feeds the formula text to BuildGraph.
// ProjectBuilder reads a formula file and passes its content through to BuildGraph.

import Foundation

// MARK: - ProjectFinder

/// Watches an input file-list and creates a ProjectBuilder child for
/// every formula.json file that appears, wiring it into the BuildGraph's formulae input.
struct ProjectFinder: NodeFunction {
    static let kind: UInt = 5

    enum CodingKeys: CodingKey {
    }

    var initialName: String? {
        "projectFinder"
    }

    static let folderManifestInputPort = "folderManifest"
    static let projectBuildersInputPort = "projectBuilders"

    // ProjectFinder uses all dynamic ports because there is nobody to wire up static input ports, as it is the first.
    let descriptor = NodeFunctionDescriptor(staticInputPorts: [],
                                            outputPorts: [],
                                            dynamicInputPorts: [folderManifestInputPort, projectBuildersInputPort])

    var properties: [String : String] {
        [:]
    }

    init(properties: [String: String]) {
    }

    // ProjectFinder is the root object and so must never be deleted.
    func canBeDeleted(thisNode: Node) throws -> Bool {
        false
    }

    private func buildProjectBuildersExpectationFromFolderManifest(folderManifest: FolderManifest) throws -> [String: String] {
        var result: [String: String] = [:]

        for entry in folderManifest.entries {
            if entry.name.hasSuffix(".fmla") {
                result[entry.name] = "ProjectBuilder(projectFile <- [\"\(entry.name)\": StaticFile(path: \"\(entry.name)\").output]).status".replacingOccurrences(of: "\\'", with: "'")
            }
        }

        return result
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        var projectBuildersExpectations = [String: String]()

        // TODO: when an input .fmla file goes to "deleted", we need to erase the corresponding ProjectBuilder and its wires. This is not yet implemented.

        if let folderManifestInputValue = input.inputValues[Self.folderManifestInputPort]?.first {
            let object = try? PolyFactory.decode(encodedJSON: folderManifestInputValue.value.expectValue().resolveAsString())

            guard let folderManifest = object as? FolderManifest else {
                throw NodeError.other(message: "Could not decode FolderManifest")
            }

            projectBuildersExpectations = try buildProjectBuildersExpectationFromFolderManifest(folderManifest: folderManifest)
        }

        return .init(outputValues: [:],
                     inputWireExpectations: [Self.folderManifestInputPort: ["/": "Folder(path: 'inputFileSystem').manifest"],
                                             Self.projectBuildersInputPort: projectBuildersExpectations])
    }
}
