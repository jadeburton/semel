//
//  StringCatalogCompilerTests.swift
//  SemelAppleTests
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class StringCatalogCompilerTests: SemelAppleTestCase {

    private let descriptor = ToolDescriptor(name: "xcstringstool", version: "Xcode 26.6 (17F113)", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func process() throws -> ProcessOutput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            """
        let node = try StringCatalogCompiler(thisNode: NodeRecord(id: 1, kind: StringCatalogCompiler.kind))
        return try node.process(input: ProcessInput(inputValues: [
            StringCatalogCompiler.configuration: ["configuration": .value(try configuration.intern())],
            StringCatalogCompiler.catalog: ["input:/app/Resources/Localizable.xcstrings": .value(try "{}".intern())],
        ]))
    }

    /// The catalog goes in under its own name — the table is named after the file — and
    /// everything xcstringstool writes comes back as one tree.
    func test_compilesTheCatalogUnderItsOwnNameIntoATree() throws {
        executor.producedTrees["out"] = ["en.lproj/Localizable.strings": Array("\"hi\" = \"hi\";".utf8),
                                         "de.lproj/Localizable.strings": Array("\"hi\" = \"hallo\";".utf8)]

        let output = try process()

        XCTAssertEqual(executor.lastInputFileNames, ["Localizable.xcstrings"])
        XCTAssertEqual(executor.lastArguments, ["compile", "Localizable.xcstrings", "--output-directory", "out"])
        let tree = try treeManifest(from: output.outputValues[StringCatalogCompiler.output])
        XCTAssertEqual(tree.entries.map(\.path), ["de.lproj/Localizable.strings", "en.lproj/Localizable.strings"])
    }

    func test_aFailedRunIsTheToolsError() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: Localizable.xcstrings is not valid JSON"

        let output = try process()

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[StringCatalogCompiler.output]) else {
            return XCTFail("the tree must carry the error")
        }
        XCTAssertTrue(try messageHash.resolveAsString().contains("not valid JSON"))
    }
}
