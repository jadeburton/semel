//
//  SwiftCompilerResourceBundleTests.swift
//  SemelSwiftTests
//
//  B-77. A target with resources compiles with the `Bundle.module` accessor SwiftPM would
//  generate, naming the bundle the converter builds; a target without compiles as before.
//

@testable import SemelSwift
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class SwiftCompilerResourceBundleTests: SemelSwiftTestCase {

    private let descriptor = ToolDescriptor(name: "swiftc", version: "test-swiftc", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    /// One source file, its folder's tree in and the file supplied, so the compile runs.
    private func compile(extraConfiguration: [String]) throws {
        let configuration = ([
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "moduleName=Kit",
        ] + extraConfiguration).joined(separator: "\n")
        let folder = try FolderManifest(baseFolderPath: "input:/pkg/Sources/Kit",
                                        entries: [FolderManifestEntry(name: "Kit.swift", isFolder: false, isPinned: true)])
        let tree = FolderSubtreeManifest(entries: [FolderSubtreeEntry(name: "Kit.swift", isFolder: false, isPinned: true)])
        let input = ProcessInput(inputValues: [
            SwiftCompiler.configuration:    ["config": .value(try configuration.intern())],
            SwiftCompiler.inputFolder:      ["folder0": .value(try folder.toJSON().intern())],
            SwiftCompiler.inputFolderTrees: ["input:/pkg/Sources/Kit": .value(try tree.toJSON().intern())],
            SwiftCompiler.inputSourceFiles: ["input:/pkg/Sources/Kit/Kit.swift": .value(try "// kit".intern())],
        ])
        _ = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind)).process(input: input)
    }

    func test_aTargetWithResourcesCompilesTheAccessorNamingItsBundle() throws {
        try compile(extraConfiguration: ["resourceBundleName=Kit_Kit"])

        let invocation = try XCTUnwrap(executor.invocations.last)
        XCTAssertTrue(invocation.inputFileNames.contains(SwiftCompilerConfiguration.resourceBundleAccessorFileName),
                      "\(invocation.inputFileNames)")
        XCTAssertTrue(invocation.arguments.contains { $0.hasSuffix(SwiftCompilerConfiguration.resourceBundleAccessorFileName) },
                      "\(invocation.arguments)")
        let source = SwiftCompilerConfiguration.resourceBundleAccessorSource(bundleName: "Kit_Kit")
        XCTAssertTrue(source.contains("static let module: Bundle"), source)
        XCTAssertTrue(source.contains("\"Kit_Kit.bundle\""), source)
        XCTAssertTrue(source.contains("Contents/Resources"), "the macOS layout is one of the places looked: \(source)")
    }

    func test_aTargetWithoutResourcesCompilesNoAccessor() throws {
        try compile(extraConfiguration: [])

        let invocation = try XCTUnwrap(executor.invocations.last)
        XCTAssertFalse(invocation.inputFileNames.contains(SwiftCompilerConfiguration.resourceBundleAccessorFileName),
                       "\(invocation.inputFileNames)")
    }
}
