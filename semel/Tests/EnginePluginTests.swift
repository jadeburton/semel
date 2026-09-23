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

        // The count goes through `countErrorRecords`, not `outputError`, so the same
        // settle report the idle-time event already counted is not counted twice.
        XCTAssertEqual(context.messages, [
            "2 errors across 1 node:\n",
            "❌ StaticFile  'input:/a.c'",
            "   · errorLog, output: boom",
            "",
        ])
        XCTAssertEqual(context.countedErrorRecords, [[
            ErrorRecord(label: "StaticFile  'input:/a.c'", entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")]),
        ]])
    }

    func test_waitSendsWaitAndReportsSettled() throws {
        try run("wait")

        XCTAssertEqual(connection.daemonRequests, [.wait])
        XCTAssertEqual(context.messages, ["Settled."])
    }

    /// The settle-time event this unblocks can fire and count *during* the `.wait`
    /// request, so the guard must already be clear before that request goes out, not
    /// after it comes back.
    func test_waitResetsErrorAccountingBeforeSendingTheRequest() throws {
        let orderLog = OrderLog()
        connection.orderLog = orderLog
        context.orderLog    = orderLog

        try run("wait")

        XCTAssertEqual(orderLog.entries, ["resetErrorRecordAccounting", "send"])
    }

    func test_resetSendsResetAndAnnouncesTheRebuild() throws {
        try run("reset")

        XCTAssertEqual(connection.daemonRequests, [.reset])
        XCTAssertEqual(context.messages, ["Rebuild started."])
    }

    func test_debugPrintsTheTextItGetsBack() throws {
        connection.reply(.debug, body: Data("BUILD GRAPH STATE (0 nodes)".utf8))

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

    /// B-94. A reply the server cannot frame reached the prompt as a closed socket and
    /// "error 2". The user is told which command was refused, how large its answer was and
    /// what the limit is.
    func test_aRefusedReplySaysWhatWasTooLargeAndHowLarge() {
        connection.responses.append((.error(.replyTooLarge(request: "debug", bytes: 3_000_000, limit: 1_048_576)), nil))

        XCTAssertThrowsError(try run("debug")) { error in
            let message = (error as? ServerError)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("`debug`"),   message)
            XCTAssertTrue(message.contains("3000000"),   message)
            XCTAssertTrue(message.contains("1048576"),   message)
        }
    }
}
