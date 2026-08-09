// ProjectFinder.swift
// build_system
//

import Foundation

// MARK: - ProjectBuilderPlugin

private protocol ProjectBuilderPlugin {
    /// Returns the ProjectBuilder expectation string for `entry` inside `folderPath`,
    /// or `nil` if this plugin does not handle the entry.
    func expectationString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String?
}

private struct FormulaFilePlugin: ProjectBuilderPlugin {
    func expectationString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String? {
        guard entry.isPinned, entry.name.hasSuffix(".fmla") else { return nil }
        let fullPath = (Path(folderPath) / entry.name).string
        return "ProjectBuilder(projectFile: [\"\(fullPath)\": StaticFile(path: \"\(fullPath)\").output]).status"
            .replacingOccurrences(of: "\\'", with: "'")
    }
}

private struct SwiftPackagePlugin: ProjectBuilderPlugin {
    func expectationString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String? {
        guard entry.isPinned, entry.name == "Package.swift" else { return nil }
        let fullPath      = (Path(folderPath) / entry.name).string
        let packageFolder = Path(fullPath).deletingLastComponent!.string

        let pkgReaderExpr =
            "SwiftPackageReaderTool(" +
            "configuration: ['config': Configuration().output], " +
            "packageFile: ['\(fullPath)': StaticFile(path: '\(fullPath)').output]" +
            ").packageJSON"

        let converterExpr =
            "SwiftFormulaConverter(" +
            "packageFolder: ['\(packageFolder)': Folder(path: '\(packageFolder)').manifest], " +
            "packageJSON: ['\(fullPath)': \(pkgReaderExpr)]" +
            ").formula"

        return
            "ProjectBuilder(" +
            "projectFile: ['\(packageFolder)': \(converterExpr)]" +
            ").status"
    }
}

private let projectBuilderPlugins: [any ProjectBuilderPlugin] = [
    FormulaFilePlugin(),
    SwiftPackagePlugin(),
]

// MARK: - ProjectFinder

/// Watches an input file-list and creates a ProjectBuilder child for
/// every formula.json file that appears, wiring it into the BuildGraph's formulae input.
public struct ProjectFinder: NodeFunction {
    public static let kind: UInt = 5

    static let rootFolderManifestInputPort = "folderManifest"
    static let watchedFolderManifestInputPort = "watchedFolders"
    static let projectBuildersInputPort = "projectBuilders"

    // ProjectFinder uses all dynamic ports because there is nobody to wire up static input ports, as it is the first.
    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .dynamic(rootFolderManifestInputPort),
            .dynamic(watchedFolderManifestInputPort),
            .dynamic(projectBuildersInputPort),
        ],
        outputPorts: []
    )

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

        for (folderPath, folderManifest) in folderManifests {
            for entry in folderManifest.entries {
                let fullPath = (Path(folderPath) / entry.name).string
                for plugin in projectBuilderPlugins {
                    if let expectation = plugin.expectationString(forEntry: entry, inFolder: folderPath) {
                        result[fullPath] = expectation
                        break
                    }
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

            allFolderManifests.append((Folder.inputFileSystemName, folderManifest))

            for entry in folderManifest.entries {
                if entry.isFolder && entry.isPinned {
                    watchedPaths.insert((Path(Folder.inputFileSystemName) / entry.name).string)
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
                     inputWireExpectations: [Self.rootFolderManifestInputPort: [Folder.inputFileSystemName: "Folder(path: 'input:').manifest"],
                                             Self.watchedFolderManifestInputPort: watchedFolderExpectations,
                                             Self.projectBuildersInputPort: projectBuildersExpectations])
    }
}
