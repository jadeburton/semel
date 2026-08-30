// ConfigSubset.swift
// SemelCore
//
// Selects one node's settings out of a config file that holds everyone's.
//
// A config file is written under a global namespace — `swift.compiler.sdkVersion`,
// `clang.linker.target` — so a single file can configure every node in a project. This takes
// the slice under one prefix and strips it, leaving exactly what that node's
// `init(properties:)` already expects to read.
//
// Selecting here rather than inside the tool is what makes an edit local. A cache key
// aggregates every input port's wire values, so text arriving at a tool has already
// rescheduled it and changed its key before the tool can decide it does not care. Upstream,
// an unrelated edit leaves this node's output byte-identical, writeToOutputPort returns false,
// and nothing below is scheduled. With one of these per prefix and ten thousand compilers
// sharing it, that is the difference between one node reparsing a file and ten thousand
// recompiling.

import SemelNodeKit

public struct ConfigSubset: NodeFunction {
    public static let kind: UInt = 25

    static let inputPort = "input"
    static let outputPort = "output"

    /// The namespace this node takes, without a trailing dot: `swift.compiler`.
    static let prefixProperty = "prefix"

    public var thisNode: Node

    public init(thisNode: Node) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let prefix = thisNode.properties[Self.prefixProperty] ?? ""

        // A wire named in the shape before its file exists is a ghost, and one whose file
        // failed to read is not this node's business to explain — either way it contributes
        // nothing, rather than failing every tool downstream over a config file nobody wrote
        // yet. The tool that actually needs a setting is what can say which one is missing
        // and where to write it; an errored selector output could only ever say "something
        // upstream is wrong," which helps nobody.
        let wires = input.inputValues[Self.inputPort] ?? [:]
        var merged: [String: String] = [:]
        for wireKey in wires.keys.sorted() {
            guard let hash = try? wires[wireKey]!.expectValue() else { continue }
            let text = try hash.resolveAsString()
            merged = merged.mergedWith([String: String](plainText: text))
        }

        // A whole segment, so `swift.compiler` does not also claim `swift.compilerPlugin`.
        // Whatever follows is the key, dots and all — stripping, not parsing.
        let qualifier = prefix + "."
        var selected: [String: String] = [:]
        for (key, value) in merged where key.hasPrefix(qualifier) {
            let bare = String(key.dropFirst(qualifier.count))
            guard !bare.isEmpty else { continue }
            selected[bare] = value
        }

        return .init(outputValues: [Self.outputPort: .value(try selected.asPlainText().intern())],
                     inputWireExpectations: [:])
    }
}
