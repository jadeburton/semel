//
//  ProductsExportTests.swift
//  SemelMonitorTests
//
//  B-150 phase 2, over an in-process server. The products window lists `output:` folder by
//  folder exactly as `ls -o <folder>` lists it, and its export writes the bytes and modes
//  `export <folder> --into <dir>` writes, through the same code, a selection writing its
//  products where the whole export would.
//

@testable import SemelCore
import Foundation
import SemelCLI
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest
@testable import SemelMonitor

final class ProductsExportTests: XCTestCase {

    private var connection: InProcessConnection?
    private var interpreter: CommandInterpreter?
    private var printed: [String] = []
    private var temporaryFolders: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTemporaryFolder())
        let database = try DatabaseLayer()
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite",
                                      engineConfigurationFile: makeTemporaryFolder().appendingPathComponent("semel.engine.config"))
        let connection  = InProcessConnection(handler: handler)
        let interpreter = CommandInterpreter(connection: connection, baseDirectory: makeTemporaryFolder().path)
        interpreter.output = { [weak self] in self?.printed.append($0) }
        self.connection  = connection
        self.interpreter = interpreter
    }

    override func tearDown() {
        BuildEngine.shared = nil
        connection  = nil
        interpreter = nil
        temporaryFolders.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    // MARK: - The listing

    func test_theListingIsWhatLsListsInEveryFolder() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try publish("Packages/libModels.a", contents: "models")
        try publish("Packages/libLists.a", contents: "a longer library")
        try publish("Packages/Sub/libSub.a", contents: "sub")
        try publish("App/App", contents: "the app")
        try publishBundle()
        _ = try GraphSpecNode.parse("OutputFile(path: 'output:/Packages/libUnbuilt.a')").findOrCreateMatchingNode()

        let snapshot = try ProductsSnapshot.read(through: interpreter)
        XCTAssertEqual(snapshot.folders.map(\.folder),
                       ["", "App", "Hello.app", "Hello.app/Contents", "Packages", "Packages/Sub"])

        for listing in snapshot.folders {
            var model = ProductsWindowModel(snapshot: snapshot, card: nil)
            model.select(.folder(listing.folder))
            XCTAssertEqual(model.rows.map(Self.nameAndSize), try lsRows(of: listing.folder), "output:/\(listing.folder)")
        }
    }

    // MARK: - Export

    func test_exportingAFolderWritesWhatExportWrites() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try publish("Packages/libModels.a", contents: "models")
        try publish("Packages/Sub/libSub.a", contents: "sub")
        try publishBundle()
        let byCommand = makeTemporaryFolder()
        let byWindow  = makeTemporaryFolder()

        for folder in ["Packages", "Hello.app"] {
            interpreter.handleCommand("export \(folder) --into \(byCommand.appendingPathComponent(folder).path)")
            var model = ProductsWindowModel(snapshot: try ProductsSnapshot.read(through: interpreter), card: nil)
            model.select(.folder(folder))
            let request = try XCTUnwrap(model.exportRequest)
            XCTAssertNil(request.selection)
            _ = try interpreter.export(folder: request.folder, selecting: request.selection,
                                       into: byWindow.appendingPathComponent(folder).path)
        }

        XCTAssertEqual(interpreter.errorsReported, 0, printed.joined(separator: "\n"))
        let written = try contents(of: byCommand)
        XCTAssertEqual(written.map(\.path), ["Hello.app/Contents/Info.plist", "Hello.app/Hello",
                                             "Packages/Sub/libSub.a", "Packages/libModels.a"])
        XCTAssertEqual(written.first { $0.path == "Hello.app/Hello" }?.mode, 0o755)
        XCTAssertEqual(try contents(of: byWindow), written, "the same bytes and modes")
    }

    func test_exportingASelectionWritesItsProductsWhereTheWholeExportWould() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try publish("Packages/libModels.a", contents: "models")
        try publish("Packages/libLists.a", contents: "lists")
        try publish("Packages/Sub/libSub.a", contents: "sub")
        let destination = makeTemporaryFolder()
        var model = ProductsWindowModel(snapshot: try ProductsSnapshot.read(through: interpreter), card: nil)
        model.select(.folder("Packages"))
        model.selectRows(["Packages/libModels.a", "Packages/Sub"])
        let request = try XCTUnwrap(model.exportRequest)

        let exported = try interpreter.export(folder: request.folder, selecting: request.selection, into: destination.path)

        XCTAssertEqual(exported, 2)
        XCTAssertEqual(try contents(of: destination).map(\.path), ["Sub/libSub.a", "libModels.a"])
    }

    // MARK: - Products

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

    /// A tree product's entries, an executable among them, wired as `ProjectBuilder` wires
    /// them: what carries a mode other than the default.
    private func publishBundle() throws {
        let tree = TreeManifest(entries: [
            TreeManifestEntry(path: "Hello",               hash: try "binary".intern(), mode: FileMetadata.executableMode),
            TreeManifestEntry(path: "Contents/Info.plist", hash: try "plist".intern(),  mode: FileMetadata.defaultMode),
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
    }

    // MARK: - Reading what was written

    /// A row as `ls` prints it: the name, `/` after a folder's, and the size or `-`.
    private struct NameAndSize: Equatable {
        let name: String
        let size: String
    }

    private static func nameAndSize(_ row: ProductRow) -> NameAndSize {
        NameAndSize(name: row.name, size: row.size.map(String.init) ?? "-")
    }

    /// `ls -o <folder>`'s lines as names and sizes: each line is the mode, the size and
    /// the name, then a state in brackets.
    private func lsRows(of folder: String) throws -> [NameAndSize] {
        let interpreter = try XCTUnwrap(self.interpreter)
        printed = []
        interpreter.handleCommand(folder.isEmpty ? "ls -o" : "ls -o \(folder)")
        return printed.filter { $0 != "(empty)" }.map { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return NameAndSize(name: fields[2], size: fields[1])
        }
    }

    private struct WrittenFile: Equatable {
        let path: String
        let bytes: Data
        let mode: Int
    }

    /// Every file below `folder`, by its path below it, in path order.
    private func contents(of folder: URL) throws -> [WrittenFile] {
        let fileManager = FileManager.default
        let paths = try XCTUnwrap(fileManager.subpaths(atPath: folder.path)).sorted()
        return try paths.compactMap { path in
            let url = folder.appendingPathComponent(path)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return nil
            }
            let mode = (attributes[.posixPermissions] as? Int ?? 0) & 0o777
            return WrittenFile(path: path, bytes: try Data(contentsOf: url), mode: mode)
        }
    }

    private func makeTemporaryFolder() -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-monitor-tests/\(UUID().uuidString)", isDirectory: true)
        temporaryFolders.append(folder)
        return folder
    }
}
