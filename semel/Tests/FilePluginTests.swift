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
        XCTAssertEqual(context.messages, ["Push file: a.c "])
    }

    func test_pushOfAFolderSendsTheFolderThenItsFiles() throws {
        try write("src/a.c", "a")
        connection.reply(.ok)
        connection.reply(.ok)
        connection.reply(.pushFile(didChange: false))
        connection.reply(.ok)

        try run("push", ["src"])

        XCTAssertEqual(connection.daemonRequests, [.beginBatch, .pushFolder(path: "src"),
                                                   .pushFile(path: "src/a.c", mode: 0o644), .endBatch])
        XCTAssertEqual(context.messages, ["Push folder: src", "Push file: src/a.c [no change]"])
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

    func test_rmSendsThePatternRelativeToTheCurrentDirectory() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.remove(removedPaths: ["src/a.c"]))

        try run("rm", ["*.c"])

        XCTAssertEqual(connection.daemonRequests, [.remove(pattern: "src/*.c")])
        XCTAssertTrue(context.allOutput.isEmpty)
    }

    func test_rmOfNothingIsAnError() throws {
        connection.reply(.remove(removedPaths: []))

        try run("rm", ["nope"])

        XCTAssertEqual(context.errors, ["rm: nope: no such file or directory"])
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
