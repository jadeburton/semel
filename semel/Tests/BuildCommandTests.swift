//
//  BuildCommandTests.swift
//  SemelCLITests
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

/// B-57. `build <folder>` is the loop in one word — push, wait, errors — and a scripted
/// run exits non-zero when any command reported an error, which is what makes it a build
/// step rather than an interactive convenience.
final class BuildCommandTests: XCTestCase {

    private var connection: InProcessConnection!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try "int main(void) { return 0; }".write(to: externalRoot.appendingPathComponent("src/main.c"),
                                                 atomically: true, encoding: .utf8)
        let database = try DatabaseLayer()
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection   = InProcessConnection(handler: handler)
        interpreter  = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
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

    /// A product under `output:/src`, wired to a static file standing in for its builder.
    private func publishProduct(_ name: String, contents: String) throws {
        // Pinned, as a push would leave it; an unpinned folder is one the graph reports.
        _ = try BuildEngine.shared.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stand-in"), pinned: true)
        let (source, _) = try GraphSpecNode.staticFile(at: "input:/stand-in/\(name)").findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        _ = try product(name).findOrCreateMatchingNode()
    }

    /// `OutputFile(path: 'output:/src/<name>', input: ['product': StaticFile(path: 'input:/stand-in/<name>').output])`.
    private func product(_ name: String) -> GraphSpecNode {
        GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: "output:/src/\(name)"],
                      inputs: [OutputFile.inputPort: ["product": .staticFile(at: "input:/stand-in/\(name)")]])
    }

    /// A product whose source failed: one node with something of its own to say, which is
    /// what a report counts and what a scripted build's exit status rests on.
    private func publishFailedProduct(_ name: String, message: String) throws {
        _ = try BuildEngine.shared.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stand-in"), pinned: true)
        let (source, _) = try GraphSpecNode.staticFile(at: "input:/stand-in/\(name)").findOrCreateMatchingNode()
        _ = try product(name).findOrCreateMatchingNode()
        // Written after the wiring, which puts every output of its target back to pending.
        try source.writeToOutputPort(StaticFile.outputPort,
                                     value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    /// With no loop running the wait returns at once, so the macro's three steps are
    /// observable in order: the push happened, the wait settled, the report ran.
    func test_buildPushesWaitsAndReports() throws {
        interpreter.handleCommand("build src")

        let pushed = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: "src/main.c"))
        XCTAssertNotNil(pushed)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_buildTakesExactlyOneFolder() throws {
        XCTAssertEqual(interpreter.handleCommand("build"), .failed)

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// The exit status of a scripted run rests on this count, so an error a command
    /// reports must land in it — here a push of something that is not there.
    func test_aReportedErrorIsCounted() throws {
        interpreter.handleCommand("push nowhere")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// A build error is what the exit status is for: the `errors` report has to count,
    /// not just print. A product whose source failed is one error, named at the source.
    func test_aBuildErrorIsCounted() throws {
        try publishFailedProduct("broken.a", message: "the source is gone")

        interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    // MARK: - Following the formula's inputs (B-110)

    /// The graph a formula in `hello/` leaves when it names `<../clang.cfg>`: a source
    /// nobody pushed, and a node that needs it. No loop runs, so the shape is laid by hand.
    private func nameConfigBesideTheBuildFolder() throws {
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("hello"),
                                                withIntermediateDirectories: true)
        try "include 'clang'".write(to: externalRoot.appendingPathComponent("hello/hello.fmla"),
                                    atomically: true, encoding: .utf8)
        try "clang.compiler.target=x".write(to: externalRoot.appendingPathComponent("clang.cfg"),
                                            atomically: true, encoding: .utf8)
        _ = try GraphSpecNode.configFilter(prefix: "clang.compiler", input: ["config": .staticFile(at: "input:/clang.cfg")])
            .findOrCreateMatchingNode()
    }

    private func configIsPushed() throws -> Bool {
        let node = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: "clang.cfg"))
        return try XCTUnwrap(node.nodeAsAny() as? StaticFile).isPinned
    }

    /// The settle reports `clang.cfg` as not pushed; it is beside the build folder, under
    /// the base, so `build` pushes it and waits again.
    func test_buildPushesASourceTheFormulaNeedsFromTheTree() throws {
        try nameConfigBesideTheBuildFolder()

        interpreter.handleCommand("build hello")

        XCTAssertTrue(try configIsPushed())
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    /// A dot-named file the formula names — a resource such as CodeEdit's
    /// `.all-contributorsrc` — is followed by its path as any source is, though the push of
    /// the folder passed it over (B-77 item 5).
    func test_buildPushesADotNamedSourceTheFormulaNames() throws {
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("hello"),
                                                withIntermediateDirectories: true)
        try "include 'clang'".write(to: externalRoot.appendingPathComponent("hello/hello.fmla"),
                                    atomically: true, encoding: .utf8)
        try "{}".write(to: externalRoot.appendingPathComponent("hello/.all-contributorsrc"), atomically: true, encoding: .utf8)
        _ = try GraphSpecNode.configFilter(prefix: "clang.compiler",
                                           input: ["config": .staticFile(at: "input:/hello/.all-contributorsrc")])
            .findOrCreateMatchingNode()

        interpreter.handleCommand("build hello")

        let node = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: "hello/.all-contributorsrc"))
        XCTAssertTrue(try XCTUnwrap(node.nodeAsAny() as? StaticFile).isPinned)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_noFollowPushesTheNamedFolderAlone() throws {
        try nameConfigBesideTheBuildFolder()

        interpreter.handleCommand("build hello --no-follow")

        XCTAssertFalse(try configIsPushed())
        XCTAssertEqual(interpreter.errorsReported, 1, "the unpushed config is the report")
    }

    /// A source the report names that is not on disk stays the error it is.
    func test_aSourceMissingFromDiskIsNotPushedAndStaysReported() throws {
        try nameConfigBesideTheBuildFolder()
        try FileManager.default.removeItem(at: externalRoot.appendingPathComponent("clang.cfg"))

        interpreter.handleCommand("build hello")

        XCTAssertFalse(try configIsPushed())
        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// The line says where the source is from the formula's point of view, which is how
    /// the formula spelled it.
    func test_theSourceIsNamedRelativeToTheFormulasFolder() {
        XCTAssertEqual(CommandInterpreter.relativePath(to: "clang.cfg", from: "hello"), "../clang.cfg")
        XCTAssertEqual(CommandInterpreter.relativePath(to: "swift/MyLibrary", from: "swift/MyApp"), "../MyLibrary")
        XCTAssertEqual(CommandInterpreter.relativePath(to: "hello/extra.h", from: "hello"), "extra.h")
    }

    // MARK: - The one command to run next (B-110)

    /// A Swift tree with no configuration fails on missing settings; the report is where
    /// the reader looks, so it names `prepare`, the command that writes them.
    func test_aFailedBuildOfAPackageWithNoConfigNamesPrepare() throws {
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("pkg"),
                                                withIntermediateDirectories: true)
        try "// swift-tools-version:6.0".write(to: externalRoot.appendingPathComponent("pkg/Package.swift"),
                                               atomically: true, encoding: .utf8)
        try publishFailedProduct("broken.a", message: "the source is gone")
        var lines: [String] = []
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build pkg")

        XCTAssertTrue(lines.contains("pkg holds a Package.swift and no semel.config: "
                                     + "`semel-swift prepare pkg --platform macos` writes one; then build again."),
                      lines.joined(separator: "\n"))
    }

    // MARK: - --into

    /// The destination is the opt-in: with one, a clean build ends with its products on
    /// disk, which is what a build step is for.
    func test_aDestinationExportsTheProductsAfterACleanBuild() throws {
        try publishProduct("lib.a", contents: "archive")
        let destination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("lib.a"), encoding: .utf8), "archive")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    /// Without a destination the products still land somewhere known: `semel-out/<folder>`
    /// under the base (B-110).
    func test_withoutADestinationProductsGoToSemelOutUnderTheBase() throws {
        try publishProduct("lib.a", contents: "archive")

        interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 0)
        XCTAssertEqual(try String(contentsOf: externalRoot.appendingPathComponent("semel-out/src/lib.a"),
                                  encoding: .utf8), "archive")
    }

    /// Yesterday's products are not today's sources: a push of the tree leaves the export
    /// folder out, and a push of the folder itself says why nothing happened.
    func test_aLaterPushDoesNotSendTheExportFolderBackIn() throws {
        try publishProduct("lib.a", contents: "archive")
        interpreter.handleCommand("build src")

        interpreter.handleCommand("push .")
        XCTAssertNil(try BuildEngine.shared.inputFileSystem.childNode(path: "semel-out"))
        XCTAssertNotNil(try BuildEngine.shared.inputFileSystem.childNode(path: "src/main.c"))

        XCTAssertEqual(interpreter.handleCommand("push semel-out"), .failed)
        XCTAssertNil(try BuildEngine.shared.inputFileSystem.childNode(path: "semel-out"))
    }

    /// A destination inside the tree is left out of later pushes too.
    func test_aDestinationInsideTheTreeIsLeftOutOfLaterPushes() throws {
        try publishProduct("lib.a", contents: "archive")
        interpreter.handleCommand("build src --into \(externalRoot.path)/out")

        interpreter.handleCommand("push .")

        XCTAssertNil(try BuildEngine.shared.inputFileSystem.childNode(path: "out"))
        XCTAssertNotNil(try BuildEngine.shared.inputFileSystem.childNode(path: "src/main.c"))
    }

    /// A partial product set beside a non-zero exit would only mislead.
    func test_aBuildThatReportedErrorsExportsNothing() throws {
        try publishProduct("lib.a", contents: "archive")
        try publishFailedProduct("broken.a", message: "the source is gone")
        let destination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// B-142. The report under a failed build is grouped by the products the errors stop,
    /// and where the export would have been said, the products it was refused for are
    /// named.
    func test_aFailedBuildNamesTheProductsItDidNotExport() throws {
        try publishProduct("lib.a", contents: "archive")
        try publishFailedProduct("broken.a", message: "the source is gone")
        let destination = makeTempDirectory()
        var lines: [String] = []
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertTrue(lines.contains("Stopping output:/src/broken.a:"), lines.joined(separator: "\n"))
        XCTAssertEqual(lines.last { $0.hasPrefix("Not exported") },
                       "Not exported into \(destination.path): errors stop output:/src/broken.a.")
    }

    func test_intoNeedsADirectory() throws {
        interpreter.handleCommand("build src --into")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }
}
