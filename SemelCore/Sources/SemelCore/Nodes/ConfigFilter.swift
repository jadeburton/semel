// ConfigFilter.swift
// SemelCore
//
// Selects one node's settings out of a config file that holds everyone's.
//
// A config file is written under a global namespace — `swift.compiler.sdkVersion`,
// `clang.linker.target` — so a single file can configure every node in a project. This takes
// the slice under one prefix and strips it, leaving exactly what that node's
// `init(properties:)` already expects to read.
//
// Selecting here rather than inside the tool is what keeps an edit cheap. A cache key
// aggregates every input port's wire values, so unfiltered text arriving at a tool changes
// that tool's key: every compiler would miss cache and recompile over a setting only the
// linker reads.
//
// What it does not do is stop the cascade. Writing the config file marks the whole subgraph
// below it pending (`NodeSupport.writeToOutputPort`), so this node's own write is
// pending -> value, a change, and everything downstream is rescheduled whether or not the
// selected slice moved. What stays put is node *identity*: the prefix is in the graph spec
// and the values are not, so the woken compilers are the same nodes as before and hit cache
// instead of recompiling. Ten thousand reschedules and cache lookups; no recompiles.

import SemelNodeKit

public struct ConfigFilter: Node {
    public static let kind: UInt = 25

    static let inputPort = "input"
    static let outputPort = "output"

    /// The namespace this node takes, without a trailing dot: `swift.compiler`.
    public static let prefixProperty = "prefix"

    /// Two wires on `input` are an error where they were merged in key order (B-120), so
    /// an entry the older code wrote for such a node holds a merge this one refuses.
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 3

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    /// The input needs its file. A config file nobody has written selects to nothing here
    /// rather than failing every tool below it, which is a decision about whose output
    /// carries the error — not a claim that the absence is fine. The file is named where the
    /// reader can act on it, so the port is left out of `inputPortsToleratingAbsentValue`.
    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let prefix = thisNode.properties[Self.prefixProperty] ?? ""

        // A wire whose file has never been written carries no value, and one whose file
        // failed to read is not this node's business to explain — either way it contributes
        // nothing, rather than failing every tool downstream over a config file nobody wrote
        // yet. The tool that actually needs a setting is what can say which one is missing
        // and where to write it; an errored selector output could only ever say "something
        // upstream is wrong," which helps nobody. Two wires are another matter: a selector
        // is not where settings meet, and it says so (B-120).
        let settings = try input.settings(onPort: Self.inputPort)

        // A whole segment, so `swift.compiler` does not also claim `swift.compilerPlugin`.
        // Whatever follows is the key, dots and all — stripping, not parsing.
        let qualifier = prefix + "."
        var selected: [String: String] = [:]
        for (key, value) in settings where key.hasPrefix(qualifier) {
            let bare = String(key.dropFirst(qualifier.count))
            guard !bare.isEmpty else { continue }
            selected[bare] = value
        }

        return .init(outputValues: [Self.outputPort: .value(try selected.asPlainText().intern())],
                     inputWireSpecs: [:])
    }
}
