//
//  LineCounterTests.swift
//  SemelExamplesTests
//
//  One line of output per input wire. Each wire's line depends on that wire alone, which is
//  what lets the tutorial show an edit to one file changing one line of the product.
//

@testable import SemelExamples
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class LineCounterTests: SemelExamplesTestCase {

    private func count(_ wires: [String: NodeValue]) throws -> String {
        let node = try LineCounter(thisNode: NodeRecord(id: 1, kind: LineCounter.kind, properties: [:]))
        let output = try node.process(input: ProcessInput(inputValues: [LineCounter.inputPort: wires]))
        return try XCTUnwrap(output.outputValues[LineCounter.outputPort]).expectValue().resolveAsString()
    }

    func test_writesOneLinePerWireSortedByName() throws {
        let result = try count([
            "main.c": .value(try "a\nb\nc\n".intern()),
            "hello.c": .value(try "x\n".intern()),
        ])

        XCTAssertEqual(result, "hello.c: 1\nmain.c: 3")
    }

    /// A last line without a newline is still a line; an empty file has none.
    func test_countsAnUnterminatedLastLineAndNothingInAnEmptyFile() throws {
        let result = try count([
            "empty": .value(try "".intern()),
            "unterminated": .value(try "a\nb".intern()),
        ])

        XCTAssertEqual(result, "empty: 0\nunterminated: 2")
    }

    /// A count that silently omitted a file would be wrong, so an input without a value
    /// fails the node rather than being skipped.
    func test_aWireWithoutAValueFailsRatherThanBeingLeftOut() throws {
        XCTAssertThrowsError(try count([
            "hello.c": .value(try "x\n".intern()),
            "main.c": .noValue(reason: .pending),
        ]))
        XCTAssertThrowsError(try count([
            "hello.c": .value(try "x\n".intern()),
            "main.c": .noValue(reason: .error(documentHash: try "did not compile".intern())),
        ]))
    }

    func test_noWiresIsAnEmptyOutputNotAnError() throws {
        XCTAssertEqual(try count([:]), "")
    }
}
