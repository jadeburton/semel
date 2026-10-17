//
//  RunningNodeNamesTests.swift
//  SemelCLITests
//
//  B-168. What the server's `progress` events name each running node by, over a real engine
//  and the real toolchain types: a compile by its module, a compiler by its source, a linker
//  by the product it is published as. Here because this is the one target that sees the
//  server, the engine and the toolchains at once. No tool runs: none of the nodes is given
//  a tool to run, so each fails on its settings after it has started, and a node is named
//  as it starts.
//

@testable import SemelCore
@testable import SemelServer
import Foundation
import SemelClang
import SemelNodeKit
import SemelProtocol
import SemelSwift
import XCTest

final class RunningNodeNamesTests: XCTestCase {

    /// Every running node the server's `progress` events carried. Delivered from the
    /// engine's loop and read from the test's thread, so it has a lock of its own.
    private final class RunningNodeSink: EventSink {
        private let lock = NSLock()
        private var storage: [ActiveNode] = []

        func deliver(_ event: Event) {
            guard case .daemon(.progress(let record)) = event else {
                return
            }
            lock.withLock { storage += record.running }
        }

        var running: [ActiveNode] {
            lock.withLock { storage }
        }
    }

    private var engine: BuildEngine!
    private var handler: RequestHandler!
    private let sink = RunningNodeSink()

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true))
        try SemelSwift.register()
        try SemelClang.register()
        let database = try DatabaseLayer()
        engine  = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite",
                                 engineConfigurationFile: URL(fileURLWithPath: "/tmp/test-semel.engine.config"))
        handler.eventSink = sink
        engine.startProcessingLoop()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        BuildEngine.shared = nil
        handler = nil
        engine  = nil
        super.tearDown()
    }

    /// A pushed file below `input:`, as a push leaves it.
    private func pushFile(_ relativePath: String, contents: String) throws {
        let folder = try XCTUnwrap(Path(relativePath).deletingLastComponent)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(folder, pinned: true)
        let (file, _) = try GraphSpecNode.staticFile(at: "input:/\(relativePath)").findOrCreateMatchingNode()
        _ = try XCTUnwrap(file.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
    }

    /// The nodes of `formulas` built in one batch and settled.
    private func settle(_ formulas: [String]) throws {
        engine.beginBatch()
        for formula in formulas {
            _ = try GraphSpecNode.parse(formula).findOrCreateMatchingNode()
        }
        engine.signalWorkAvailable()
        engine.endBatch()
        engine.waitUntilIdleBlocking()
    }

    private func running(_ type: String) -> [ActiveNode] {
        sink.running.filter { $0.type == type }
    }

    func test_aSwiftCompilerIsNamedByItsModule() throws {
        try settle(["SwiftCompiler(configuration: ['settings': SettingsLiteral(moduleName: 'Models').output]).object"])

        let compiler = try XCTUnwrap(running("SwiftCompiler").first, "the compiler started: \(sink.running)")
        XCTAssertEqual(compiler.subject, .target(name: "Models"))
        XCTAssertFalse(compiler.identity.isEmpty, "a node made from a spec has an identity")
    }

    func test_aClangCompilerIsNamedByItsSource() throws {
        try pushFile("proj/src/main.c", contents: "int main(void) { return 0; }")

        try settle(["""
            ClangCompiler(configuration: ['settings': SettingsLiteral(role: 'compile').output],
                          input: ['input:/proj/src/main.c.p': StaticFile(path: 'input:/proj/src/main.c').output]).output
            """])

        let compiler = try XCTUnwrap(running("ClangCompiler").first, "the compiler started: \(sink.running)")
        XCTAssertEqual(compiler.subject, .source(path: "input:/proj/src/main.c"))
    }

    /// A linker names nothing of its own; it is named by the product an `OutputFile` takes it
    /// as. Two linkers of one set of objects, one per product, are two names.
    func test_aLinkerIsNamedByTheProductItIsPublishedAs() throws {
        try pushFile("proj/obj/main.o", contents: "object")
        let linker = { (dynamicLibrary: String) in
            "ClangLinker(configuration: ['settings': SettingsLiteral(dynamicLibrary: '\(dynamicLibrary)').output], "
                + "objectFiles: ['main.o': StaticFile(path: 'input:/proj/obj/main.o').output]).output"
        }

        try settle(["OutputFile(path: 'output:/proj/hello', input: ['product': \(linker("false"))]).status",
                    "OutputFile(path: 'output:/proj/hello.dylib', input: ['product': \(linker("true"))]).status"])

        XCTAssertEqual(Set(running("ClangLinker").map(\.subject)),
                       [.product(path: "output:/proj/hello"), .product(path: "output:/proj/hello.dylib")])
    }

    /// Two compiles of one module under two configurations: one subject, two identities.
    func test_twoCompilesOfOneModuleHaveOneSubjectAndTwoIdentities() throws {
        try settle(["SwiftCompiler(configuration: ['settings': SettingsLiteral(moduleName: 'Models', sdk: 'macosx').output]).object",
                    "SwiftCompiler(configuration: ['settings': SettingsLiteral(moduleName: 'Models', sdk: 'iphonesimulator').output]).object"])

        let compilers = running("SwiftCompiler")
        XCTAssertEqual(Set(compilers.map(\.subject)), [.target(name: "Models")])
        XCTAssertEqual(Set(compilers.map(\.identity)).count, 2)
    }
}
