//
//  FilePluginTests.swift
//  SemelCLITests
//
//  push, rm and cp over a scripted connection: what each sends, with what body, and how
//  it reports. The disk side is real (temporary directories); the graph side is the fake.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class FilePluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        externalRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection, baseDirectory: externalRoot.path)
    }

    private func write(_ relativePath: String, _ text: String) throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Fixes the mode so the push assertions do not depend on the runner's umask.
        chmod(url.path, 0o644)
    }

    private func run(_ verb: String, _ tokens: [String]) throws {
        try FilePlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    // MARK: - push

    func test_pushSendsAFileWithItsBytesInsideOneBatch() throws {
        try write("a.c", "int main() {}")
        connection.reply(.ok)
        connection.reply(.pushFile(didChange: true))
        connection.reply(.ok)

        try run("push", ["a.c"])

        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .pushFile(path: "a.c", mode: 0o644), .endBatch])
        XCTAssertEqual(connection.requests[1].body, Data("int main() {}".utf8))
        XCTAssertEqual(context.messages, ["Push file: a.c"])
    }

    /// B-132. A push of a folder asks what the server holds before it sends anything.
    private func replyHoldingNothing() throws {
        connection.reply(.contentRoots, body: try MessageCoder.encode([HeldFolderRoot]()))
    }

    func test_pushOfAFolderSendsTheFolderThenItsFiles() throws {
        try write("src/a.c", "a")
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFile(didChange: false))
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(connection.daemonRequests, [.contentRoots(path: "src"), .beginBatch, .pushFolder(path: "src"),
                                                   .pushFile(path: "src/a.c", mode: 0o644), .endBatch])
        XCTAssertEqual(context.messages, ["Push folder: src", "Push file: src/a.c [no change]"])
    }

    /// Several files are one request, their bytes one after another in its body, and each
    /// is reported from its own outcome, in the order the push listed them.
    func test_severalFilesGoInOneRequestWithTheirBytesInTurn() throws {
        try write("src/a.c", "a")
        try write("src/b.c", "bb")
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFiles(outcomes: [.stored(didChange: true), .stored(didChange: false)]))
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(connection.daemonRequests, [.contentRoots(path: "src"), .beginBatch, .pushFolder(path: "src"),
                                                   .pushFiles(files: [PushedFileHeader(path: "src/a.c", mode: 0o644, length: 1),
                                                                      PushedFileHeader(path: "src/b.c", mode: 0o644, length: 2)]),
                                                   .endBatch])
        XCTAssertEqual(connection.requests[3].body, Data("abb".utf8))
        XCTAssertEqual(context.messages, ["Push folder: src", "Push file: src/a.c", "Push file: src/b.c [no change]"])
    }

    /// A file deleted between the listing and the read is reported in its place among the
    /// others, and the files around it are sent together.
    func test_aFileThatCannotBeReadIsReportedAndTheRestGoTogether() throws {
        try write("src/a.c", "a")
        try write("src/b.c", "b")
        try write("src/c.c", "c")
        connection.reply(.ok)
        connection.reply(.pushFiles(outcomes: [.stored(didChange: true), .stored(didChange: true)]))
        connection.reply(.ok)
        let unreadable = externalRoot.appendingPathComponent("src/b.c").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable)
        defer { chmod(unreadable, 0o644) }

        try run("push", ["src/*.c"])

        XCTAssertEqual(connection.daemonRequests, [.beginBatch,
                                                   .pushFiles(files: [PushedFileHeader(path: "src/a.c", mode: 0o644, length: 1),
                                                                      PushedFileHeader(path: "src/c.c", mode: 0o644, length: 1)]),
                                                   .endBatch])
        XCTAssertEqual(context.messages, ["Push file: src/a.c", "Push file: src/c.c"])
        XCTAssertEqual(context.errors.count, 1)
        XCTAssertTrue(context.errors.first?.hasPrefix("push: src/b.c: ") == true, "\(context.errors)")
    }

    /// B-130. A file the server could not store is named with the server's reason, and the
    /// push goes on to the files after it, as it does for a file it cannot read.
    func test_aFileTheServerRefusesIsReportedAndThePushGoesOn() throws {
        try write("src/a.c", "a")
        try write("src/b.c", "b")
        try write("src/c.c", "c")
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFiles(outcomes: [.stored(didChange: true),
                                               .failed(error: .nodeError(description: "the node it wakes cannot be made")),
                                               .stored(didChange: true)]))
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(connection.daemonRequests.last, .endBatch)
        XCTAssertEqual(context.messages, ["Push folder: src", "Push file: src/a.c", "Push file: src/c.c"])
        XCTAssertEqual(context.errors, ["push: src/b.c: the node it wakes cannot be made"])
    }

    /// A failure that is the server's, not the file's, stops the push: no later file would
    /// fare better, and each would say so.
    func test_aServerThatStoppedStopsThePush() throws {
        try write("src/a.c", "a")
        try write("src/b.c", "b")
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        connection.responses.append((.error(.unrecoverable(message: "the disk is full")), nil))

        XCTAssertThrowsError(try run("push", ["src"]))

        XCTAssertFalse(connection.daemonRequests.contains(.pushFile(path: "src/b.c", mode: 0o644)))
    }

    /// B-77. A link inside its folder is pushed as one: to a file with the file's bytes and
    /// mode, to a folder by itself, what it names pushed below it as always. A link out of
    /// its folder is a file like any other.
    func test_aLinkInsideItsFolderIsPushedAsOne() throws {
        try write("fw/Versions/A/Tiny", "binary")
        chmod(externalRoot.appendingPathComponent("fw/Versions/A/Tiny").path, 0o755)
        try write("outside.h", "outside")
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: externalRoot.appendingPathComponent("fw/Versions/Current").path, withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: externalRoot.appendingPathComponent("fw/Tiny").path, withDestinationPath: "Versions/Current/Tiny")
        try fileManager.createSymbolicLink(atPath: externalRoot.appendingPathComponent("fw/Outside.h").path, withDestinationPath: "../outside.h")
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        for _ in 0..<3 {
            connection.reply(.pushFile(didChange: true))
        }
        connection.reply(.pushFiles(outcomes: [.stored(didChange: true), .stored(didChange: true)]))
        connection.reply(.ok)

        try run("push", ["fw"])

        XCTAssertEqual(connection.daemonRequests, [
            .contentRoots(path: "fw"),
            .beginBatch, .pushFolder(path: "fw"),
            .pushFile(path: "fw/Outside.h", mode: 0o644),
            .pushSymbolicLink(path: "fw/Tiny", target: "Versions/Current/Tiny", referent: .file(mode: 0o755)),
            .pushSymbolicLink(path: "fw/Versions/Current", target: "A", referent: .folder),
            .pushFiles(files: [PushedFileHeader(path: "fw/Versions/A/Tiny", mode: 0o755, length: 6),
                               PushedFileHeader(path: "fw/Versions/Current/Tiny", mode: 0o755, length: 6)]),
            .endBatch,
        ])
        XCTAssertEqual(connection.requests[3].body, Data("outside".utf8))
        XCTAssertEqual(connection.requests[4].body, Data("binary".utf8), "a link to a file carries what it names")
        XCTAssertTrue(context.messages.contains("Push link: fw/Versions/Current -> A"), "\(context.messages)")
    }

    /// B-77. What the export writes for a link is the link, replacing whatever an earlier
    /// export left there without following it.
    func test_cpWritesALinkAsALink() throws {
        let destination = (externalRoot.path as NSString).resolvingSymlinksInPath
        try FileManager.default.createDirectory(atPath: destination + "/Current", withIntermediateDirectories: true)
        connection.reply(.list(entries: [ListEntry(path: "fw/Versions/Current", kind: .file, size: 0, mode: 0o644, status: .none)]))
        connection.reply(.symbolicLink(target: "A"))

        try run("cp", ["-o", "fw/Versions/Current", externalRoot.path])

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination + "/Current"), "A")
        XCTAssertEqual(context.messages, ["Link written: \(destination)/Current -> A"])
    }

    /// Past the point where a wall of paths is worth reading, the push reports a count
    /// instead — and still says how much of it was already there.
    func test_aLongPushReportsACountRatherThanEveryPath() throws {
        for index in 0..<21 {
            try write("src/file\(index).c", "\(index)")
        }
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFiles(outcomes: (0..<21).map { .stored(didChange: $0 > 1) }))
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(context.messages, ["Pushed 21 files and 1 folder, 2 unchanged"])
    }

    /// Three batches' worth of files under one folder, answered only when collected: the
    /// folder and the batches after it, and the push's `endBatch`, scripted in that order
    /// behind the roots and the `beginBatch`.
    private func scriptThreeBatchesInFlight(secondBatch: [PushedFileOutcome]) throws {
        for index in 0..<(3 * FilePlugin.filesPerRequest) {
            try write("src/file\(String(format: "%03d", index)).c", "\(index)")
        }
        connection.answersWhenCollected = true
        try replyHoldingNothing()
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFiles(outcomes: Array(repeating: .stored(didChange: true), count: FilePlugin.filesPerRequest)))
        connection.reply(.pushFiles(outcomes: secondBatch))
        connection.reply(.pushFiles(outcomes: Array(repeating: .stored(didChange: true), count: FilePlugin.filesPerRequest)))
        connection.reply(.ok)
    }

    private var sentBatches: [[PushedFileHeader]] {
        connection.daemonRequests.compactMap { request in
            guard case .pushFiles(let files) = request else {
                return nil
            }
            return files
        }
    }

    /// A batch leaves while the one before it is still being answered, up to
    /// `batchesInFlight`, and a file the server refuses in a batch that is no longer the
    /// newest is still reported against its own path.
    func test_batchesLeaveAheadOfTheirRepliesAndARefusalIsReportedAgainstItsFile() throws {
        var secondBatch = Array(repeating: PushedFileOutcome.stored(didChange: true), count: FilePlugin.filesPerRequest)
        secondBatch[9] = .failed(error: .nodeError(description: "the node it wakes cannot be made"))
        try scriptThreeBatchesInFlight(secondBatch: secondBatch)

        try run("push", ["src"])

        XCTAssertEqual(connection.mostOutstanding, FilePlugin.batchesInFlight)
        XCTAssertEqual(connection.outstanding, 0, "every reply collected before the push ends")
        XCTAssertEqual(connection.daemonRequests.last, .endBatch)
        XCTAssertEqual(sentBatches.count, 3)
        let refused = try XCTUnwrap(sentBatches.dropFirst().first?[9].path)
        XCTAssertEqual(context.errors, ["push: \(refused): the node it wakes cannot be made"])
        XCTAssertEqual(context.messages, ["Pushed \(3 * FilePlugin.filesPerRequest - 1) files and 1 folder"])
    }

    /// A failure that is the server's stops the push at the batch it came in, and the
    /// batches already sent behind it are waited out before the batch is ended, so no
    /// reply of the push is still to come when the next command's requests go out.
    func test_aServerThatStoppedMidPushWaitsOutTheBatchesAlreadySent() throws {
        try scriptThreeBatchesInFlight(secondBatch: Array(repeating: .failed(error: .unrecoverable(message: "the disk is full")),
                                                          count: FilePlugin.filesPerRequest))

        XCTAssertThrowsError(try run("push", ["src"])) { error in
            XCTAssertEqual((error as? ServerError)?.description, "the server stopped: the disk is full")
        }

        XCTAssertEqual(connection.outstanding, 0)
        XCTAssertEqual(connection.daemonRequests.last, .endBatch)
    }

    func test_pushOfAnAbsolutePathIsRefusedWithoutSendingAnything() throws {
        try run("push", ["/etc/hosts"])

        XCTAssertTrue(connection.requests.isEmpty)
        XCTAssertEqual(context.errors, ["push: /etc/hosts: only paths under \(externalRoot.path) can be pushed"])
    }

    func test_pushOfNothingIsAnError() throws {
        try run("push", ["nope.c"])

        XCTAssertTrue(connection.requests.isEmpty)
        XCTAssertEqual(context.errors, ["push: nope.c: no such file or directory"])
    }

    // MARK: - rm

    func test_rmSendsThePatternRelativeToTheCurrentDirectoryInsideOneBatch() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: ["src/a.c"], removedFolders: []))
        connection.reply(.ok)

        try run("rm", ["a.c"])

        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .remove(pattern: "src/a.c"), .endBatch])
        XCTAssertEqual(context.messages, ["Removed file: src/a.c"])
    }

    func test_rmNamesWhatItRemoved() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: ["src/a.c"], removedFolders: ["src"]))
        connection.reply(.ok)

        try run("rm", ["src"])

        XCTAssertEqual(context.messages, ["Removed folder: src", "Removed file: src/a.c"])
    }

    /// A long removal is a count, with the folders still named: they are what the user
    /// meant, and the files are what would fill the screen.
    func test_aLongRmReportsACountAndNamesTheFolders() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: (0..<30).map { "pkg/file\($0).c" },
                                 removedFolders: ["pkg", "pkg/sub"]))
        connection.reply(.ok)

        try run("rm", ["pkg"])

        XCTAssertEqual(context.messages, ["Removed 30 files and 2 folders: pkg, pkg/sub"])
    }

    /// `*` matches within one segment, so `*.*` takes the dotted files and leaves the
    /// folders. Naming what went is what says so: files, and no folder.
    func test_aWildcardThatTookNoFolderNamesOnlyFiles() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: ["a.c", "b.c"], removedFolders: []))
        connection.reply(.ok)

        try run("rm", ["*.*"])

        XCTAssertEqual(context.messages, ["Removed file: a.c", "Removed file: b.c"])
    }

    /// The folder list is capped like the file list: a pattern can match folders by the
    /// hundred, and the count exists to keep them off the screen.
    func test_aLongRmCapsTheFolderListItNames() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: [], removedFolders: (0..<25).map { "pkg\($0)" }))
        connection.reply(.ok)

        try run("rm", ["pkg*"])

        XCTAssertEqual(context.messages, ["Removed 25 folders: "
                                          + (0..<20).map { "pkg\($0)" }.joined(separator: ", ")
                                          + ", and 5 more"])
    }

    /// A removal whose reply streams (B-137) says how far it has got at each part, then
    /// reports the whole as one removal would: the count, and the folders named across
    /// every part, up to the cap.
    func test_aStreamedRmSaysHowFarItHasGotAndReportsTheWhole() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: (20..<30).map { "pkg/file\($0).c" }, removedFolders: ["pkg"]),
                         afterParts: [.remove(removedFiles: (0..<10).map { "pkg/file\($0).c" }, removedFolders: []),
                                      .remove(removedFiles: (10..<20).map { "pkg/file\($0).c" },
                                              removedFolders: (0..<25).map { "pkg/sub\($0)" })])
        connection.reply(.ok)

        try run("rm", ["pkg"])

        XCTAssertEqual(context.errors, [])
        XCTAssertEqual(context.messages, ["Removing: 10 files so far",
                                          "Removing: 20 files and 25 folders so far",
                                          "Removed 30 files and 26 folders: "
                                          + (0..<20).map { "pkg/sub\($0)" }.joined(separator: ", ")
                                          + ", and 6 more"])
    }

    /// A streamed reply whose last slice is empty still took what its parts named.
    func test_aStreamedRmEndingInAnEmptySliceIsNotANoOp() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: [], removedFolders: []),
                         afterParts: [.remove(removedFiles: ["a.c"], removedFolders: [])])
        connection.reply(.ok)

        try run("rm", ["a.c"])

        XCTAssertEqual(context.errors, [])
        XCTAssertEqual(context.messages, ["Removing: 1 file so far", "Removed file: a.c"])
    }

    func test_rmOfNothingIsAnError() throws {
        connection.reply(.ok)
        connection.reply(.remove(removedFiles: [], removedFolders: []))
        connection.reply(.ok)

        try run("rm", ["nope"])

        XCTAssertEqual(context.errors, ["rm: nope: no such file or directory"])
        XCTAssertTrue(context.messages.isEmpty)
    }

    // MARK: - cp

    func test_cpListsThenFetchesEachFileAndWritesIt() throws {
        connection.reply(.list(entries: [
            ListEntry(path: "src/a.c", kind: .file, size: 1, mode: 0o644, status: .none),
            ListEntry(path: "src",     kind: .folder, size: nil, mode: nil, status: .none),
        ]))
        connection.reply(.fetch(mode: 0o755), body: Data("hello".utf8))

        try run("cp", ["src/*", externalRoot.path])

        XCTAssertEqual(connection.daemonRequests, [
            .list(fileSystem: .input, pattern: "src/*"),
            .fetch(fileSystem: .input, path: "src/a.c"),
        ])
        // The destination goes through ExternalPathSanitizer, which resolves symlinks, and
        // the temporary directory is one on macOS (/var → /private/var).
        let destination = (externalRoot.path as NSString).resolvingSymlinksInPath
        let written     = destination + "/a.c"
        XCTAssertEqual(try String(contentsOfFile: written), "hello")
        let permissions = try FileManager.default.attributesOfItem(atPath: written)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        XCTAssertEqual(context.messages, ["File written: \(written)"])
    }

    func test_cpFromTheOutputFileSystemIsRootRelative() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.list(entries: []))

        try run("cp", ["-o", "app", externalRoot.path])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .output, pattern: "app")])
        XCTAssertEqual(context.errors, ["cp: app: no such file or directory"])
    }
}
