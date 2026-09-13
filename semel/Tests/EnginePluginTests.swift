//
//  EnginePluginTests.swift
//  SemelCLITests
//
//  errors, reset, nudge, debug and tools over a scripted connection: what each sends and
//  how it renders what comes back.
//

@testable import SemelCLI
import SemelProtocol
import XCTest

final class EnginePluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
    }

    private func run(_ verb: String) throws {
        try EnginePlugin().handle(verb: verb, tokens: [], context: context)
    }

    func test_errorsWithNoneSaysSo() throws {
        connection.reply(.errors(records: []))

        try run("errors")

        XCTAssertEqual(connection.daemonRequests, [.errors])
        XCTAssertEqual(context.messages, ["No errors."])
    }

    func test_errorsRendersRecordsUnderACount() throws {
        connection.reply(.errors(records: [
            ErrorRecord(label: "StaticFile  'input:/a.c'", entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")]),
        ]))

        try run("errors")

        XCTAssertEqual(context.messages, [
            "2 errors across 1 node:\n",
            "❌ StaticFile  'input:/a.c'",
            "   · errorLog, output: boom",
            "",
        ])
    }

    func test_resetSendsResetAndAnnouncesTheRebuild() throws {
        try run("reset")

        XCTAssertEqual(connection.daemonRequests, [.reset])
        XCTAssertEqual(context.messages, ["Rebuild started."])
    }

    func test_debugPrintsTheTextItGetsBack() throws {
        connection.reply(.debug(text: "BUILD GRAPH STATE (0 nodes)"))

        try run("debug")

        XCTAssertEqual(context.messages, ["BUILD GRAPH STATE (0 nodes)"])
    }

    func test_toolsRendersEachNamespaceAsConfigText() throws {
        connection.reply(.tools(namespaces: [
            ToolNamespaceRecord(namespace: "c.compiler", toolName: "clang", descriptors: []),
            ToolNamespaceRecord(namespace: "swift.compiler", toolName: "swiftc", descriptors: [
                ToolDescriptorRecord(name: "swiftc", version: "6.0", platform: "macOS", architecture: "arm64",
                                     machineSettings: ["sdk": "/x"]),
            ]),
        ]))

        try run("tools")

        XCTAssertEqual(context.messages, ["""
            // c.compiler: no clang is installed on this machine

            swift.compiler.toolDescriptor.name=swiftc
            swift.compiler.toolDescriptor.version=6.0
            swift.compiler.toolDescriptor.platform=macOS
            swift.compiler.toolDescriptor.architecture=arm64
            swift.compiler.sdk=/x
            """])
    }

    func test_aServerErrorIsThrownForTheInterpreterToPrint() {
        connection.responses.append((.error(.nodeError(description: "wire missing")), nil))

        XCTAssertThrowsError(try run("nudge")) { error in
            XCTAssertEqual((error as? ServerError)?.description, "wire missing")
        }
    }
}
