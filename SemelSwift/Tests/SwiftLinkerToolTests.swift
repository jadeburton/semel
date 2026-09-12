//
//  SwiftLinkerToolTests.swift
//  semel_tests
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftLinkerToolTests: SemelSwiftTestCase {

    private let descriptor = ToolDescriptor(name: "swiftc",
                                            version: "test-swiftc",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func makeTool() throws -> SwiftLinkerTool {
        try SwiftLinkerTool(thisNode: NodeRecord(id: 1, kind: SwiftLinkerTool.kind))
    }

    private func makeInput(objectFiles: [String],
                           libraries: [String] = [],
                           dynamicLibrary: Bool = false) throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            outputName=product
            dynamicLibrary=\(dynamicLibrary)
            """

        var objects: [String: NodeValue] = [:]
        for path in objectFiles { objects[path] = .value(try "object \(path)".intern()) }

        var libraryValues: [String: NodeValue] = [:]
        for path in libraries { libraryValues[path] = .value(try "library \(path)".intern()) }

        return ProcessInput(inputValues: [
            SwiftLinkerTool.configuration: ["configuration": .value(try configuration.intern())],
            SwiftLinkerTool.input: objects,
            SwiftLinkerTool.libraries: libraryValues,
        ])
    }

    // Same reproducibility requirement as the Clang linker: identical inputs must produce
    // an identical command line, so dictionary iteration order must not leak through.
    func test_objectFilesAreOrderedDeterministically() throws {
        let objectFiles = ["zebra.o", "alpha.o", "middle.o", "beta.o", "yankee.o"]

        _ = try makeTool().process(input: try makeInput(objectFiles: objectFiles))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".o") },
                       objectFiles.sorted())
    }

    func test_librariesAreOrderedDeterministically() throws {
        let libraries = ["libz.dylib", "libapple.dylib", "libmiddle.dylib"]

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], libraries: libraries))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".dylib") },
                       libraries.sorted())
    }

    func test_linksToTheConfiguredOutputName() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        XCTAssertEqual(Array(executor.lastArguments.suffix(2)), ["-o", "product"])
    }

    // MARK: - Vendored system libraries

    private func file(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: false, isPinned: true) }

    private func manifestValue(_ baseFolderPath: String, _ entries: [FolderManifestEntry]) throws -> NodeValue {
        .value(try FolderManifest(baseFolderPath: baseFolderPath, entries: entries).toJSON().intern())
    }

    /// The folder a `.systemLibrary` target points at, once a user has dropped a vendored
    /// archive and header beside the module map.
    private func vendoredFolderInput(_ entries: [FolderManifestEntry]) throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            outputName=product
            """
        return ProcessInput(inputValues: [
            SwiftLinkerTool.configuration:   ["configuration": .value(try configuration.intern())],
            SwiftLinkerTool.input:           ["a.o": .value(try "object".intern())],
            SwiftLinkerTool.libraries:       [:],
            SwiftLinkerTool.libraryFolders:  ["GRDBSQLite": try manifestValue("input:/pkg/Sources/GRDBSQLite", entries)],
        ])
    }

    private func libraryExpectations(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireExpectations[SwiftLinkerTool.libraries]).keys.sorted()
    }

    /// A static archive dropped in the system library's folder is what makes the linked
    /// binary self-contained — without it the modulemap's `link "sqlite3"` resolves
    /// against the SDK and the product silently depends on the system copy.
    func test_wiresStaticArchivesFoundInASystemLibraryFolder() throws {
        let output = try makeTool().process(input: try vendoredFolderInput(
            [file("libsqlite3.a"), file("module.modulemap"), file("shim.h"), file("sqlite3.h")]))

        XCTAssertEqual(try libraryExpectations(output), ["input:/pkg/Sources/GRDBSQLite/libsqlite3.a"])
    }

    /// The module map, the shim and the vendored header belong to the *compile*, not the
    /// link — handing them to the linker would be an error, not merely noise.
    func test_ignoresEverythingButArchivesInASystemLibraryFolder() throws {
        let output = try makeTool().process(input: try vendoredFolderInput(
            [file("module.modulemap"), file("shim.h"), file("sqlite3.h")]))

        XCTAssertEqual(try libraryExpectations(output), [])
    }

    /// A folder with no archive is the "use the system library" case, and must link
    /// exactly as it did before this port existed.
    func test_aSystemLibraryFolderWithNoArchiveAddsNoLinkerArguments() throws {
        _ = try makeTool().process(input: try vendoredFolderInput([file("module.modulemap")]))

        XCTAssertFalse(executor.lastArguments.contains { $0.hasSuffix(".a") })
    }

    func test_passesAWiredArchiveToTheLinker() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                        libraries: ["input:/pkg/Sources/GRDBSQLite/libsqlite3.a"]))

        XCTAssertTrue(executor.lastArguments.contains("input:/pkg/Sources/GRDBSQLite/libsqlite3.a"),
                      "got \(executor.lastArguments)")
    }

    // MARK: - File metadata

    private func linkedFileMode(dynamicLibrary: Bool) throws -> UInt16? {
        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                                 dynamicLibrary: dynamicLibrary))
        let value = try XCTUnwrap(output.outputValues[SwiftLinkerTool.fileMetadata])
        let metadata = try XCTUnwrap(FileMetadata.decode(from: try value.expectValue().resolveAsString()))
        return metadata.mode
    }

    /// Without this the linked binary is copied out at the default 0644 and will not run.
    /// ProjectBuilder wires the port automatically for any node type that declares it, so
    /// declaring it is the whole fix — same as ClangLinkerTool.
    func test_anExecutableIsPublishedAsExecutable() throws {
        XCTAssertEqual(try linkedFileMode(dynamicLibrary: false), FileMetadata.executableMode)
    }

    func test_aDynamicLibraryIsPublishedWithTheDefaultMode() throws {
        XCTAssertEqual(try linkedFileMode(dynamicLibrary: true), FileMetadata.defaultMode)
    }

    /// ProjectBuilder only wires the metadata if the port is declared on the type.
    func test_declaresTheFileMetadataPort() {
        XCTAssertTrue(SwiftLinkerTool.descriptor.outputPorts.contains(FileMetadata.portName))
    }
}
