//
//  EndToEndFailure.swift
//  SemelEndToEndTests
//
//  What a failed step throws: enough that a CI failure reads without a rerun — the
//  step, the command line, the status, and the tails of the process's output and of
//  the server's log.
//

import Foundation

struct EndToEndFailure: Error, CustomStringConvertible {
    var step: String
    var message: String
    var commandLine: String?
    var status: Int32?
    var outputTail: String?
    var serverLogTail: String?

    var description: String {
        var lines = ["\(step): \(message)"]
        if let commandLine { lines.append("  command: \(commandLine)") }
        if let status { lines.append("  status: \(status)") }
        if let outputTail, !outputTail.isEmpty { lines.append("  output (tail):\n" + indented(outputTail)) }
        if let serverLogTail, !serverLogTail.isEmpty { lines.append("  server log (tail):\n" + indented(serverLogTail)) }
        return lines.joined(separator: "\n")
    }

    private func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
