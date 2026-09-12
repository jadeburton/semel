//
//  SwiftLinkerTests.swift
//  semel_tests
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftLinkerTests: SemelSwiftTestCase {

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

    private func makeTool() throws -> SwiftLinker {
        try SwiftLinker(thisNode: NodeRecord(id: 1, kind: SwiftLinker.kind))
    }

    private func makeInput(objectFiles: [String],
                           libraries: [String] = [],
                           linkage: String = "executable",
                           extraConfiguration: [String] = []) throws -> ProcessInput {
        let configuration = ([
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "outputName=product",
            "linkage=\(linkage)",
        ] + extraConfiguration).joined(separator: "\n")

        var objects: [String: NodeValue] = [:]
        for path in objectFiles { objects[path] = .value(try "object \(path)".intern()) }

        var libraryValues: [String: NodeValue] = [:]
        for path in libraries { libraryValues[path] = .value(try "library \(path)".intern()) }

        return ProcessInput(inputValues: [
            SwiftLinker.configuration: ["configuration": .value(try configuration.intern())],
            SwiftLinker.input: objects,
            SwiftLinker.libraries: libraryValues,
        ])
    }

    // MARK: - Which SDK and target

    /// Nothing declared links against the machine's macOS SDK with no `-target`, as every
    /// existing tree did.
    func test_linksAgainstTheMacOSSDKByDefault() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let arguments = executor.lastArguments
        let sdkPath = try XCTUnwrap(arguments.firstIndex(of: "-sdk").map { arguments[$0 + 1] })
        XCTAssertTrue(sdkPath.contains("MacOSX"), "got \(sdkPath)")
        XCTAssertFalse(arguments.contains("-target"), "got \(arguments)")
    }

    /// An iOS package names its SDK and target, and both reach the link line.
    func test_linksAgainstTheDeclaredSDKAndTarget() throws {
        _ = try makeTool().process(input: try makeInput(
            objectFiles: ["a.o"],
            extraConfiguration: ["sdk=iphonesimulator", "target=arm64-apple-ios18.0-simulator"]))

        let arguments = executor.lastArguments
        let sdkPath = try XCTUnwrap(arguments.firstIndex(of: "-sdk").map { arguments[$0 + 1] })
        XCTAssertTrue(sdkPath.contains("iPhoneSimulator"), "got \(sdkPath)")
        let target = try XCTUnwrap(arguments.firstIndex(of: "-target").map { arguments[$0 + 1] })
        XCTAssertEqual(target, "arm64-apple-ios18.0-simulator")
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
            linkage=executable
            """
        return ProcessInput(inputValues: [
            SwiftLinker.configuration:   ["configuration": .value(try configuration.intern())],
            SwiftLinker.input:           ["a.o": .value(try "object".intern())],
            SwiftLinker.libraries:       [:],
            SwiftLinker.libraryFolders:  ["GRDBSQLite": try manifestValue("input:/pkg/Sources/GRDBSQLite", entries)],
        ])
    }

    private func librarySpecs(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftLinker.libraries]).keys.sorted()
    }

    /// A static archive dropped in the system library's folder is what makes the linked
    /// binary self-contained — without it the modulemap's `link "sqlite3"` resolves
    /// against the SDK and the product silently depends on the system copy.
    func test_wiresStaticArchivesFoundInASystemLibraryFolder() throws {
        let output = try makeTool().process(input: try vendoredFolderInput(
            [file("libsqlite3.a"), file("module.modulemap"), file("shim.h"), file("sqlite3.h")]))

        XCTAssertEqual(try librarySpecs(output), ["input:/pkg/Sources/GRDBSQLite/libsqlite3.a"])
    }

    /// The module map, the shim and the vendored header belong to the *compile*, not the
    /// link — handing them to the linker would be an error, not merely noise.
    func test_ignoresEverythingButArchivesInASystemLibraryFolder() throws {
        let output = try makeTool().process(input: try vendoredFolderInput(
            [file("module.modulemap"), file("shim.h"), file("sqlite3.h")]))

        XCTAssertEqual(try librarySpecs(output), [])
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

    private func linkedFileMode(linkage: String) throws -> UInt16? {
        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: linkage))
        let value = try XCTUnwrap(output.outputValues[SwiftLinker.fileMetadata])
        let metadata = try XCTUnwrap(FileMetadata.decode(from: try value.expectValue().resolveAsString()))
        return metadata.mode
    }

    /// Without this the linked binary is copied out at the default 0644 and will not run.
    /// ProjectBuilder wires the port automatically for any node type that declares it, so
    /// declaring it is the whole fix — same as ClangLinker.
    func test_anExecutableIsPublishedAsExecutable() throws {
        XCTAssertEqual(try linkedFileMode(linkage: "executable"), FileMetadata.executableMode)
    }

    func test_aDynamicLibraryIsPublishedWithTheDefaultMode() throws {
        XCTAssertEqual(try linkedFileMode(linkage: "dynamicLibrary"), FileMetadata.defaultMode)
    }

    /// An archive is not run either.
    func test_aStaticArchiveIsPublishedWithTheDefaultMode() throws {
        XCTAssertEqual(try linkedFileMode(linkage: "staticArchive"), FileMetadata.defaultMode)
    }

    // MARK: - Linkage (B-09)

    /// The flags that select the artifact form, in the order they are emitted.
    private func emitFlags(linkage: String) throws -> [String] {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: linkage))
        return executor.lastArguments.filter { $0 == "-emit-library" || $0 == "-static" }
    }

    func test_anExecutableIsLinkedWithNeitherLibraryFlag() throws {
        XCTAssertEqual(try emitFlags(linkage: "executable"), [])
    }

    func test_aDynamicLibraryIsLinkedWithEmitLibraryAlone() throws {
        XCTAssertEqual(try emitFlags(linkage: "dynamicLibrary"), ["-emit-library"])
    }

    /// `swiftc -emit-library -static -o lib<name>.a *.o` drives libtool and writes a plain
    /// `ar` archive — verified on the local toolchain — so the linker stays one tool.
    func test_aStaticArchiveIsLinkedWithEmitLibraryAndStatic() throws {
        XCTAssertEqual(try emitFlags(linkage: "staticArchive"), ["-emit-library", "-static"])
    }

    /// Three forms and no default: the formula has to say which one it wants.
    func test_linkageIsRequired() throws {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            outputName=product
            """
        let input = ProcessInput(inputValues: [
            SwiftLinker.configuration: ["configuration": .value(try configuration.intern())],
            SwiftLinker.input: ["a.o": .value(try "object".intern())],
            SwiftLinker.libraries: [:],
        ])

        XCTAssertThrowsError(try makeTool().process(input: input)) { error in
            XCTAssertTrue(String(describing: error).contains("swift.linker.linkage"), "got \(error)")
        }
    }

    func test_anUnknownLinkageIsRejectedNamingTheChoices() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(objectFiles: ["a.o"], linkage: "shared"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("shared"), "should name the bad value, got \(message)")
            XCTAssertTrue(message.contains("staticArchive"), "should list the accepted values, got \(message)")
        }
    }

    /// ProjectBuilder only wires the metadata if the port is declared on the type.
    func test_declaresTheFileMetadataPort() {
        XCTAssertTrue(SwiftLinker.descriptor.outputPorts.contains(FileMetadata.portName))
    }
}
