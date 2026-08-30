//
//  FilePluginPathTests.swift
//  SemelCLITests
//
//  Regression cover for the push/cp path resolution defects. Each of these commands
//  used to match nothing and report nothing — the failure mode was silence, which is
//  why they went unnoticed.
//

@testable import SemelCLI
@testable import SemelCore
import XCTest
import SemelNodeKit

final class FilePluginPathTests: XCTestCase {

    private var context: TestCommandContext!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Never touch the user's real object store.
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())

        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

        let database = try DatabaseLayer()
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine

        context = TestCommandContext(database: database, baseDirectory: externalRoot.path)
    }

    override func tearDown() {
        BuildEngine.shared = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("build_system-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeExternalFile(_ relativePath: String, contents: String = "int main(){}\n") throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(_ command: String, _ tokens: [String]) throws {
        try FilePlugin().handle(verb: command, tokens: tokens, context: context)
    }

    // MARK: - push

    func test_push_storesAFileRelativeToTheCurrentDirectory() throws {
        try writeExternalFile("src/hello.c")
        context.currentDirectoryPath = Path("src")

        try run("push", ["hello.c"])

        XCTAssertNotNil(try context.inputFileSystem.childNode(path: Path("src/hello.c")),
                        "the file should be stored at input:/src/hello.c")
    }

    // Was silent: the cwd was prefixed onto the absolute path, so nothing matched.
    func test_push_rejectsAnAbsolutePathInsteadOfMatchingNothing() throws {
        try run("push", ["/tmp/somewhere-outside.c"])

        XCTAssertTrue(context.errors.contains { $0.contains("only paths under") },
                      "expected an explanation, got \(context.allOutput)")
    }

    // Was silent: an empty match set produced no output at all.
    func test_push_reportsWhenNothingMatches() throws {
        try run("push", ["no-such-file.c"])

        XCTAssertTrue(context.errors.contains { $0.contains("no such file or directory") },
                      "expected a not-found error, got \(context.allOutput)")
    }

    // The matcher lists a file, then pushOne reads it. Anything can happen in between —
    // and the read result was force-unwrapped, so a permission change or a deleted file
    // took the whole process down.
    func test_push_reportsAnUnreadableFileInsteadOfCrashing() throws {
        try writeExternalFile("secret.c")
        let url = externalRoot.appendingPathComponent("secret.c")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: url.path)
        }

        try run("push", ["secret.c"])

        XCTAssertTrue(context.errors.contains { $0.contains("secret.c") },
                      "expected an error naming the file, got \(context.allOutput)")
    }

    func test_push_resolvesDotDotAgainstTheCurrentDirectory() throws {
        try writeExternalFile("shared/util.c")
        context.currentDirectoryPath = Path("src")

        try run("push", ["../shared/util.c"])

        XCTAssertNotNil(try context.inputFileSystem.childNode(path: Path("shared/util.c")),
                        "'..' should resolve before matching")
    }

    // MARK: - cp

    // Was silent: the default destination resolved under baseDirectory/<internal cwd>,
    // a directory that need not exist, and the write error was swallowed by `try?`.
    func test_cp_defaultDestinationWritesToTheProcessWorkingDirectory() throws {
        try writeExternalFile("src/hello.c", contents: "contents-of-hello\n")
        context.currentDirectoryPath = Path("src")
        try run("push", ["hello.c"])

        // An internal directory with no external counterpart.
        try FileManager.default.removeItem(at: externalRoot.appendingPathComponent("src"))

        let workingDirectory = makeTempDirectory()
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(workingDirectory.path)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }

        try run("cp", ["hello.c"])

        let written = workingDirectory.appendingPathComponent("hello.c")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path),
                      "expected the copy in the working directory, got \(context.allOutput)")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "contents-of-hello\n")
    }

    // Was silent: an explicit -i/-o names a file system the cwd does not belong to, but
    // the cwd was prefixed anyway, so `src/src/hello.c` matched nothing.
    func test_cp_explicitFileSystemFlagIgnoresTheCurrentDirectory() throws {
        try writeExternalFile("src/hello.c")
        context.currentDirectoryPath = Path("src")
        try run("push", ["hello.c"])

        let destination = makeTempDirectory()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try run("cp", ["-i", "/src/hello.c", destination.path])

        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: destination.appendingPathComponent("hello.c").path),
                      "a root-relative source should resolve from any cwd, got \(context.allOutput)")
    }

    // Was silent: findAllMatching returned nothing and the forEach body never ran.
    func test_cp_reportsWhenNothingMatches() throws {
        try run("cp", ["no-such-file.c"])

        XCTAssertTrue(context.errors.contains { $0.contains("no such file or directory") },
                      "expected a not-found error, got \(context.allOutput)")
    }
}

// MARK: - Test context

/// A `CommandContext` that captures output instead of printing it, so a test can assert
/// on what the user would have been told.
final class TestCommandContext: CommandContext {

    let database: DatabaseLayer
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty

    private(set) var messages: [String] = []
    private(set) var errors: [String] = []

    var allOutput: [String] { messages + errors }

    init(database: DatabaseLayer, baseDirectory: String) {
        self.database = database
        self.baseDirectory = baseDirectory
    }

    var buildEngine: BuildEngine { BuildEngine.shared }
    var inputFileSystem: NodeRecord { get throws { try buildEngine.inputFileSystem } }
    var outputFileSystem: NodeRecord { get throws { try buildEngine.outputFileSystem } }

    func outputMessage(_ message: String) { messages.append(message) }
    func outputError(_ message: String)   { errors.append(message) }
}

// MARK: - Pushing a tree

/// A wildcard that reaches into subdirectories matches the directories *and* their contents.
/// Pushing a directory means pushing everything under it, so a file matched both ways must
/// still be pushed once — otherwise the second attempt reports "[no change]" against a file
/// nothing changed, and the report stops describing what happened.
final class PushTreeTests: XCTestCase {

    private var context: TestCommandContext!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let database = try DatabaseLayer()
        BuildEngine.shared = try BuildEngine(database: database, startProcessingLoop: false)
        context = TestCommandContext(database: database, baseDirectory: externalRoot.path)
    }

    override func tearDown() {
        BuildEngine.shared = nil
        context = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("build_system-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeExternalFile(_ relativePath: String) throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "int main(){}\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func pushLines(for path: String) -> [String] {
        context.messages.filter { $0.hasPrefix("Push file:") && $0.contains(path) }
    }

    func test_aFileMatchedBothDirectlyAndThroughItsFolderIsPushedOnce() throws {
        try writeExternalFile("c/hello.fmla")
        try writeExternalFile("c/src/main.c")
        try writeExternalFile("c/src/common.h")

        try FilePlugin().handle(verb: "push", tokens: ["c/**/*"], context: context)

        XCTAssertEqual(pushLines(for: "c/src/main.c").count, 1,
                       "got:\n\(context.messages.joined(separator: "\n"))")
        XCTAssertEqual(pushLines(for: "c/src/common.h").count, 1)
        XCTAssertEqual(pushLines(for: "c/hello.fmla").count, 1)
    }

    /// Nothing should report "[no change]" on a first push — every file is new.
    func test_aFirstPushReportsNoFileAsUnchanged() throws {
        try writeExternalFile("c/src/main.c")

        try FilePlugin().handle(verb: "push", tokens: ["c/**/*"], context: context)

        XCTAssertFalse(context.messages.contains { $0.contains("[no change]") },
                       "got:\n\(context.messages.joined(separator: "\n"))")
    }

    /// A bare directory has no wildcard enumerating its contents, so the recursion into it
    /// is what pushes them — removing it would silently create an empty folder.
    func test_pushingABareDirectoryStillPushesItsContents() throws {
        try writeExternalFile("c/src/main.c")

        try FilePlugin().handle(verb: "push", tokens: ["c"], context: context)

        XCTAssertNotNil(try context.inputFileSystem.childNode(path: Path("c/src/main.c")),
                        "got:\n\(context.messages.joined(separator: "\n"))")
    }

    /// A genuine second push is still reported as unchanged — the deduplication is within
    /// one command, not a memory across commands.
    func test_pushingTheSameTreeTwiceReportsNoChangeTheSecondTime() throws {
        try writeExternalFile("c/src/main.c")
        try FilePlugin().handle(verb: "push", tokens: ["c/**/*"], context: context)

        try FilePlugin().handle(verb: "push", tokens: ["c/**/*"], context: context)

        XCTAssertTrue(context.messages.contains { $0.contains("main.c") && $0.contains("[no change]") },
                      "got:\n\(context.messages.joined(separator: "\n"))")
    }
}
