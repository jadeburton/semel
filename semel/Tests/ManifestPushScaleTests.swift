//
//  ManifestPushScaleTests.swift
//  SemelCLITests
//
//  B-132. A push of a folder compares the disk with what the server holds before it sends
//  anything, and sends only where the two differ. Its cost is pinned here in requests, the
//  unit a push paid per file before: an unchanged push of 400 files in 40 folders sends a
//  handful, a one-file change sends that file and the queries on its path, and a fresh
//  push sends every file, several to a request. Over `InProcessConnection` with a live
//  processing loop, so the roots compared are the ones the engine folds.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

/// Every request the client sends, on its way to the real connection.
private final class CountingConnection: SemelConnection {

    private let underlying: any SemelConnection
    private let lock = NSLock()
    private var sent: [DaemonRequest] = []

    init(_ underlying: any SemelConnection) {
        self.underlying = underlying
    }

    var onEvent: ((Event) -> Void)? {
        get { underlying.onEvent }
        set { underlying.onEvent = newValue }
    }

    func send(_ request: Request, body: Data?, onPart: (Response) throws -> Void) throws -> (Response, Data?) {
        if case .daemon(let daemonRequest) = request {
            lock.withLock { sent.append(daemonRequest) }
        }
        return try underlying.send(request, body: body, onPart: onPart)
    }

    /// What was sent since the last call, and forget it.
    func takeSent() -> [DaemonRequest] {
        lock.withLock {
            defer { sent = [] }
            return sent
        }
    }
}

final class ManifestPushScaleTests: XCTestCase {

    private var engine: BuildEngine!
    private var connection: CountingConnection!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!
    private var lines: [String] = []

    private static let groups           = 4
    private static let foldersPerGroup  = 10
    private static let filesPerFolder   = 10
    private static let fileCount        = groups * foldersPerGroup * filesPerFolder

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        for group in 0..<Self.groups {
            for folder in 0..<Self.foldersPerGroup {
                for file in 0..<Self.filesPerFolder {
                    try write("tree/group\(group)/folder\(folder)/file\(file).txt", "\(group) \(folder) \(file)\n")
                }
            }
        }

        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection  = CountingConnection(InProcessConnection(handler: handler))
        interpreter = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
        interpreter.output = { [weak self] line in self?.lines.append(line) }
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
        _ = connection.takeSent()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine = nil
        BuildEngine.shared = nil
        connection = nil
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

    /// Pushes the tree and returns what the push sent; `settle` waits for the engine to
    /// fold what it was sent, as a build's `wait` does before the next push.
    private func pushTree(settle: Bool = true) -> [DaemonRequest] {
        lines = []
        interpreter.handleCommand("push tree")
        let sent = connection.takeSent()
        if settle {
            engine.waitUntilIdleBlocking()
        }
        return sent
    }

    private func pushedFiles(_ sent: [DaemonRequest]) -> [String] {
        sent.flatMap { request -> [String] in
            switch request {
            case .pushFile(let path, _):
                return [path]
            case .pushFiles(let files):
                return files.map(\.path)
            default:
                return []
            }
        }
    }

    // MARK: - Costs

    /// A tree the server has never seen sends every file, several to a request, and the
    /// one question before them.
    func test_aFreshPushSendsEveryFileSeveralToARequest() {
        let sent = pushTree()

        let requestsOfFiles = (Self.fileCount + FilePlugin.filesPerRequest - 1) / FilePlugin.filesPerRequest
        XCTAssertEqual(pushedFiles(sent).count, Self.fileCount)
        XCTAssertEqual(Set(pushedFiles(sent)).count, Self.fileCount, "each file once")
        XCTAssertEqual(sent.count, requestsOfFiles + 4, "the roots, the batch around the files, and the folder: \(sent.filter { if case .pushFiles = $0 { return false }; return true })")
        XCTAssertEqual(sent.first, .contentRoots(path: "tree"))
        XCTAssertTrue(lines.contains("Pushed \(Self.fileCount) files and 1 folder"), "\(lines)")
    }

    /// Nothing changed: one question, and the batch around nothing. No file is sent and no
    /// folder is listed, and the report says what it always said.
    func test_anUnchangedPushSendsAHandfulOfRequests() {
        _ = pushTree()

        let sent = pushTree()

        XCTAssertEqual(sent, [.contentRoots(path: "tree"), .beginBatch, .endBatch])
        XCTAssertTrue(lines.contains("Pushed \(Self.fileCount) files and 1 folder, \(Self.fileCount) unchanged"), "\(lines)")
    }

    /// One file edited: the folders on its path are listed in one request, and the one
    /// file is sent.
    func test_aOneFileChangeSendsThatFileAndTheQueriesOnItsPath() throws {
        _ = pushTree()
        try write("tree/group2/folder5/file3.txt", "edited\n")

        let sent = pushTree()

        XCTAssertEqual(sent, [.contentRoots(path: "tree"),
                              .folderChildren(paths: ["tree", "tree/group2", "tree/group2/folder5"]),
                              .beginBatch,
                              .pushFile(path: "tree/group2/folder5/file3.txt", mode: 0o644),
                              .endBatch])
        XCTAssertTrue(lines.contains("Pushed \(Self.fileCount) files and 1 folder, \(Self.fileCount - 1) unchanged"),
                      "\(lines)")
    }

    // MARK: - What a comparison must not miss

    /// A file made executable is a change though its bytes are not: the mode is on its
    /// line in the root.
    func test_aModeChangeAloneIsSent() throws {
        _ = pushTree()
        chmod(externalRoot.appendingPathComponent("tree/group0/folder0/file0.txt").path, 0o755)

        let sent = pushTree()

        XCTAssertEqual(pushedFiles(sent), ["tree/group0/folder0/file0.txt"])
        XCTAssertTrue(sent.contains(.pushFile(path: "tree/group0/folder0/file0.txt", mode: 0o755)))
    }

    /// A new file and a new folder are sent; nothing else is.
    func test_aNewFileAndANewFolderAreSent() throws {
        _ = pushTree()
        try write("tree/group1/folder1/new.txt", "new\n")
        try write("tree/group3/fresh/deeper/one.txt", "one\n")

        let sent = pushTree()

        XCTAssertEqual(pushedFiles(sent), ["tree/group1/folder1/new.txt", "tree/group3/fresh/deeper/one.txt"])
    }

    /// Pushed again before the engine has folded the first push in, and with the disk put
    /// back as it was: the roots the server holds are stale — they still describe the disk
    /// as it is now — and it says so, so the file is compared rather than skipped on a root
    /// that no longer describes the graph. `begin` holds the engine, so nothing folds.
    func test_aPushBeforeTheLastIsFoldedStillSendsWhatDiffers() throws {
        _ = pushTree()
        interpreter.handleCommand("begin")
        try write("tree/group0/folder3/file7.txt", "changed\n")
        _ = pushTree(settle: false)
        try write("tree/group0/folder3/file7.txt", "0 3 7\n")

        let sent = pushTree(settle: false)
        interpreter.handleCommand("commit")

        XCTAssertEqual(pushedFiles(sent), ["tree/group0/folder3/file7.txt"])
    }

    /// A framework's links (B-77): unchanged, nothing is sent for them either; and the bytes
    /// a file link holds, and the copy below a folder link, follow what they name, as a
    /// push of the folder always refreshed them.
    func test_linksAreComparedAndFollowWhatTheyName() throws {
        try write("tree/fw/Versions/A/Tiny", "binary")
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: externalRoot.appendingPathComponent("tree/fw/Versions/Current").path,
                                           withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: externalRoot.appendingPathComponent("tree/fw/Tiny").path,
                                           withDestinationPath: "Versions/Current/Tiny")
        _ = pushTree()

        XCTAssertEqual(pushTree(), [.contentRoots(path: "tree"), .beginBatch, .endBatch])

        try write("tree/fw/Versions/A/Tiny", "rebuilt")
        let sent = pushTree()

        XCTAssertEqual(pushedFiles(sent), ["tree/fw/Versions/A/Tiny", "tree/fw/Versions/Current/Tiny"])
        XCTAssertTrue(sent.contains(.pushSymbolicLink(path: "tree/fw/Tiny", target: "Versions/Current/Tiny",
                                                      referent: .file(mode: 0o644))), "\(sent)")
        XCTAssertFalse(sent.contains(.pushSymbolicLink(path: "tree/fw/Versions/Current", target: "A", referent: .folder)),
                       "the folder link itself did not change")
    }

    // MARK: - A dot-named file a formula names (B-77 item 5)

    /// A push of the folder passes a new dot-named file over; `push` naming it exactly
    /// sends it. From then on the folder's push folds it as the server does: unchanged,
    /// nothing is sent and nothing is said to be missing; edited, it is sent again; gone
    /// from disk, it is reported and kept as any pushed file is.
    func test_aDotNamedFilePushedByItsPathIsComparedByTheFolderFromThenOn() throws {
        try write("tree/group0/.all-contributorsrc", "{\"contributors\": []}\n")
        XCTAssertEqual(pushedFiles(pushTree()).filter { $0.contains("/.") }, [], "a walk leaves dot-names out")

        lines = []
        interpreter.handleCommand("push tree/group0/.all-contributorsrc")
        XCTAssertEqual(pushedFiles(connection.takeSent()), ["tree/group0/.all-contributorsrc"], "\(lines)")
        engine.waitUntilIdleBlocking()

        XCTAssertEqual(pushTree(), [.contentRoots(path: "tree"), .beginBatch, .endBatch])
        XCTAssertFalse(lines.contains { $0.hasPrefix("Not on disk") }, "\(lines)")

        try write("tree/group0/.all-contributorsrc", "{\"contributors\": [\"someone\"]}\n")
        XCTAssertEqual(pushedFiles(pushTree()), ["tree/group0/.all-contributorsrc"])

        try FileManager.default.removeItem(at: externalRoot.appendingPathComponent("tree/group0/.all-contributorsrc"))
        XCTAssertEqual(pushedFiles(pushTree()), [])
        XCTAssertTrue(lines.contains("Not on disk, kept: 1 file (push only adds; rm removes them): tree/group0/.all-contributorsrc"),
                      "\(lines)")
    }

    /// Deleted on disk, the file stays in the graph, and the push says so; nothing is sent
    /// for it.
    func test_aFileGoneFromDiskIsReportedAndKept() throws {
        _ = pushTree()
        try FileManager.default.removeItem(at: externalRoot.appendingPathComponent("tree/group1/folder2/file4.txt"))

        let sent = pushTree()

        XCTAssertEqual(pushedFiles(sent), [])
        XCTAssertTrue(lines.contains("Not on disk, kept: 1 file (push only adds; rm removes them): tree/group1/folder2/file4.txt"),
                      "\(lines)")
    }
}
