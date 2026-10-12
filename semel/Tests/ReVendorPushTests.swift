//
//  ReVendorPushTests.swift
//  SemelCLITests
//
//  B-162. A push that brings a lock the server does not hold mirrors the folder that lock
//  locks: a copy re-vendored with fewer files lands with its lock, rather than leaving the
//  old copy's files below it for the barrier to refuse on every later push. Over
//  `InProcessConnection` with a live processing loop, so the roots the barrier compares
//  are the ones the engine folds.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class ReVendorPushTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!
    private var lines: [String] = []

    private let package = "tree/Dependencies/Pkg"
    private let lock    = "tree/Dependencies/Pkg.semel-lock"

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()

        try write("tree/App/main.swift", "print(1)\n")
        try write("tree/App/other.swift", "let other = 2\n")
        try write("\(package)/Package.swift", "// swift-tools-version: 5.9\n")
        try write("\(package)/Sources/Pkg/Kept.swift", "public struct Kept {}\n")
        try write("\(package)/Sources/Pkg/Dropped.swift", "public struct Dropped {}\n")
        try write("\(package)/Tests/__Snapshots__\u{F8FF}Silicon__/one.png", "one\n")
        try write("\(package)/Tests/__Snapshots__\u{F8FF}Silicon__/Nested/two.png", "two\n")
        try writeLock()

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

        pushTree()
        XCTAssertFalse(lines.contains { $0.contains("is locked") }, "the first copy lands: \(lines)")
        XCTAssertTrue(try holds("\(package)/Sources/Pkg/Dropped.swift"))
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

    private func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: externalRoot.appendingPathComponent(relativePath))
    }

    /// The lock `prepare` writes for the copy on disk.
    private func writeLock() throws {
        let root = try FolderContentRoot.root(ofFolderAt: externalRoot.appendingPathComponent(package))
        try write(lock, DependencyLock(contentRoot: root, fold: FolderContentRoot.formatTag).text)
    }

    /// `prepare` vendoring the next release: one file and one folder of snapshots gone, a
    /// folder of them under a new name, a file added, and the lock written for it all.
    private func reVendor() throws {
        try delete("\(package)/Sources/Pkg/Dropped.swift")
        try delete("\(package)/Tests/__Snapshots__\u{F8FF}Silicon__")
        try write("\(package)/Tests/__Snapshots__AppleSilicon__/one.png", "one\n")
        try write("\(package)/Sources/Pkg/Added.swift", "public struct Added {}\n")
        try writeLock()
    }

    private func pushTree() {
        lines = []
        interpreter.handleCommand("push tree")
        engine.waitUntilIdleBlocking()
    }

    /// Whether `input:` holds a file with content, or a folder, at `path`.
    private func holds(_ path: String) throws -> Bool {
        guard let node = try engine.inputFileSystem.childNode(path: Path(path)) else {
            return false
        }
        guard node.kind == StaticFile.kind else {
            return node.kind == Folder.kind
        }
        guard case .value = try node.readFromOutputPort(StaticFile.outputPort) else {
            return false
        }
        return true
    }

    private func pushedRoot(of folder: String) throws -> DataObjectHash {
        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path(folder)))
        return try node.readFromOutputPort(Folder.pushedContentRootOutputPort).expectValue()
    }

    // MARK: - A re-vendor

    /// The release renamed and dropped files: the push that brings the new lock takes the
    /// old copy's leftovers in its batch, and the barrier finds the folder as the lock
    /// describes it.
    func test_aReVendorThatDropsFilesLandsWithItsLock() throws {
        try reVendor()

        pushTree()

        XCTAssertFalse(lines.contains { $0.contains("is locked") }, "\(lines)")
        XCTAssertTrue(lines.contains("Locked anew: \(package); with the push, taking out 1 file and 1 folder the copy "
                                     + "no longer holds: \(package)/Sources/Pkg/Dropped.swift, "
                                     + "\(package)/Tests/__Snapshots__\u{F8FF}Silicon__/"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Not on disk, kept") || $0.hasPrefix("Removed") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix(ErrorMark.glyph) }, "\(lines)")
        XCTAssertFalse(try holds("\(package)/Sources/Pkg/Dropped.swift"))
        XCTAssertFalse(try holds("\(package)/Tests/__Snapshots__\u{F8FF}Silicon__"))
        XCTAssertTrue(try holds("\(package)/Sources/Pkg/Added.swift"))
        XCTAssertTrue(try holds("\(package)/Tests/__Snapshots__AppleSilicon__/one.png"))
        let recorded = try FolderContentRoot.root(ofFolderAt: externalRoot.appendingPathComponent(package))
        XCTAssertEqual(try pushedRoot(of: package), recorded)

        pushTree()
        XCTAssertFalse(lines.contains { $0.contains("is locked") }, "the next push lands too: \(lines)")
    }

    /// What the new lock removes is below its own folder: a file gone from elsewhere in
    /// the tree is kept and reported, as a push always did.
    func test_aFileGoneOutsideTheFolderLockedAnewIsKept() throws {
        try reVendor()
        try delete("tree/App/main.swift")

        pushTree()

        XCTAssertFalse(lines.contains { $0.contains("is locked") }, "\(lines)")
        XCTAssertTrue(try holds("tree/App/main.swift"))
        XCTAssertTrue(lines.contains("Not on disk, kept: tree/App/main.swift (push only adds; rm removes it)"), "\(lines)")
    }

    /// A new lock the copy does not match: the push's removal is part of its batch, so the
    /// barrier's refusal takes it back with the rest, and the push says none of it stands.
    func test_aReVendorWhoseLockDoesNotMatchIsRefusedRemovalAndAll() throws {
        try reVendor()
        try write("\(package)/Sources/Pkg/Kept.swift", "public struct Kept { let editedAfterTheLock = 1 }\n")

        pushTree()

        XCTAssertTrue(lines.contains { $0.hasPrefix("Locked anew: \(package); with the push, taking out") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("sent, and none of it committed") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("\(package) is locked") }, "\(lines)")
        XCTAssertTrue(try holds("\(package)/Sources/Pkg/Dropped.swift"), "the removal went with the batch")
        XCTAssertFalse(try holds("\(package)/Sources/Pkg/Added.swift"))
    }

    // MARK: - No new lock

    /// A file gone from a locked copy with no new lock is a change the lock does not
    /// describe: nothing is removed, and the barrier refuses the push.
    func test_aFileGoneFromALockedCopyWithoutANewLockIsRefusedAndKept() throws {
        try delete("\(package)/Sources/Pkg/Dropped.swift")
        try write("\(package)/Sources/Pkg/Kept.swift", "public struct Kept { let edited = 1 }\n")

        pushTree()

        XCTAssertTrue(lines.contains { $0.contains("\(package) is locked") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Locked anew") }, "\(lines)")
        XCTAssertTrue(try holds("\(package)/Sources/Pkg/Dropped.swift"))
    }

    /// A copy whose lock the push brings and whose files are all still on disk removes
    /// nothing and says nothing of removing.
    func test_aNewLockOverACopyThatLostNothingRemovesNothing() throws {
        try write("\(package)/Sources/Pkg/Added.swift", "public struct Added {}\n")
        try writeLock()

        pushTree()

        XCTAssertFalse(lines.contains { $0.contains("is locked") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Locked anew") || $0.hasPrefix("Removed") }, "\(lines)")
        XCTAssertTrue(try holds("\(package)/Sources/Pkg/Dropped.swift"))
    }
}
