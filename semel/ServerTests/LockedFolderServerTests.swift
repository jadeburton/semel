//
//  LockedFolderServerTests.swift
//  SemelServerTests
//
//  B-146 at the server: the outermost `commit` puts a batch through the lock barrier and
//  answers `batchRejected` when it moved a locked folder without its lock; a push outside a
//  batch is a batch of one; a connection that closes with a batch open is committed and
//  checked the same; and a refused batch wakes nothing.
//

@testable import SemelCLI
@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class LockedFolderServerTests: RequestHandlerTestCase {

    private var directory: URL!
    private var socketPath: String!
    private var server: Server!
    private var disk: URL!

    private let package = "Dependencies/Pkg"
    private let lock    = "Dependencies/Pkg.semel-lock"
    private let source  = "Dependencies/Pkg/Sources/Pkg/Pkg.swift"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("semelserv.sock").path
        server = Server(handler: handler, socketPath: socketPath)
        try server.start()

        disk = directory.appendingPathComponent("disk", isDirectory: true)
        try write("Package.swift", "// swift-tools-version: 5.9\n")
        try write("Sources/Pkg/Pkg.swift", "public struct Pkg {}\n")
        try daemon(.beginBatch)
        try daemon(.pushFile(path: "\(package)/Package.swift", mode: 0o644), body: Data("// swift-tools-version: 5.9\n".utf8))
        try daemon(.pushFile(path: source, mode: 0o644), body: Data("public struct Pkg {}\n".utf8))
        try daemon(.pushFile(path: lock, mode: 0o644), body: Data(try lockText().utf8))
        try daemon(.endBatch)
    }

    override func tearDown() {
        server.stop()
        server = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func write(_ relativePath: String, _ text: String) throws {
        let url = disk.appendingPathComponent(package).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The lock `prepare` writes for the copy on disk.
    private func lockText() throws -> String {
        DependencyLock(contentRoot: try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent(package)),
                       fold: FolderContentRoot.formatTag).text
    }

    private func daemon(_ connection: SocketConnection, _ request: DaemonRequest, body: Data? = nil) throws -> Response {
        try connection.send(.daemon(request), body: body).0
    }

    /// The text `input:` holds at `path`; nil when it holds nothing there.
    private func held(_ path: String) -> String? {
        let (response, body) = handler.handle(.daemon(.fetch(fileSystem: .input, path: path)), body: nil, session: session)
        guard case .daemon(.fetch) = response else {
            return nil
        }
        return body.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Over a socket

    func test_commitAnswersBatchRejectedOverASocketWithThePaths() throws {
        let client = try SocketConnection.connect(to: socketPath)
        XCTAssertEqual(try daemon(client, .beginBatch), .daemon(.ok))
        _ = try daemon(client, .pushFile(path: source, mode: 0o644), body: Data("public struct Pkg { let edited = 1 }\n".utf8))
        _ = try daemon(client, .pushFile(path: "App/main.swift", mode: 0o644), body: Data("print(1)\n".utf8))

        guard case .error(.batchRejected(let folder, let lockPath, let expected, let found, let paths)) =
                try daemon(client, .endBatch) else {
            return XCTFail("the commit was not refused")
        }
        XCTAssertEqual(folder, package)
        XCTAssertEqual(lockPath, lock)
        XCTAssertEqual(expected, .contentRoot(try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent(package))))
        XCTAssertNotNil(found)
        XCTAssertEqual(paths, [source])
        XCTAssertEqual(held(source), "public struct Pkg {}\n", "the locked file is as it was")
        XCTAssertNil(held("App/main.swift"), "and so is every other path of the batch")
        client.close()
    }

    func test_aRefusedCommitLeavesNoBatchOpenAndTheNextOneIsItsOwn() throws {
        try daemon(.beginBatch)
        try daemon(.pushFile(path: source, mode: 0o644), body: Data("edited\n".utf8))
        XCTAssertNotNil(daemonError(.endBatch))
        XCTAssertEqual(session.openBatchDepth, 0)
        XCTAssertNil(session.journal)

        try daemon(.beginBatch)
        try daemon(.pushFile(path: "App/main.swift", mode: 0o644), body: Data("print(1)\n".utf8))
        try daemon(.endBatch)
        XCTAssertEqual(held("App/main.swift"), "print(1)\n")
    }

    // MARK: - Batches of one, nested batches

    func test_aPushOutsideABatchIsCheckedAsABatchOfOne() throws {
        guard case .batchRejected(let folder, _, _, _, let paths)? =
                daemonError(.pushFile(path: source, mode: 0o644), body: Data("edited\n".utf8)) else {
            return XCTFail("the push was not refused")
        }
        XCTAssertEqual(folder, package)
        XCTAssertEqual(paths, [source])
        XCTAssertEqual(held(source), "public struct Pkg {}\n")
        XCTAssertEqual(session.openBatchDepth, 0)
    }

    func test_aRemovalOutsideABatchIsCheckedAsABatchOfOne() throws {
        guard case .batchRejected? = daemonError(.remove(pattern: source)) else {
            return XCTFail("the removal was not refused")
        }
        XCTAssertEqual(held(source), "public struct Pkg {}\n")
    }

    func test_nestedBatchesShareOneJournalAndOnlyTheOutermostCommitChecks() throws {
        try daemon(.beginBatch)
        try daemon(.pushFile(path: "App/main.swift", mode: 0o644), body: Data("print(1)\n".utf8))
        try daemon(.beginBatch)
        try daemon(.pushFile(path: source, mode: 0o644), body: Data("edited\n".utf8))
        let journal = try XCTUnwrap(session.journal)
        XCTAssertEqual(try daemon(.endBatch).0, .ok, "an inner commit only counts")
        XCTAssertTrue(session.journal === journal)
        XCTAssertEqual(journal.paths.map(\.string), ["App", "App/main.swift", "Dependencies", package,
                                                      "\(package)/Sources", "\(package)/Sources/Pkg", source])

        guard case .batchRejected? = daemonError(.endBatch) else {
            return XCTFail("the outermost commit was not refused")
        }
        XCTAssertNil(held("App/main.swift"), "the outer batch's push goes with the inner one's")
    }

    func test_aReVendorThatBringsItsLockLands() throws {
        try write("Sources/Pkg/Pkg.swift", "public struct Pkg { let version = 2 }\n")
        try daemon(.beginBatch)
        try daemon(.pushFile(path: source, mode: 0o644), body: Data("public struct Pkg { let version = 2 }\n".utf8))
        try daemon(.pushFile(path: lock, mode: 0o644), body: Data(try lockText().utf8))
        XCTAssertEqual(try daemon(.endBatch).0, .ok)
        XCTAssertEqual(held(source), "public struct Pkg { let version = 2 }\n")
    }

    // MARK: - Waking

    /// A refused batch leaves the loop nothing to do: its folders are folded back and no
    /// node is scheduled. Its one wake-up is still sent, so that the wake-ups it asked for
    /// are answered and a later `wait` does not wait for them.
    func test_aRefusedBatchThatReachedNoConsumerLeavesNothingToSettle() throws {
        let signalsBefore = engine.loopSignalsSent
        try daemon(.beginBatch)
        try daemon(.pushFile(path: source, mode: 0o644), body: Data("edited\n".utf8))
        XCTAssertNotNil(daemonError(.endBatch))
        XCTAssertEqual(try database.node.countScheduled(), 0, "a refused batch schedules nothing")
        XCTAssertTrue(try database.metadata.selectKeys(withPrefix: "contentRootDirty/").isEmpty,
                      "and leaves no folder to fold")
        XCTAssertEqual(engine.loopSignalsSent, signalsBefore + 1, "one wake-up, as any batch sends")
    }

    /// With a running loop, a `wait` after a refused batch returns: the batch's wake-ups
    /// were answered.
    func test_aWaitAfterARefusedBatchReturns() throws {
        engine.startProcessingLoop()
        defer { engine.stopProcessingLoop() }
        engine.waitUntilIdleBlocking()
        try daemon(.beginBatch)
        try daemon(.pushFile(path: source, mode: 0o644), body: Data("edited\n".utf8))
        XCTAssertNotNil(daemonError(.endBatch))

        let returned = expectation(description: "the wait returned")
        DispatchQueue.global().async {
            _ = self.handler.handle(.daemon(.wait), body: nil, session: self.session)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 10)
    }

    // MARK: - A closing connection

    func test_aConnectionClosingWithABatchOpenIsCheckedAsACommitWouldBe() throws {
        let client = try SocketConnection.connect(to: socketPath)
        _ = try daemon(client, .beginBatch)
        _ = try daemon(client, .pushFile(path: source, mode: 0o644), body: Data("edited\n".utf8))
        client.close()

        let gone = expectation(description: "connection removed")
        DispatchQueue.global().async {
            while self.server.connectionCount != 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(held(source), "public struct Pkg {}\n", "the closing connection's batch was refused")
    }
}
