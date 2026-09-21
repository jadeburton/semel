//
//  ToolsCommandTests.swift
//  SemelCLITests
//
//  `tools` prints the tools this machine can build with, in the form a config file needs:
//  one `toolDescriptor.*` block per namespace that names the tool, prefixed with that
//  namespace, so choosing a toolchain version is a copy rather than a transcription.
//

@testable import SemelCLI
@testable import SemelCore
import SemelClang
import SemelSwift
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class ToolsCommandTests: XCTestCase {

    private var connection: InProcessConnection!
    private var context: TestCommandContext!

    /// A runner that never runs. The command reads descriptors, not tools.
    private struct NoTool: ToolRunner {
        func execute(arguments: [String], environment: [String: String],
                     inputFiles: [FileNameAndContent], expectedOutputFileNames: [String],
                     expectedOutputFolders: [String], output: ToolOutput) throws -> ToolExecuteResult {
            ToolExecuteResult(exitCode: 0, resolvedSandboxPath: "")
        }
    }

    private let swiftcDescriptor = ToolDescriptor(name: "swiftc",
                                                  version: "Apple Swift version 9.9 (swiftlang-9.9.9.9.9 clang-9999.9.9.9)",
                                                  platform: "macOS", architecture: "arm64", recursiveHash: nil)
    private let clangDescriptor  = ToolDescriptor(name: "clang",
                                                  version: "Apple clang version 99.0.0",
                                                  platform: "macOS", architecture: "arm64", recursiveHash: nil)

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true))
        let database = try DatabaseLayer()
        BuildEngine.shared = try BuildEngine(database: database, startProcessingLoop: false)
        // After the engine: its constructor registers whatever real tools the toolchains
        // have declared, and these tests must see only the descriptors they register
        // themselves.
        ToolRunnerRegistry.instance = ToolRunnerRegistry()
        // The real registrations, so the namespaces printed are the ones the toolchains own.
        try SemelSwift.register()
        try SemelClang.register()
        let handler = RequestHandler(engine: BuildEngine.shared, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection  = InProcessConnection(handler: handler)
        context     = TestCommandContext(connection: connection, baseDirectory: NSTemporaryDirectory())
    }

    override func tearDown() {
        BuildEngine.shared = nil
        connection = nil
        context = nil
        super.tearDown()
    }

    private func runTools() throws -> String {
        try EnginePlugin().handle(verb: "tools", tokens: [], context: context)
        return context.messages.joined(separator: "\n")
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    func test_printsEveryNamespaceThatUsesARegisteredToolInConfigSyntax() throws {
        ToolRunnerRegistry.instance.registerTool(descriptor: swiftcDescriptor, toolExecutor: NoTool())
        ToolRunnerRegistry.instance.registerTool(descriptor: clangDescriptor,  toolExecutor: NoTool())

        let output = lines(try runTools())

        for namespace in ["swift.compiler", "swift.linker"] {
            XCTAssertTrue(output.contains("\(namespace).toolDescriptor.name=swiftc"), "got:\n\(output)")
            XCTAssertTrue(output.contains("\(namespace).toolDescriptor.version=\(swiftcDescriptor.version)"), "got:\n\(output)")
            XCTAssertTrue(output.contains("\(namespace).toolDescriptor.platform=macOS"), "got:\n\(output)")
            XCTAssertTrue(output.contains("\(namespace).toolDescriptor.architecture=arm64"), "got:\n\(output)")
        }
        for namespace in ["clang.compiler", "clang.linker", "clang.preprocessor"] {
            XCTAssertTrue(output.contains("\(namespace).toolDescriptor.name=clang"), "got:\n\(output)")
            XCTAssertTrue(output.contains("\(namespace).toolDescriptor.version=\(clangDescriptor.version)"), "got:\n\(output)")
        }
    }

    /// The SDK check (B-47) wants the machine's full SDK identity beside the Swift tools,
    /// and typing it by hand is the thing this command exists to spare.
    func test_printsTheMachineSDKIdentityForTheSwiftNamespacesThatCheckIt() throws {
        ToolRunnerRegistry.instance.registerTool(descriptor: swiftcDescriptor, toolExecutor: NoTool())

        let output = lines(try runTools())

        for namespace in ["swift.compiler", "swift.linker"] {
            let line = try XCTUnwrap(output.first { $0.hasPrefix("\(namespace).sdkVersion=") }, "got:\n\(output)")
            let value = String(line.dropFirst("\(namespace).sdkVersion=".count))
            XCTAssertTrue(value.contains("("), "expected `<version> (<build>)`, got \(line)")
        }
        XCTAssertFalse(output.contains { $0.hasPrefix("swift.packageReader.sdkVersion=") },
                       "the package reader declares no SDK, got:\n\(output)")
    }

    /// Dictionary-backed on both sides — the registry and the namespaces — so the order
    /// has to be imposed: namespaces alphabetical, and a tool with several installed
    /// versions listed by version.
    func test_ordersNamespacesAlphabetically() throws {
        ToolRunnerRegistry.instance.registerTool(descriptor: swiftcDescriptor, toolExecutor: NoTool())
        ToolRunnerRegistry.instance.registerTool(descriptor: clangDescriptor,  toolExecutor: NoTool())
        // The package reader runs `swift`, not `swiftc`; without it that namespace is a comment.
        ToolRunnerRegistry.instance.registerTool(
            descriptor: ToolDescriptor(name: "swift", version: swiftcDescriptor.version,
                                       platform: "macOS", architecture: "arm64", recursiveHash: nil),
            toolExecutor: NoTool())

        let output = lines(try runTools())
        let namespaceOrder = output.compactMap { line -> String? in
            guard line.contains(".toolDescriptor.name=") else { return nil }
            return String(line.prefix { $0 != "=" }.dropLast(".toolDescriptor.name".count))
        }

        XCTAssertEqual(namespaceOrder, namespaceOrder.sorted(), "got:\n\(output)")
        XCTAssertEqual(namespaceOrder.count, 6, "one block per namespace, got:\n\(output)")
    }

    /// A namespace whose tool is not installed still appears, as a comment: the user
    /// learns what is missing from the same place they learn what is there, and pasting
    /// the output whole stays harmless.
    func test_namesANamespaceWhoseToolIsNotInstalledAsAComment() throws {
        ToolRunnerRegistry.instance.registerTool(descriptor: swiftcDescriptor, toolExecutor: NoTool())

        let output = lines(try runTools())

        let note = try XCTUnwrap(output.first { $0.contains("clang.compiler") }, "got:\n\(output)")
        XCTAssertTrue(note.hasPrefix("//"), "a missing tool must not print as a setting, got: \(note)")
        XCTAssertTrue(note.contains("clang"), "should name the tool that is missing, got: \(note)")
        XCTAssertFalse(output.contains { $0.hasPrefix("clang.compiler.toolDescriptor") }, "got:\n\(output)")
    }
}
