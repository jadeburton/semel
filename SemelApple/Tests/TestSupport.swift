//
//  TestSupport.swift
//  SemelAppleTests
//
//  The same isolation SemelClang's tests use: a package that only needs the node-authoring
//  API swaps the process-globals a node can reach, and nothing more.
//

@testable import SemelApple
import Foundation
import SemelNodeKit
import XCTest

/// Base class for every test here: swaps the process-globals a node can reach.
class SemelAppleTestCase: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared      = DataObjectStore(storeRoot: Self.temporaryStoreRoot())
        ToolRunnerRegistry.instance = ToolRunnerRegistry()
        // The manifests the nodes decode resolve through the same process-global registry
        // production uses.
        try TypeRegistry.register(types: [FolderManifest.self, TreeManifest.self])
        try SemelApple.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-apple-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Helpers

    /// `folderLinks` names the subfolders that are symbolic links pushed as ones, with what
    /// each holds.
    func manifestValue(_ path: String, files: [String] = [], folders: [String] = [],
                       folderLinks: [String: String] = [:]) throws -> NodeValue {
        let entries = files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
                    + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true, symbolicLinkTarget: folderLinks[$0]) }
        return .value(try FolderManifest(baseFolderPath: path, entries: entries).toJSON().intern())
    }

    func treeManifest(from value: NodeValue?) throws -> TreeManifest {
        let json = try XCTUnwrap(value).expectValue()
        return try TypeRegistry.decodeAndCast(encodedJSON: try json.resolveAsString())
    }
}

/// A `ToolRunner` that runs nothing, recording what it was asked to do so a test can
/// assert on the command line a node built.
///
/// Duplicated from the engine's test target rather than shared, like the other toolchain
/// packages' copies.
final class RecordingToolRunner: ToolRunner {

    struct Invocation {
        let arguments: [String]
        let environment: [String: String]
        let inputFileNames: [String]
        let inputHashes: [String]
        let expectedOutputFileNames: [String]
        let expectedOutputFolders: [String]
    }

    private(set) var invocations: [Invocation] = []

    /// Files the fake tool "produces", keyed by the output file name the caller expects.
    var producedFiles: [String: [UInt8]] = [:]
    /// Trees the fake tool "produces": folder -> relative path -> bytes.
    var producedTrees: [String: [String: [UInt8]]] = [:]
    /// Symbolic links the fake tool leaves in its trees: folder -> relative path -> target.
    var producedLinks: [String: [String: String]] = [:]
    var exitCode: Int32 = 0
    var errorOutput = ""
    var infoOutput = ""

    var lastArguments: [String] { invocations.last?.arguments ?? [] }
    var lastInputFileNames: [String] { invocations.last?.inputFileNames ?? [] }
    var lastInputHashes: [String] { invocations.last?.inputHashes ?? [] }

    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 expectedOutputFolders: [String],
                 output: ToolOutput) throws -> ToolExecuteResult {

        invocations.append(.init(arguments: arguments,
                                 environment: environment,
                                 inputFileNames: inputFiles.map(\.filePath),
                                 inputHashes: inputFiles.map(\.hash),
                                 expectedOutputFileNames: expectedOutputFileNames,
                                 expectedOutputFolders: expectedOutputFolders))

        if !errorOutput.isEmpty {
            output.logError(errorOutput)
        }
        if !infoOutput.isEmpty {
            output.logMessage(infoOutput)
        }
        for name in expectedOutputFileNames {
            output.write(name, try (producedFiles[name] ?? []).intern())
        }
        for folder in expectedOutputFolders {
            for (relativePath, data) in (producedTrees[folder] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output.writeTreeEntry(folder, relativePath, try data.intern(), FileMetadata.defaultMode)
            }
            for (relativePath, target) in (producedLinks[folder] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output.writeTreeLink(folder, relativePath, target)
            }
        }

        return ToolExecuteResult(exitCode: exitCode, resolvedSandboxPath: "/tmp/recording-tool-sandbox")
    }
}

extension Dictionary where Key == String, Value == GraphSpecNode {
    /// The trees as the spec text they render to, for assertions written against text.
    var rendered: [String: String] { mapValues { $0.asString(omitOutputPort: false) } }
}

/// NetNewsWire's local packages, which the fixture's project file does not name: the
/// seventeen folders in its synchronized `Modules` folder, each with the library products
/// its manifest declares at b4361413fc1850110f9f42652f0f84e7a51e9d64, as `swift package
/// dump-package` reads them. The manifests themselves are not copied into the fixture: a
/// `Package.swift` under this repository is one `semel-swift prepare` would take for a
/// package of Semel's own tree.
enum NetNewsWireModules {

    static let products: [String: [String]] = [
        "Account":          ["Account"],
        "ActivityLog":      ["ActivityLog"],
        "Articles":         ["Articles"],
        "ArticlesDatabase": ["ArticlesDatabase"],
        "CloudKitSync":     ["CloudKitSync"],
        "ErrorLog":         ["ErrorLog"],
        "FeedFinder":       ["FeedFinder"],
        "HTMLMetadata":     ["HTMLMetadata"],
        "Images":           ["Images"],
        "NewsBlur":         ["NewsBlur"],
        "RSCore":           ["RSCore", "RSCoreObjC", "RSCoreResources"],
        "RSDatabase":       ["RSDatabase", "RSDatabaseObjC"],
        "RSParser":         ["RSParser"],
        "RSTree":           ["RSTree"],
        "RSWeb":            ["RSWeb"],
        "Secrets":          ["Secrets"],
        "SyncDatabase":     ["SyncDatabase"],
    ]

    /// What a package folder holds, as far as a search looks: its manifest, and the
    /// folders every one of these has.
    static let packageFolderFiles   = ["Package.swift", "README.md"]
    static let packageFolderFolders = ["Sources", "Tests"]

    /// The package, among the ones given by path relative to the project's folder, whose
    /// manifest declares `product`, or nil for none.
    static func package(vending product: String, among packagePaths: [String]) -> String? {
        packagePaths.first { path in
            products[(path as NSString).lastPathComponent]?.contains(product) == true
        }
    }

    /// A copy of the fixture's project file in a new temporary folder, with `Modules` laid
    /// out as the clone has it — each package folder holding its manifest — for the facts
    /// `prepare` reads from the disk. The caller removes the folder.
    static func treeOnDisk() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("semel-netnewswire-\(UUID().uuidString)", isDirectory: true)
        let project = folder.appendingPathComponent("NetNewsWire.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: XcodeBuildSettingsTests.netNewsWire.appendingPathComponent("NetNewsWire.xcodeproj/project.pbxproj"),
                                         to: project.appendingPathComponent("project.pbxproj"))
        for name in products.keys.sorted() {
            let package = folder.appendingPathComponent("Modules/\(name)", isDirectory: true)
            for subfolder in packageFolderFolders {
                try FileManager.default.createDirectory(at: package.appendingPathComponent(subfolder), withIntermediateDirectories: true)
            }
            for file in packageFolderFiles {
                try Data("// \(name)\n".utf8).write(to: package.appendingPathComponent(file))
            }
        }
        return folder
    }
}

extension XcodeFormulaEmitter {
    /// An emitter for a project whose local packages are the ones it declares: what the
    /// converter hands it when no synchronized folder holds a package.
    init(project: XcodeProject, build: Build) {
        self.init(project: project, build: build, localPackagePaths: project.localPackagePaths)
    }
}

extension Xcconfig {
    /// The assignments written in the file itself, its includes not followed: what a test
    /// hands the settings evaluation for an xcconfig that includes nothing.
    static func assignments(_ text: String) -> [XcodeSettingAssignment] {
        Xcconfig(parsing: text).lines.compactMap { line in
            guard case .assignment(let assignment) = line else {
                return nil
            }
            return assignment
        }
    }
}
