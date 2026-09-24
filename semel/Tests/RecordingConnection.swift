//
//  RecordingConnection.swift
//  SemelCLITests
//
//  A connection that answers from a script and remembers what it was asked, so a plugin
//  can be tested on what it sends and how it renders the reply, with no engine anywhere.
//

@testable import SemelCLI
import Foundation
import SemelNodeKit
import SemelProtocol

/// Where `RecordingConnection` and `TestCommandContext` both note what they did, so a test
/// can pin the *order* of two calls across the two fakes — not just that each happened.
final class OrderLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

final class RecordingConnection: SemelConnection {

    private(set) var requests: [(request: Request, body: Data?)] = []
    var responses: [(response: Response, body: Data?)] = []
    var onEvent: ((Event) -> Void)?
    var orderLog: OrderLog?

    func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        orderLog?.record("send")
        requests.append((request, body))
        guard !responses.isEmpty else {
            return (.daemon(.ok), nil)
        }
        let scripted = responses.removeFirst()
        return (scripted.response, scripted.body)
    }

    /// Queue one daemon reply.
    func reply(_ response: DaemonResponse, body: Data? = nil) {
        responses.append((.daemon(response), body))
    }

    var daemonRequests: [DaemonRequest] {
        requests.compactMap { entry in
            if case .daemon(let request) = entry.request { return request }
            return nil
        }
    }
}

/// A `CommandContext` over a fake connection that captures output instead of printing it.
final class TestCommandContext: CommandContext {

    let connection: any SemelConnection
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty
    var openBatchDepth = 0

    private(set) var messages: [String] = []
    private(set) var errors: [String] = []
    private(set) var countedErrorRecords: [[ErrorRecord]] = []
    private(set) var resetErrorRecordAccountingCallCount = 0
    var orderLog: OrderLog?

    var allOutput: [String] { messages + errors }

    init(connection: any SemelConnection, baseDirectory: String = NSTemporaryDirectory()) {
        self.connection    = connection
        self.baseDirectory = baseDirectory
    }

    func outputMessage(_ message: String) { messages.append(message) }
    func outputError(_ message: String)   { errors.append(message) }

    func countErrorRecords(_ records: [ErrorRecord]) { countedErrorRecords.append(records) }

    func resetErrorRecordAccounting() {
        resetErrorRecordAccountingCallCount += 1
        orderLog?.record("resetErrorRecordAccounting")
    }
}
