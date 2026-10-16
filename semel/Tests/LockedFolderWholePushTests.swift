//
//  LockedFolderWholePushTests.swift
//  SemelCLITests
//
//  B-164. A push that reaches a locked folder pushes it whole: the lock declares all the
//  folder holds, so a part of it can only be refused at the commit. `push **/*.*` matches
//  no `LICENSE`, and Charts has one at its root. Over `InProcessConnection` with a live
//  processing loop, so the roots the barrier compares are the ones the engine folds.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class LockedFolderWholePushTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!
    private var lines: [String] = []

    private let package = "tree/Dependencies/Pkg"
    private let other   = "tree/Dependencies/Other"

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()

        try write("tree/App/main.swift", "print(1)\n")
        try write("tree/App/other.swift", "let other = 2\n")
        try write("tree/App/NOTES", "not matched by *.*\n")
        for folder in [package, other] {
            try write("\(folder)/Package.swift", "// swift-tools-version: 5.9\n")
            try write("\(folder)/LICENSE", "Apache License\n")
            try write("\(folder)/Sources/Pkg/Pkg.swift", "public struct Pkg {}\n")
            try writeLock(of: folder)
        }

        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite",
                                     engineConfigurationFile: URL(fileURLWithPath: "/tmp/test-semel.engine.config"))
        interpreter = CommandInterpreter(connection: InProcessConnection(handler: handler), baseDirectory: externalRoot.path)
        interpreter.output = { [weak self] line in self?.lines.append(line) }
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine = nil
        BuildEngine.shared = nil
        interpreter = nil
        try? FileManager.default.removeItem(at: externalRoot)
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ relativePath: String, _ text: String) throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o644)
    }

    /// The lock `prepare` writes for the copy on disk.
    private func writeLock(of folder: String) throws {
        let root = try FolderContentRoot.root(ofFolderAt: externalRoot.appendingPathComponent(folder))
        try write(DependencyLock.lockPath(forDependencyAt: folder), DependencyLock(contentRoot: root, fold: FolderContentRoot.formatTag).text)
    }

    private func push(_ arguments: String) {
        lines = []
        interpreter.handleCommand("push \(arguments)")
        engine.waitUntilIdleBlocking()
    }

    /// Whether `input:` holds a file with content at `path`.
    private func holds(_ path: String) throws -> Bool {
        guard let node = try engine.inputFileSystem.childNode(path: Path(path)), node.kind == StaticFile.kind,
              case .value = try node.readFromOutputPort(StaticFile.outputPort) else {
            return false
        }
        return true
    }

    private var refused: Bool {
        lines.contains { $0.contains("is locked, and the batch changes it") }
    }

    // MARK: - A pattern

    /// The owner's push: `**/*.*` matches every file of the copy but its `LICENSE`. The
    /// copy goes whole, the push says so before its own lines, and the batch lands.
    func test_aGlobPushThatMissesALicensePushesTheLockedFolderWholeAndLands() throws {
        push("**/*.*")

        XCTAssertFalse(refused, "\(lines)")
        XCTAssertEqual(lines.first, "Pushing \(other), \(package) whole: they are locked", "\(lines)")
        XCTAssertTrue(try holds("\(package)/LICENSE"))
        XCTAssertTrue(try holds("\(other)/LICENSE"))
        XCTAssertFalse(try holds("tree/App/NOTES"), "the widening goes no further than the locked folders")
    }

    /// One locked folder reached is named alone.
    func test_aPatternReachingOneLockedFolderNamesIt() throws {
        push("tree/Dependencies/Pkg/**/*.swift")

        XCTAssertFalse(refused, "\(lines)")
        XCTAssertEqual(lines.first, "Pushing \(package) whole: it is locked", "\(lines)")
        XCTAssertTrue(try holds("\(package)/LICENSE"))
        XCTAssertFalse(try holds("\(other)/Package.swift"), "a locked folder nothing matched is not pushed")
    }

    // MARK: - A list of files

    /// A file named below a locked folder stands for the folder; a file named outside it
    /// stays one file.
    func test_aFileNamedBelowALockedFolderPushesTheFolderWhole() throws {
        push("\(package)/Sources/Pkg/Pkg.swift tree/App/main.swift")

        XCTAssertFalse(refused, "\(lines)")
        XCTAssertEqual(lines.first, "Pushing \(package) whole: it is locked", "\(lines)")
        XCTAssertTrue(try holds("\(package)/LICENSE"))
        XCTAssertTrue(try holds("tree/App/main.swift"))
        XCTAssertFalse(try holds("tree/App/other.swift"))
    }

    /// A lock names its folder, so a lock pushed alone brings the folder with it: what lands
    /// a re-vendor whose copy and lock `prepare` wrote together.
    func test_aLockPushedAlonePushesItsFolderWhole() throws {
        push(DependencyLock.lockPath(forDependencyAt: package))

        XCTAssertFalse(refused, "\(lines)")
        XCTAssertEqual(lines.first, "Pushing \(package) whole: it is locked", "\(lines)")
        XCTAssertTrue(try holds(DependencyLock.lockPath(forDependencyAt: package)))
        XCTAssertTrue(try holds("\(package)/LICENSE"))
    }

    /// A lock the server holds as the disk has it is no news about its folder: pushed
    /// alone, it stays one file, as `semel-watch` pushes a tree's locks while it leaves the
    /// locked folders alone.
    func test_aLockTheServerHoldsAsItIsDoesNotWidenThePush() throws {
        push("tree")
        XCTAssertFalse(refused, "\(lines)")
        try write("\(package)/Sources/Pkg/Pkg.swift", "public struct Pkg { let edited = true }\n")

        push(DependencyLock.lockPath(forDependencyAt: package))

        XCTAssertFalse(refused, "the edit below the folder is not pushed: \(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Pushing ") && $0.contains(" whole: ") }, "\(lines)")
    }

    // MARK: - Already whole

    /// A push of the folder, or of a folder above it, already sends it whole, and says
    /// nothing more.
    func test_aFolderPushedWholeIsNotSaidToBeWidened() throws {
        push("tree")
        XCTAssertFalse(refused, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Pushing ") && $0.contains(" whole: ") }, "\(lines)")

        push("\(package) \(package)/Sources/Pkg/Pkg.swift")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Pushing ") && $0.contains(" whole: ") }, "\(lines)")
    }
}
