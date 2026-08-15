//
//  SwiftLinkerToolTests.swift
//  build_system_tests
//

@testable import BuildSystemCore
import XCTest

final class SwiftLinkerToolTests: BuildSystemTestCase {

    private let descriptor = ToolDescriptor(name: "swiftc",
                                            version: "test-swiftc",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolExecutor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolExecutor()
        ToolExecutorRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func makeTool() throws -> SwiftLinkerTool {
        try SwiftLinkerTool(thisNode: Node(id: 1, kind: SwiftLinkerTool.kind))
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
