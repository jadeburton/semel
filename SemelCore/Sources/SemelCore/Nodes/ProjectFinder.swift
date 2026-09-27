// ProjectFinder.swift
// semel
//

import Foundation
import SemelNodeKit

// MARK: - Project kinds

struct FormulaFilePlugin: ProjectBuilderPlugin {
    func spec(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> GraphSpecNode? {
        guard entry.isPinned, entry.name.hasSuffix(".fmla") else {
            return nil
        }
        let fullPath = (Path(folderPath) / entry.name).string
        // The .fmla file sits *in* the project's directory, so products go beside it.
        return GraphSpecNode(ProjectBuilder.self,
                             properties: [ProjectBuilder.outputFolderProperty: folderPath],
                             inputs: [ProjectBuilder.projectFileInputPort: [fullPath: .staticFile(at: fullPath)]])
            .port(ProjectBuilder.statusOutputPort)
    }
}

// MARK: - ProjectFinder

/// Watches an input file-list and creates a ProjectBuilder child for
/// every formula.json file that appears, wiring it into the BuildGraph's formulae input.
public struct ProjectFinder: Node {
    public static let kind: UInt = 5

    static let rootFolderManifestInputPort = "folderManifest"
    static let watchedFolderManifestInputPort = "watchedFolders"
    static let projectBuildersInputPort = "projectBuilders"

    // ProjectFinder uses all dynamic ports because there is nobody to wire up static input ports, as it is the first.
    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .dynamic(rootFolderManifestInputPort),
            .dynamic(watchedFolderManifestInputPort),
            .dynamic(projectBuildersInputPort),
        ],
        outputPorts: []
    )

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    // ProjectFinder is the root object and so must never be deleted.
    public func canBeDeleted() throws -> Bool {
        false
    }

    private func buildProjectBuildersSpecsFromFolderManifest(folderManifests: [(String, FolderManifest)]) throws -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]

        for (folderPath, folderManifest) in folderManifests {
            for entry in folderManifest.entries {
                let fullPath = (Path(folderPath) / entry.name).string
                for plugin in ProjectDiscovery.plugins {
                    if let spec = plugin.spec(forEntry: entry, inFolder: folderPath) {
                        result[fullPath] = spec
                        break
                    }
                }
            }
        }

        return result
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        var projectBuildersSpecs = [String: GraphSpecNode]()

        let allWatchedFolderManifests = input.inputValues[Self.watchedFolderManifestInputPort]

        var watchedPaths = Set<String>()

        var allFolderManifests = [(String, FolderManifest)]()

        for (watchedFolderManifestInputKey, watchedFolderManifestInputValue) in allWatchedFolderManifests ?? [:] {
            let object = try? TypeRegistry.decode(encodedJSON: watchedFolderManifestInputValue.expectValue().resolveAsString())

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
            let object = try? TypeRegistry.decode(encodedJSON: folderManifestInputValue.value.expectValue().resolveAsString())

            guard let folderManifest = object as? FolderManifest else {
                throw NodeError.other(message: "Could not decode FolderManifest")
            }

            allFolderManifests.append((Folder.inputFileSystemName, folderManifest))

            for entry in folderManifest.entries {
                if entry.isFolder && entry.isPinned {
                    watchedPaths.insert((Path(Folder.inputFileSystemName) / entry.name).string)
                }
            }
        }

        projectBuildersSpecs = try buildProjectBuildersSpecsFromFolderManifest(folderManifests: allFolderManifests)

        var watchedFolderSpecs = [String: GraphSpecNode]()

        for watchedPath in watchedPaths {
            watchedFolderSpecs[watchedPath] = .folderManifest(at: watchedPath)
        }

        return .init(outputValues: [:],
                     inputWireSpecs: [Self.rootFolderManifestInputPort: [Folder.inputFileSystemName: .folderManifest(at: Folder.inputFileSystemName)],
                                             Self.watchedFolderManifestInputPort: watchedFolderSpecs,
                                             Self.projectBuildersInputPort: projectBuildersSpecs])
    }
}
