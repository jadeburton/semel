//
//  ExportCommandTests.swift
//  SemelCLITests
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

/// B-58. `export <folder> --into <dir>` copies every product under a folder of the output
/// file system into one directory, keeping the tree below the folder — the last step of
/// the clone-to-build loop, where `cp -o` did one file at a time.
final class ExportCommandTests: XCTestCase {

    private var connection: InProcessConnection!
    private var interpreter: CommandInterpreter!
    private var destination: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        destination = makeTempDirectory()
        let database = try DatabaseLayer()
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection   = InProcessConnection(handler: handler)
        interpreter  = CommandInterpreter(connection: connection, baseDirectory: makeTempDirectory().path)
    }

    override func tearDown() {
        BuildEngine.shared = nil
        connection = nil
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
        let (source, _) = try GraphSpecNode.staticFile(at: sourcePath).findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        _ = try GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: "output:/\(outputPath)"],
                              inputs: [OutputFile.inputPort: ["product": .staticFile(at: sourcePath)]])
            .findOrCreateMatchingNode()
    }

    private func exported(_ relativePath: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_exportsEveryProductUnderTheFolderKeepingTheTree() throws {
        try publish("Packages/libModels.a", contents: "models")
        try publish("Packages/Sub/libSub.a", contents: "sub")
        try publish("Elsewhere/libOther.a", contents: "other")

        interpreter.handleCommand("export Packages --into \(destination.path)")

        XCTAssertEqual(try exported("libModels.a"), "models")
        XCTAssertEqual(try exported("Sub/libSub.a"), "sub")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("libOther.a").path),
                       "a product outside the folder is not exported")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    /// B-108. An entry of a tree product leaves with the mode its tree carries: the
    /// executable of an app bundle is exported executable, and the plist beside it is not.
    /// The products are wired as `ProjectBuilder` wires a tree product's entries.
    func test_aTreeEntryIsExportedWithTheModeItsTreeCarries() throws {
        let tree = TreeManifest(entries: [
            TreeManifestEntry(path: "Hello",      hash: try "binary".intern(), mode: FileMetadata.executableMode),
            TreeManifestEntry(path: "Info.plist", hash: try "plist".intern(),  mode: FileMetadata.defaultMode),
        ])
        let treeSource = GraphSpecNode.staticFile(at: "input:/sources/bundle-tree")
        let (source, _) = try treeSource.findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try tree.toJSON().intern())
        for entry in tree.entries {
            let entryFile = GraphSpecNode(TreeFile.self,
                                          properties: [TreeFile.nameProperty: entry.path],
                                          inputs: [TreeFile.treeInputPort: ["tree": treeSource]])
            let (entryNode, _) = try entryFile.findOrCreateMatchingNode()
            try BuildEngine.shared.processOneNode(entryNode)
            _ = try GraphSpecNode(OutputFile.self,
                                  properties: [OutputFile.pathProperty: "output:/Hello.app/\(entry.path)"],
                                  inputs: [OutputFile.inputPort: ["product": entryFile.port(TreeFile.outputPort)]])
                .wiringFileMetadata()
                .findOrCreateMatchingNode()
        }

        interpreter.handleCommand("export Hello.app --into \(destination.path)")

        XCTAssertEqual(try exported("Hello"), "binary")
        XCTAssertEqual(try exportedMode("Hello"), 0o755)
        XCTAssertEqual(try exportedMode("Info.plist"), 0o644)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    /// A second export into the same folder replaces what the first left there, a file it
    /// left read-only included: a vendored resource is pushed read-only and leaves so, and
    /// `build --into` the same folder twice failed on every such file (B-125).
    func test_aSecondExportReplacesAReadOnlyFileTheFirstLeft() throws {
        try publish("Packages/libModels.a", contents: "models")
        interpreter.handleCommand("export Packages --into \(destination.path)")
        let exportedPath = destination.appendingPathComponent("libModels.a").path
        chmod(exportedPath, 0o444)
        XCTAssertEqual(try exportedMode("libModels.a"), 0o444)

        interpreter.handleCommand("export Packages --into \(destination.path)")

        XCTAssertEqual(try exported("libModels.a"), "models")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    private func exportedMode(_ relativePath: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(relativePath).path)
        return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
    }

    /// B-77. A tree product's links leave as links — a versioned framework's
    /// `Versions/Current` and the links at its top — and a link replaces what an earlier
    /// export left at its path, a folder of copies included, without following it.
    func test_aTreesLinksAreExportedAsLinks() throws {
        let tree = TreeManifest(entries: [
            TreeManifestEntry(path: "Tiny.framework/Versions/A/Tiny", hash: try "binary".intern(), mode: FileMetadata.executableMode),
            TreeManifestEntry(path: "Tiny.framework/Versions/Current", symbolicLinkTarget: "A"),
            TreeManifestEntry(path: "Tiny.framework/Tiny", symbolicLinkTarget: "Versions/Current/Tiny"),
        ])
        let treeSource = GraphSpecNode.staticFile(at: "input:/sources/framework-tree")
        let (source, _) = try treeSource.findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try tree.toJSON().intern())
        for entry in tree.entries {
            let entryFile = GraphSpecNode(TreeFile.self,
                                          properties: [TreeFile.nameProperty: entry.path],
                                          inputs: [TreeFile.treeInputPort: ["tree": treeSource]])
            let (entryNode, _) = try entryFile.findOrCreateMatchingNode()
            try BuildEngine.shared.processOneNode(entryNode)
            _ = try GraphSpecNode(OutputFile.self,
                                  properties: [OutputFile.pathProperty: "output:/Frameworks/\(entry.path)"],
                                  inputs: [OutputFile.inputPort: ["product": entryFile.port(TreeFile.outputPort)]])
                .wiringFileMetadata()
                .findOrCreateMatchingNode()
        }
        let staleCopy = destination.appendingPathComponent("Tiny.framework/Versions/Current/Tiny")
        try FileManager.default.createDirectory(at: staleCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "an earlier export's copy".write(to: staleCopy, atomically: true, encoding: .utf8)

        interpreter.handleCommand("export Frameworks --into \(destination.path)")

        let fileManager = FileManager.default
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Tiny.framework/Versions/Current").path), "A")
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Tiny.framework/Tiny").path),
                       "Versions/Current/Tiny")
        XCTAssertEqual(try exported("Tiny.framework/Tiny"), "binary", "read through the links")
        XCTAssertEqual(try exportedMode("Tiny.framework/Versions/A/Tiny"), 0o755)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_theDestinationIsRequired() throws {
        try publish("Packages/libModels.a", contents: "models")

        interpreter.handleCommand("export Packages")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    func test_aFolderThatIsNotThereIsAnError() throws {
        interpreter.handleCommand("export Nowhere --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// A product whose builder has not produced it has no content; exporting it is an
    /// error, not an empty file — the exit status of a scripted run rests on this.
    func test_anUnbuiltProductIsReportedNotWrittenEmpty() throws {
        _ = try GraphSpecNode.parse("OutputFile(path: 'output:/Packages/libModels.a')").findOrCreateMatchingNode()

        interpreter.handleCommand("export Packages --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("libModels.a").path))
    }
}
