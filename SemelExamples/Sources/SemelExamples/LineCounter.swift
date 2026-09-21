//
//  LineCounter.swift
//  SemelExamples
//
//  Counts the lines of whatever is wired to it: one `name: count` line per input wire.
//
//  The smallest node that does something, and the reference copy of the one
//  docs/tutorial/first-node.md builds by hand. It runs no tool and reads no configuration,
//  so everything a node must have is here and nothing else is. Work this quick is
//  recomputed rather than cached — the engine's decision, made on processing duration, not
//  the node's.
//
//  The names are the wire names, which the formula chooses. The node never sees a path
//  unless the formula hands it one as a name.

import SemelDatabaseModels
import SemelNodeKit

public struct LineCounter: Node {
    public static let kind: UInt = 36

    static let inputPort = "input"
    static let outputPort = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let wires = input.inputValues[Self.inputPort] ?? [:]

        // Sorted, because a dictionary's order differs from one process to the next and the
        // output is a value other nodes and the cache compare byte for byte.
        //
        // `expectValue()` throws on a wire that is pending or in error. A count that left a
        // file out would be a wrong answer that looks like a right one, so there is no
        // skipping here.
        var lines: [String] = []
        for (name, value) in wires.sorted(by: { $0.key < $1.key }) {
            let text = try value.expectValue().resolveAsString()
            lines.append("\(name): \(Self.lineCount(of: text))")
        }

        return .init(outputValues: [Self.outputPort: .value(try lines.joined(separator: "\n").intern())],
                     inputWireSpecs: [:])
    }

    /// Newline-terminated lines, plus a last line that has no newline.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }
}
