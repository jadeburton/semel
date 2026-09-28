//
//  PackageDependencyFollowTests.swift
//  SemelCLITests
//
//  B-110 residual 1. `build` follows what a settle reports as not pushed; for a package
//  dependency outside the built folder, what the converter's stall names has to be the
//  package's folder, typed, or the build follows what the converter happened to wire —
//  the manifest, then each target folder — one settle each. These run the real
//  converter and reader over a live loop, the reader's tool faked to hand back the
//  manifest's own text as its dump.
//

@testable import SemelCLI
@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class PackageDependencyFollowTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var connection: WaitCountingConnection!
    private var externalRoot: URL!

    /// What the fake reader's tool answers to: the descriptor the config file names.
    private let readerDescriptor = ToolDescriptor(name: "swift", version: "test-swift",
                                                  platform: "macOS", architecture: "arm64", recursiveHash: nil)

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try writeTree()

        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        try SemelSwift.register()
        ToolRunnerRegistry.instance.registerTool(descriptor: readerDescriptor, toolExecutor: ManifestEchoTool())
        // Installed and registered first: the loop's first pass reads all of it.
        engine.startProcessingLoop()

        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection  = WaitCountingConnection(wrapping: InProcessConnection(handler: handler))
        interpreter = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        BuildEngine.shared = nil
        interpreter = nil
        connection = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = externalRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `Packages/` holds the formula, its config and the package it includes; the package
    /// depends on `Helper`, beside `Packages` rather than under it, so `build Packages`
    /// pushes everything but the dependency. Each `Package.swift` holds the JSON its dump
    /// would print, which is what the fake tool hands back. No products: the formula the
    /// converter writes is empty, so nothing past the conversion needs a real toolchain.
    private func writeTree() throws {
        try write("include SwiftFormulaConverter(path: <App>, root: <.>).formula", to: "Packages/semel.fmla")
        try write("// the project's choices", to: "Packages/semel.config")
        try write("""
            swift.packageReader.toolDescriptor.name=swift
            swift.packageReader.toolDescriptor.version=test-swift
            swift.packageReader.toolDescriptor.platform=macOS
            swift.packageReader.toolDescriptor.architecture=arm64
            """, to: "Packages/semel.machine.config")
        try write("""
            {
              "name": "App",
              "dependencies": [{"fileSystem": [{"identity": "helper", "path": "../../Helper"}]}],
              "products": [],
              "targets": [{"name": "App", "type": "regular", "path": "Sources/App",
                           "dependencies": [{"product": ["Helper", "helper", null, null]}]}]
            }
            """, to: "Packages/App/Package.swift")
        try write("public struct App {}", to: "Packages/App/Sources/App/App.swift")
        try write("""
            {
              "name": "Helper",
              "dependencies": [],
              "products": [{"name": "Helper", "targets": ["Helper"], "type": {"library": ["automatic"]}}],
              "targets": [{"name": "Helper", "type": "regular", "path": "Sources/Helper", "dependencies": []}]
            }
            """, to: "Helper/Package.swift")
        try write("public struct Helper {}", to: "Helper/Sources/Helper/Helper.swift")
        // Two manifests nothing reads: a package the formula forgot, and a checkout
        // vendored under the root's Dependencies folder that no target uses.
        try write(#"{"name": "Forgotten", "dependencies": [], "products": [], "targets": []}"#,
                  to: "Packages/Forgotten/Package.swift")
        try write(#"{"name": "Unused", "dependencies": [], "products": [], "targets": []}"#,
                  to: "Packages/Dependencies/Unused/Package.swift")
    }

    /// What the interpreter printed. Notices arrive on the engine's task, the rest on the
    /// test's thread.
    private final class LineLog {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.withLock { storage.append(line) }
        }

        var all: [String] {
            lock.withLock { storage }
        }
    }

    /// The dependency's folder is what the stall names, so one round pushes the whole
    /// package: the settle after `push Packages`, then the one after `push Helper`.
    func test_aPackageDependencyOutsideTheBuiltFolderIsPushedInOneRound() throws {
        let lines = LineLog()
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build Packages")

        let transcript = lines.all.joined(separator: "\n")
        XCTAssertEqual(lines.all.filter { $0.contains(" needs ") }, ["Packages/semel.fmla needs ../Helper"], transcript)
        XCTAssertEqual(connection.waitCount, 2, "one wait for the build, one for the round that pushed Helper\n\(transcript)")
        XCTAssertEqual(interpreter.errorsReported, 0, transcript)
    }

    /// B-10 residual 2, over the real converter: the included package and the dependency
    /// it reaches are read, and so is nothing under Dependencies claimed; the package the
    /// formula forgot is the one line.
    func test_onlyThePackageNoFormulaNamesDrawsTheNotice() throws {
        let lines = LineLog()
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build Packages")
        engine.waitUntilIdleBlocking()

        XCTAssertEqual(lines.all.filter { $0.contains("is not named by any formula") },
                       ["⚠️  input:/Packages/Forgotten/Package.swift is not named by any formula; "
                        + "a formula's include SwiftFormulaConverter(path: <Forgotten>).formula builds it"],
                       lines.all.joined(separator: "\n"))
    }
}

// MARK: - Fakes

/// `swift package dump-package` for a manifest that is already its own dump: the one input
/// file's text, printed.
private struct ManifestEchoTool: ToolRunner {
    func execute(arguments: [String], environment: [String: String],
                 inputFiles: [FileNameAndContent], expectedOutputFileNames: [String],
                 expectedOutputFolders: [String], output: ToolOutput) throws -> ToolExecuteResult {
        for inputFile in inputFiles {
            output.logMessage(try inputFile.contentAsString)
        }
        return ToolExecuteResult(exitCode: 0, resolvedSandboxPath: "/tmp/manifest-echo-sandbox")
    }
}

/// The in-process connection, counting the `wait` requests a command sends: each is one
/// settle the client waited for.
private final class WaitCountingConnection: SemelConnection {
    private let inner: InProcessConnection
    private let lock = NSLock()
    private var waits = 0

    init(wrapping inner: InProcessConnection) {
        self.inner = inner
    }

    var waitCount: Int { lock.withLock { waits } }

    var onEvent: ((Event) -> Void)? {
        get { inner.onEvent }
        set { inner.onEvent = newValue }
    }

    func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        if case .daemon(.wait) = request {
            lock.withLock { waits += 1 }
        }
        return try inner.send(request, body: body)
    }
}
