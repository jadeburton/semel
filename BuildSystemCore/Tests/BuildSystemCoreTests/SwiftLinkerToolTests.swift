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

    private func makeInput(objectFiles: [String], libraries: [String] = []) throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            outputName=product
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
}
