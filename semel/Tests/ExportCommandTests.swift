//
//  ExportCommandTests.swift
//  SemelCLITests
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import XCTest

/// B-58. `export <folder> --into <dir>` copies every product under a folder of the output
/// file system into one directory, keeping the tree below the folder — the last step of
/// the clone-to-build loop, where `cp -o` did one file at a time.
final class ExportCommandTests: XCTestCase {

    private var interpreter: CommandInterpreter!
    private var destination: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        destination = makeTempDirectory()
        let database = try DatabaseLayer()
        BuildEngine.shared = try BuildEngine(database: database, startProcessingLoop: false)
        interpreter = CommandInterpreter(database: database, buildEngine: BuildEngine.shared,
                                         baseDirectory: makeTempDirectory().path)
    }

    override func tearDown() {
        BuildEngine.shared = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    /// A product is an `OutputFile` whose input is wired to whatever built it; here a
    /// static file stands in for the builder.
    private func publish(_ outputPath: String, contents: String) throws {
        let sourcePath = "input:/sources/" + outputPath.replacingOccurrences(of: "/", with: "_")
        let (source, _) = try GraphSpecNode.parse("StaticFile(path: '\(sourcePath)')").findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/\(outputPath)')").findOrCreateMatchingNode()
        try Wire.connectWire(database: interpreter.database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try product.requireID(),
                             toSymbolID: OutputFile.inputPort.asSymbolID(),
                             name: "product".asSymbolID())
    }

    private func exported(_ relativePath: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_exportsEveryProductUnderTheFolderKeepingTheTree() throws {
        try publish("Packages/libModels.a", contents: "models")
        try publish("Packages/Sub/libSub.a", contents: "sub")
        try publish("Elsewhere/libOther.a", contents: "other")

        try interpreter.handleCommand("export Packages --into \(destination.path)")

        XCTAssertEqual(try exported("libModels.a"), "models")
        XCTAssertEqual(try exported("Sub/libSub.a"), "sub")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("libOther.a").path),
                       "a product outside the folder is not exported")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_theDestinationIsRequired() throws {
        try publish("Packages/libModels.a", contents: "models")

        try interpreter.handleCommand("export Packages")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    func test_aFolderThatIsNotThereIsAnError() throws {
        try interpreter.handleCommand("export Nowhere --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// A product whose builder has not produced it has no content; exporting it is an
    /// error, not an empty file — the exit status of a scripted run rests on this.
    func test_anUnbuiltProductIsReportedNotWrittenEmpty() throws {
        _ = try GraphSpecNode.parse("OutputFile(path: 'output:/Packages/libModels.a')").findOrCreateMatchingNode()

        try interpreter.handleCommand("export Packages --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("libModels.a").path))
    }
}
