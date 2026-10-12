//
//  SwiftPackageReaderTests.swift
//  semel_tests
//
//  This node's output is the dumped manifest, which drives the whole formula and every
//  node downstream of it. Anything it can see that the graph cannot is an input nobody
//  keyed.
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftPackageReaderTests: SemelSwiftTestCase {

    private let descriptor = ToolDescriptor(name: "swift",
                                            version: "test-swift",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func makeTool() throws -> SwiftPackageReader {
        try SwiftPackageReader(thisNode: NodeRecord(id: 1, kind: SwiftPackageReader.kind))
    }

    private func folderValue(_ folder: String, files: [String]) throws -> NodeValue {
        let listing = FolderManifest(baseFolderPath: folder,
                                     entries: files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) })
        return .value(try listing.toJSON().intern())
    }

    /// The reader's inputs for the package at `folder`: `Package.swift` holding
    /// `manifest`, the folder listing `Package.swift` and every name in `versionSpecific`,
    /// and on the dynamic port whatever `delivered` holds, by file name.
    private func makeInput(folder: String = "input:/pkg",
                           manifest: String = "// swift-tools-version:5.9",
                           versionSpecific: [String] = [],
                           delivered: [String: String] = [:]) throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            """
        var deliveredValues: [String: NodeValue] = [:]
        for (name, text) in delivered {
            deliveredValues["\(folder)/\(name)"] = .value(try text.intern())
        }
        return ProcessInput(inputValues: [
            SwiftPackageReader.configuration: ["config": .value(try configuration.intern())],
            SwiftPackageReader.packageFile:   ["\(folder)/Package.swift": .value(try manifest.intern())],
            SwiftPackageReader.packageFolder: [folder: try folderValue(folder, files: ["Package.swift", "README.md"] + versionSpecific)],
            SwiftPackageReader.versionSpecificManifests: deliveredValues,
        ])
    }

    // MARK: - Hermeticity

    /// `ToolRunner` deliberately replaces the environment rather than inheriting it —
    /// fixed PATH, and HOME and TMPDIR inside the per-run sandbox — so a manifest that
    /// reads an environment variable (GRDB's own reads SQLITE_ENABLE_PREUPDATE_HOOK) sees
    /// it unset identically on every machine.
    func test_doesNotReachOutsideTheSandboxForItsEnvironment() throws {
        _ = try makeTool().process(input: try makeInput())

        let environment = try XCTUnwrap(executor.invocations.first).environment
        XCTAssertNil(environment["HOME"],
                     "HOME must stay the sandbox the executor chose, got \(environment)")
        XCTAssertNil(environment["TMPDIR"],
                     "TMPDIR must stay the sandbox the executor chose, got \(environment)")
    }

    /// B-17. Which binary answers to `test-swift` on a machine is a thing the graph cannot
    /// see either, so the reader declares the fingerprint discovery took of it.
    func test_declaresTheBinaryBehindItsToolVersion() throws {
        ToolRunnerRegistry.instance.registerTool(
            descriptor: .init(name: descriptor.name, version: descriptor.version,
                              platform: descriptor.platform, architecture: descriptor.architecture,
                              recursiveHash: "fingerprint-of-the-driver"),
            toolExecutor: executor)

        XCTAssertEqual(try makeTool().cacheKeyMaterial(input: try makeInput()),
                       "tool=swift:fingerprint-of-the-driver")
    }

    /// The manifest is laid at its path in the input file system, as every tool's inputs
    /// are, and the subcommand pointed at its folder: a `..` the manifest names is then a
    /// folder with the name it has in the build, not the sandbox's (B-80).
    func test_asksForTheManifestDumpOfTheFolderWhereItIsLaid() throws {
        _ = try makeTool().process(input: try makeInput(folder: "input:/repo/swift-syntax/SwiftParserCLI"))

        let invocation = try XCTUnwrap(executor.invocations.first)
        XCTAssertEqual(invocation.arguments, ["package", "--manifest-cache", "none", "dump-package",
                                              "--package-path", "input:/repo/swift-syntax/SwiftParserCLI"])
        XCTAssertEqual(invocation.inputFileNames, ["input:/repo/swift-syntax/SwiftParserCLI/Package.swift"])
    }

    // MARK: - Version-specific manifests (B-80)

    func test_recognisesTheNamesSwiftPMReadsInPlaceOfPackageSwift() {
        for name in ["Package@swift-6.swift", "Package@swift-5.9.swift", "Package@swift-5.9.1.swift"] {
            XCTAssertTrue(SwiftPackageReader.isVersionSpecificManifest(name), name)
        }
        for name in ["Package.swift", "Package@swift-.swift", "Package@swift-6.0.1.2.swift", "Package@swift-6.0.swift.orig",
                     "Package@swift6.swift", "package@swift-6.swift"] {
            XCTAssertFalse(SwiftPackageReader.isVersionSpecificManifest(name), name)
        }
    }

    /// A folder holding a version-specific manifest: the reader asks for it and runs
    /// nothing until it has arrived, saying what it waits for.
    func test_asksForEachVersionSpecificManifestAndWaitsForIt() throws {
        let output = try makeTool().process(input: try makeInput(versionSpecific: ["Package@swift-6.0.swift"]))

        XCTAssertTrue(executor.invocations.isEmpty, "nothing runs before every manifest is there")
        XCTAssertEqual(output.inputWireSpecs[SwiftPackageReader.versionSpecificManifests]?.rendered,
                       ["input:/pkg/Package@swift-6.0.swift": "StaticFile(path: 'input:/pkg/Package@swift-6.0.swift').output"])
        let document = try XCTUnwrap(output.outputValues[SwiftPackageReader.packageJSON]?.errorDocument)
        guard case .engine(let condition) = document.diagnostic else {
            return XCTFail("expected an engine condition, got \(document)")
        }
        XCTAssertEqual(condition, .inputsWithoutValue(kind: .versionSpecificManifests, paths: ["input:/pkg/Package@swift-6.0.swift"]))
    }

    /// Once it has, every manifest is laid in the folder, and the tool reads the one
    /// SwiftPM would; the demand stays on every output, or the wire would go.
    func test_laysEveryVersionSpecificManifestBesidePackageSwift() throws {
        let output = try makeTool().process(input: try makeInput(versionSpecific: ["Package@swift-6.0.swift", "Package@swift-5.7.swift"],
                                                                 delivered: ["Package@swift-6.0.swift": "// swift-tools-version:6.0",
                                                                             "Package@swift-5.7.swift": "// swift-tools-version:5.7"]))

        XCTAssertEqual(try XCTUnwrap(executor.invocations.first).inputFileNames,
                       ["input:/pkg/Package.swift", "input:/pkg/Package@swift-5.7.swift", "input:/pkg/Package@swift-6.0.swift"])
        XCTAssertEqual(output.inputWireSpecs[SwiftPackageReader.versionSpecificManifests]?.keys.sorted(),
                       ["input:/pkg/Package@swift-5.7.swift", "input:/pkg/Package@swift-6.0.swift"])
    }

    /// A manifest the folder no longer holds is neither laid nor waited for, whatever is
    /// still wired.
    func test_aManifestTheFolderNoLongerHoldsIsNotLaid() throws {
        _ = try makeTool().process(input: try makeInput(delivered: ["Package@swift-6.0.swift": "// swift-tools-version:6.0"]))

        XCTAssertEqual(try XCTUnwrap(executor.invocations.first).inputFileNames, ["input:/pkg/Package.swift"])
    }

    // MARK: - Paths in the dump

    /// dump-package makes a path dependency absolute, under the sandbox; the reader
    /// publishes it relative to the package. An ancestor named exactly — `.package(path:
    /// "..")` — is `..`, which the converter resolves like any relative path.
    func test_publishesPathsRelativeToThePackageIncludingAnAncestorItself() {
        let folder = "/private/var/sandbox/input:/repo/swift-syntax/SwiftParserCLI"
        let json = """
            {"a": "\(folder)", "b": "/private/var/sandbox/input:/repo/swift-syntax", \
            "c": "/private/var/sandbox/input:/repo/Models", "d": "\(folder)/Sources/Tool", "e": "Sources"}
            """

        let published = SwiftPackageReader.relativizingPaths(in: json, packageFolder: folder)

        XCTAssertEqual(published, #"{"a":".","b":"..","c":"..\/..\/Models","d":"Sources\/Tool","e":"Sources"}"#)
    }

    // MARK: - The real tool

    /// The reader as the machine's `swift` runs it: the tool behind the version the
    /// configuration names.
    private func useTheMachinesSwift() throws {
        let swift = try XCTUnwrap(SwiftToolDiscovery.locate("swift"), "no swift on this machine")
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: swift))
    }

    private func packageName(_ output: ProcessOutput) throws -> String {
        let json = try XCTUnwrap(output.outputValues[SwiftPackageReader.packageJSON]).expectValue().resolveAsString()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(object["name"] as? String)
    }

    private func manifest(toolsVersion: String, name: String) -> String {
        "// swift-tools-version:\(toolsVersion)\nimport PackageDescription\nlet package = Package(name: \"\(name)\")\n"
    }

    /// A package holding `Package.swift` and version-specific manifests reads as SwiftPM
    /// reads it on disk: a `Package@swift-6.0.swift` declaring a newer tools version than
    /// `Package.swift` is read by any 6.x toolchain, and a `Package@swift-5.7.swift` kept
    /// for older ones is not, though its name is older than the toolchain too.
    func test_theMachinesSwiftReadsTheManifestSwiftPMWould() throws {
        try useTheMachinesSwift()
        let regular = manifest(toolsVersion: "5.9", name: "Regular")

        let olderOnly = try makeTool().process(input: try makeInput(manifest: regular,
                                                                    versionSpecific: ["Package@swift-5.7.swift"],
                                                                    delivered: ["Package@swift-5.7.swift": manifest(toolsVersion: "5.7", name: "Older")]))
        XCTAssertEqual(try packageName(olderOnly), "Regular")

        let both = try makeTool().process(input: try makeInput(manifest: regular,
                                                               versionSpecific: ["Package@swift-5.7.swift", "Package@swift-6.0.swift"],
                                                               delivered: ["Package@swift-5.7.swift": manifest(toolsVersion: "5.7", name: "Older"),
                                                                           "Package@swift-6.0.swift": manifest(toolsVersion: "6.0", name: "Six")]))
        XCTAssertEqual(try packageName(both), "Six")
    }

    /// swift-syntax's `SwiftParserCLI` (B-80): a nested package depending on `..` and naming
    /// that package by its folder's name in a product dependency. Read in the folder it is
    /// in, the name is right and the path is `..`; read at the sandbox's root, `..` was the
    /// sandbox's parent and the product's package unknown.
    func test_theMachinesSwiftReadsANestedPackageNamingItsParentByItsFolder() throws {
        try useTheMachinesSwift()
        let tool = """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
              name: "Tool",
              dependencies: [.package(path: "..")],
              targets: [.executableTarget(name: "tool", dependencies: [.product(name: "Parser", package: "parent-kit")])]
            )
            """

        let output = try makeTool().process(input: try makeInput(folder: "input:/repo/parent-kit/Tool", manifest: tool))

        let json = try XCTUnwrap(output.outputValues[SwiftPackageReader.packageJSON]).expectValue().resolveAsString()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let dependencies = try XCTUnwrap(object["dependencies"] as? [[String: Any]])
        let local = try XCTUnwrap((dependencies.first?["fileSystem"] as? [[String: Any]])?.first)
        XCTAssertEqual(local["identity"] as? String, "parent-kit")
        XCTAssertEqual(local["path"] as? String, "..")
    }
}
