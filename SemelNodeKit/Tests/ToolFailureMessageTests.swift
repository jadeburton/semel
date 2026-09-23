//
//  ToolFailureMessageTests.swift
//  SemelNodeKit
//
//  What a node's output carries when the tool behind it fails: the exit status, then
//  whatever the tool printed on either stream. A run that says nothing still names its
//  status, so a failure is never an empty line in the error report.
//

@testable import SemelNodeKit
import XCTest

final class ToolFailureMessageTests: XCTestCase {

    private func result(exitCode: Int32, stdout: String = "", stderr: String = "") -> SimplifiedToolExecuteResult {
        .init(exitCode: exitCode, resolvedSandboxPath: "/semel", infoOutput: stdout, errorOutput: stderr,
              outputFiles: [:], outputTrees: [:])
    }

    func test_aSilentFailureStillNamesTheStatus() {
        XCTAssertEqual(result(exitCode: 70).failureMessage(), "the tool exited with status 70")
        XCTAssertEqual(result(exitCode: 1).failureMessage(tool: "actool"), "actool exited with status 1")
    }

    func test_bothStreamsAreQuotedStderrFirst() {
        let message = result(exitCode: 1, stdout: "/* com.apple.actool.errors */\nAssets.xcassets: error: no runtime\n",
                             stderr: "warning: something on stderr").failureMessage(tool: "actool")

        XCTAssertEqual(message, """
            actool exited with status 1:
            warning: something on stderr
            /* com.apple.actool.errors */
            Assets.xcassets: error: no runtime
            """)
    }

    func test_theTreeAndOutputValuesCarryTheSameMessage() throws {
        let failed = result(exitCode: 2, stdout: "error: it broke")

        guard case .noValue(.error(let treeMessage)) = try failed.asTreeNodeValue(folder: "out"),
              case .noValue(.error(let outputMessage)) = try failed.asOutputNodeValue() else {
            return XCTFail("a failed run carries an error on both")
        }
        XCTAssertEqual(try treeMessage.resolveAsString(), "the tool exited with status 2:\nerror: it broke")
        XCTAssertEqual(treeMessage, outputMessage)
    }
}
