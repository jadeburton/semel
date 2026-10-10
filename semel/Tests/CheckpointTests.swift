//
//  CheckpointTests.swift
//  SemelCLITests
//
//  B-146. `checkpoint` names the tree `input:` holds by its content root, `checkpoints`
//  lists them by name, and `restore` brings a tree back in one batch through the lock
//  barrier — files, links, modes, folders the checkpoint lacks removed — and the settle it
//  causes is answered from the cache. Driven through the interpreter over a live engine,
//  so what is asserted is what a person types and reads.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class CheckpointTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!
    private let lines = CheckpointLineLog()

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        try TypeRegistry.register(types: [CountingLineCounter.self])
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        interpreter = CommandInterpreter(connection: InProcessConnection(handler: handler), baseDirectory: externalRoot.path)
        _ = try interpreter.connect()
        interpreter.output = { [lines] in lines.append($0) }
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
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

    private func url(_ relativePath: String) -> URL {
        externalRoot.appendingPathComponent(relativePath)
    }

    private func write(_ text: String, to relativePath: String, mode: Int16 = 0o644) throws {
        let file = url(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    private func link(_ relativePath: String, to target: String) throws {
        try? FileManager.default.removeItem(at: url(relativePath))
        try FileManager.default.createSymbolicLink(atPath: url(relativePath).path, withDestinationPath: target)
    }

    /// Runs one command and returns what it printed; fails the test when it failed.
    @discardableResult
    private func run(_ command: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let before = lines.all.count
        let result = interpreter.handleCommand(command)
        let printed = Array(lines.all.dropFirst(before))
        XCTAssertEqual(result, .success, "\(command): \(printed.joined(separator: "\n"))", file: file, line: line)
        return printed
    }

    /// The hash `checkpoint` printed; with no name, the one it records as `latest`.
    private func checkpoint(_ name: String?) throws -> String {
        let printed = run(name.map { "checkpoint \($0)" } ?? "checkpoint")
        let prefix  = "Checkpoint \(name ?? "latest"): sha256:"
        let line    = try XCTUnwrap(printed.first { $0.hasPrefix(prefix) }, "\(printed)")
        return String(line.dropFirst(prefix.count))
    }

    private func held(_ path: String) throws -> String? {
        guard let node = try BuildEngine.shared.inputFileSystem.childNode(path: Path(path)),
              let file = try node.nodeAsAny() as? StaticFile,
              case .value(let hash)? = try file.read() else {
            return nil
        }
        return try hash.resolveAsString()
    }

    private func metadata(_ path: String) throws -> FileMetadata? {
        let node = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: Path(path)))
        return try XCTUnwrap(try node.nodeAsAny() as? StaticFile).readFileMetadata()
    }

    // MARK: - Round trips

    func test_aRestoreRoundTripsFilesAddedRemovedRelinkedAndReModed() throws {
        try write("print(1)\n", to: "app/main.swift")
        try write("echo\n", to: "app/run.sh", mode: 0o755)
        try write("struct Lib {}\n", to: "app/lib/Lib.swift")
        try write("a\n", to: "app/a.txt")
        try write("b\n", to: "app/b.txt")
        try link("app/current.txt", to: "a.txt")
        run("push app")
        let before = try checkpoint("before")

        try write("print(2)\n", to: "app/main.swift")
        try write("echo\n", to: "app/run.sh", mode: 0o644)
        try write("new\n", to: "app/added/New.swift")
        try link("app/current.txt", to: "b.txt")
        run("push app")
        run("rm app/lib")
        XCTAssertNotEqual(try checkpoint("after"), before)

        let printed = run("restore before")
        XCTAssertTrue(printed.contains { $0.hasPrefix("Restored input: to checkpoint before (sha256:\(before)):") },
                      "\(printed)")
        XCTAssertEqual(try checkpoint("again"), before, "input: holds the checkpoint's tree")
        XCTAssertEqual(try held("app/main.swift"), "print(1)\n")
        XCTAssertEqual(try metadata("app/run.sh")?.mode, 0o755)
        XCTAssertEqual(try metadata("app/current.txt")?.symbolicLinkTarget, "a.txt")
        XCTAssertEqual(try held("app/lib/Lib.swift"), "struct Lib {}\n")
        XCTAssertNil(try held("app/added/New.swift"))
    }

    func test_checkpointsListsEveryNameWithItsRootAndAPlainCheckpointIsLatest() throws {
        try write("print(1)\n", to: "app/main.swift")
        run("push app")
        let latest = try checkpoint(nil)
        _ = try checkpoint("zeta")
        XCTAssertEqual(run("checkpoints"), ["latest  sha256:\(latest)", "zeta    sha256:\(latest)"],
                       "two checkpoints of one tree are one root, listed by name")
    }

    func test_restoringAnUnknownNameSaysWhichNamesThereAre() throws {
        _ = try checkpoint("one")
        XCTAssertEqual(interpreter.handleCommand("restore two"), .failed)
        XCTAssertTrue(lines.all.contains { $0.contains("there is no checkpoint named 'two'; there are one") }, "\(lines.all)")
    }

    // MARK: - Through the barrier

    func test_aRestoreAcrossALockChangeCarriesTheLock() throws {
        try write("public struct Pkg {}\n", to: "app/Dependencies/Pkg/Pkg.swift")
        try writeLock()
        run("push app")
        let vendored = try checkpoint("vendored")

        try write("public struct Pkg { let version = 2 }\n", to: "app/Dependencies/Pkg/Pkg.swift")
        try writeLock()
        run("push app")

        run("restore vendored")
        XCTAssertEqual(try checkpoint("now"), vendored)
        XCTAssertEqual(try held("app/Dependencies/Pkg/Pkg.swift"), "public struct Pkg {}\n")
    }

    func test_aPushThatMovesALockedFolderWithoutItsLockFailsAndSaysWhy() throws {
        try write("public struct Pkg {}\n", to: "app/Dependencies/Pkg/Pkg.swift")
        try writeLock()
        run("push app")

        try write("public struct Pkg { let edited = true }\n", to: "app/Dependencies/Pkg/Pkg.swift")
        XCTAssertEqual(interpreter.handleCommand("push app"), .failed)
        let report = lines.all.joined(separator: "\n")
        XCTAssertTrue(report.contains("app/Dependencies/Pkg is locked, and the batch changes it without a lock it matches"),
                      report)
        XCTAssertTrue(report.contains("  lock: app/Dependencies/Pkg.semel-lock"), report)
        XCTAssertTrue(report.contains("  paths: app/Dependencies/Pkg/Pkg.swift"), report)
        XCTAssertEqual(try held("app/Dependencies/Pkg/Pkg.swift"), "public struct Pkg {}\n")
        XCTAssertEqual(interpreter.batchesRefused, 1)
    }

    private func writeLock() throws {
        let root = try FolderContentRoot.root(ofFolderAt: url("app/Dependencies/Pkg"))
        try write(DependencyLock(contentRoot: root, fold: FolderContentRoot.formatTag).text,
                  to: "app/Dependencies/Pkg.semel-lock")
    }

    // MARK: - The cache

    /// The nodes that cache are answered from the cache: the counter, whose restored file is
    /// the value its entry was keyed on, and the project builder reading the formula. The
    /// product's own `OutputFile`, which stores no entry, runs again, as it does on every
    /// settle that reaches it; the project finder only holds the builder and is not woken
    /// by what the builder publishes (B-149).
    func test_aRestoreIsAnsweredFromTheCache() throws {
        try write(#"product "lines.txt" = CountingLineCounter(input: ["main.c": StaticFile(path: <main.c>)])"#,
                  to: "src/semel.fmla")
        try write("int main(void) {\n    return 0;\n}\n", to: "src/main.c")
        run("build src")
        _ = try checkpoint("first")

        try write("int main(void) { return 1; }\n", to: "src/main.c")
        run("build src")
        let processedBefore = CountingLineCounter.processed.value

        let printed = run("restore first")
        let settled = try XCTUnwrap(printed.first { $0.contains("scheduled") }, "\(printed)")
        XCTAssertTrue(settled.contains(" 1 computed, 2 from cache"), settled)
        XCTAssertEqual(CountingLineCounter.processed.value, processedBefore, "the counter did not run")
    }
}

/// `LineCounter`, counting its runs, so a test can tell a hit from a run.
struct CountingLineCounter: Node {
    static let kind: UInt = 987_140

    static let inputPort  = "input"
    static let outputPort = "output"

    static let processed = SharedCounter()

    var thisNode: NodeRecord

    init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    static let descriptor = NodeDescriptor(inputPorts: [.required(inputPort, .many)], outputPorts: [outputPort])

    func process(input: ProcessInput) throws -> ProcessOutput {
        Self.processed.increment()
        let wires = (input.inputValues[Self.inputPort] ?? [:]).sorted { $0.key < $1.key }
        let lines = try wires.map { "\($0.key): \(try $0.value.expectValue().resolveAsString().split(separator: "\n").count)" }
        return .init(outputValues: [Self.outputPort: .value(try lines.joined(separator: "\n").intern())],
                     inputWireSpecs: [:])
    }
}

/// The interpreter's output, collected from whatever thread prints it.
private final class CheckpointLineLog {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var all: [String] {
        lock.withLock { storage }
    }
}
