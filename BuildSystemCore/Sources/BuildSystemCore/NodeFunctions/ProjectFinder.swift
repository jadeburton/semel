// ProjectFinder.swift
// build_system
//
// ProjectFinder monitors a directory for .yml formula files and wires each one
// up to a ProjectBuilder, which in turn feeds the formula text to BuildGraph.
// ProjectBuilder reads a formula file and passes its content through to BuildGraph.

import Foundation

/// Watches an input file-list and creates a ProjectBuilder child for
/// every formula.json file that appears, wiring it into the BuildGraph's formulae input.
public struct ProjectFinder: NodeFunction {
    public static let kind: UInt = 5

    static let rootFolderManifestInputPort = "folderManifest"
    static let watchedFolderManifestInputPort = "watchedFolders"
    static let projectBuildersInputPort = "projectBuilders"

    // ProjectFinder uses all dynamic ports because there is nobody to wire up static input ports, as it is the first.
    let descriptor = NodeFunctionDescriptor(staticInputPorts: [],
                                            outputPorts: [],
                                            dynamicInputPorts: [rootFolderManifestInputPort, watchedFolderManifestInputPort, projectBuildersInputPort])

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    // ProjectFinder is the root object and so must never be deleted.
    func canBeDeleted() throws -> Bool {
        false
    }

    private func buildProjectBuildersExpectationFromFolderManifest(folderManifests: [(String, FolderManifest)]) throws -> [String: String] {
        var result: [String: String] = [:]

        for folderManifest in folderManifests {
            for entry in folderManifest.1.entries {
                if entry.isPinned && entry.name.hasSuffix(".fmla") {
                    let fullPath = (Path(folderManifest.0) / entry.name).string
                    result[fullPath] = "ProjectBuilder(projectFile <- [\"\(fullPath)\": StaticFile(path: \"\(fullPath)\").output]).status".replacingOccurrences(of: "\\'", with: "'")
                }
            }
        }

        return result
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        var projectBuildersExpectations = [String: String]()

        let allWatchedFolderManifests = input.inputValues[Self.watchedFolderManifestInputPort]

        var watchedPaths = Set<String>()

        var allFolderManifests = [(String, FolderManifest)]()

        for (watchedFolderManifestInputKey, watchedFolderManifestInputValue) in allWatchedFolderManifests ?? [:] {
            let object = try? PolyFactory.decode(encodedJSON: watchedFolderManifestInputValue.expectValue().resolveAsString())

            guard let folderManifest = object as? FolderManifest else {
                throw NodeError.other(message: "Could not decode FolderManifest")
            }

            allFolderManifests.append((watchedFolderManifestInputKey, folderManifest))

            for entry in folderManifest.entries {
                if entry.isFolder && entry.isPinned {
                    watchedPaths.insert((Path(watchedFolderManifestInputKey) / entry.name).string)
                }
            }
        }

        if let folderManifestInputValue = input.inputValues[Self.rootFolderManifestInputPort]?.first {
            let object = try? PolyFactory.decode(encodedJSON: folderManifestInputValue.value.expectValue().resolveAsString())

            guard let folderManifest = object as? FolderManifest else {
                throw NodeError.other(message: "Could not decode FolderManifest")
            }

            allFolderManifests.append(("inputFileSystem", folderManifest))

            for entry in folderManifest.entries {
                if entry.isFolder && entry.isPinned {
                    watchedPaths.insert((Path("inputFileSystem") / entry.name).string)
                }
            }
        }

        projectBuildersExpectations = try buildProjectBuildersExpectationFromFolderManifest(folderManifests: allFolderManifests)

        var watchedFolderExpectations = [String: String]()

        for watchedPath in watchedPaths {
            watchedFolderExpectations[watchedPath] = "Folder(path: '\(watchedPath)').manifest"
        }
        
        print("ProjectFinder: watchedPaths = \(watchedPaths.joined(separator: ", "))")

        return .init(outputValues: [:],
                     inputWireExpectations: [Self.rootFolderManifestInputPort: ["inputFileSystem": "Folder(path: 'inputFileSystem').manifest"],
                                             Self.watchedFolderManifestInputPort: watchedFolderExpectations,
                                             Self.projectBuildersInputPort: projectBuildersExpectations])
    }
}
