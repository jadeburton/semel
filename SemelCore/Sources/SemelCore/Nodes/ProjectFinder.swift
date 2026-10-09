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

    /// The input file system's subtree manifest, one wire (B-135): every folder's listing,
    /// where the finder once watched the root's manifest and then each pinned folder's, a
    /// wire and a pass per level.
    static let inputTreeInputPort = "inputTree"
    static let projectBuildersInputPort = "projectBuilders"
    /// Every project file a plugin says builds nothing until a formula includes it, as
    /// `[IncludableProject]` sorted by path (B-10). Published rather than worked out at idle:
    /// this node already reads every folder's listing when one changes, and the report
    /// reads one port instead of every listing on every settle.
    static let includableProjectsOutputPort = "includableProjects"

    /// 2: a new output port, `includableProjects` (B-10); 3: the input file system is read
    /// through its subtree manifest on one port, where two ports walked it (B-135).
    /// 4: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 4

    // ProjectFinder uses all dynamic ports because there is nobody to wire up static input ports, as it is the first.
    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .dynamic(inputTreeInputPort),
            .dynamic(projectBuildersInputPort),
        ],
        outputPorts: [includableProjectsOutputPort]
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
        // Every pinned folder of the input file system at every depth, from one tree. On the
        // first run the wire is not there yet and nothing is found; the run after has it all.
        let tree = FolderTreeWalk.trees(in: input, port: Self.inputTreeInputPort)[Folder.inputFileSystemName]
        let allFolderManifests = try tree?.folderManifests(at: Folder.inputFileSystemName)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) } ?? []

        let projectBuildersSpecs = try buildProjectBuildersSpecsFromFolderManifest(folderManifests: allFolderManifests)
        let includable = try Self.includableProjects(in: allFolderManifests).toSortedJSON()

        return .init(outputValues: [Self.includableProjectsOutputPort: .value(try includable.intern())],
                     inputWireSpecs: [Self.inputTreeInputPort: [Folder.inputFileSystemName: .folderTree(at: Folder.inputFileSystemName)],
                                      Self.projectBuildersInputPort: projectBuildersSpecs])
    }
}

// MARK: - Projects a formula has to name (B-10)

/// A project file that builds nothing until a formula includes the node a plugin names for
/// it — a `Package.swift` — as `ProjectFinder` publishes it for the idle report.
struct IncludableProject: Codable, Equatable {
    /// The file, as the input file system names it.
    let path: String
    /// What a formula's `include` names to build it.
    let include: GraphSpecNode
    /// Where the formula that includes it would be: the nearest folder at or above the
    /// file's own that holds a formula, or the file's folder when none does. The include
    /// is spelled from there, so the line the report prints can be pasted as it stands.
    let formulaFolder: String
}

extension ProjectFinder {

    /// Every entry an includable-project plugin claims, among the listings this node reads.
    static func includableProjects(in folderManifests: [(String, FolderManifest)]) -> [IncludableProject] {
        // The folders that hold a formula: an entry a builder plugin claims is one.
        var formulaFolders: Set<String> = []
        for (folderPath, folderManifest) in folderManifests {
            let holdsAFormula = folderManifest.entries.contains { entry in
                ProjectDiscovery.plugins.contains { $0.spec(forEntry: entry, inFolder: folderPath) != nil }
            }
            if holdsAFormula {
                formulaFolders.insert(Path(folderPath).string)
            }
        }

        var result: [IncludableProject] = []
        for (folderPath, folderManifest) in folderManifests {
            for entry in folderManifest.entries {
                let includes = ProjectDiscovery.includablePlugins.lazy.compactMap {
                    $0.includeSpec(forEntry: entry, inFolder: folderPath)
                }
                guard let include = includes.first else {
                    continue
                }
                result.append(IncludableProject(path: (Path(folderPath) / entry.name).string,
                                                include: include,
                                                formulaFolder: nearestFormulaFolder(from: Path(folderPath),
                                                                                    among: formulaFolders)))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// `folder` or the nearest folder above it in `formulaFolders`; `folder` when none is.
    private static func nearestFormulaFolder(from folder: Path, among formulaFolders: Set<String>) -> String {
        var candidate: Path? = folder
        while let current = candidate {
            if formulaFolders.contains(current.string) {
                return current.string
            }
            candidate = current.deletingLastComponent
        }
        return folder.string
    }
}

extension Array where Element == IncludableProject {
    /// The text the port holds: keys sorted, so equal lists intern to one hash.
    func toSortedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
