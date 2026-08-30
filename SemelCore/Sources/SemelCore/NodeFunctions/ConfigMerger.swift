// ConfigMerger.swift
// SemelCore
//
// Lays one config file over another, so a shared base can be written once and a project
// state only what it changes.
//

import SemelNodeKit

public struct ConfigMerger: NodeFunction {
    public static let kind: UInt = 26

    /// The settings to start from.
    static let basePort = "base"
    /// The settings laid over them. A key here replaces the same key in `base`.
    static let overridePort = "override"
    static let outputPort = "output"

    public var thisNode: Node

    public init(thisNode: Node) throws {
        self.thisNode = thisNode
    }

    /// Both required, because an optional port means the formula author may leave that input
    /// out — and a merger written with one side is that side. If a project has one config, it
    /// wires it directly; reaching for this node says there are two.
    ///
    /// Nothing to do with a config file that has not been written yet. Static wires are
    /// created atomically as the formula is interpreted, so naming a file creates its wire
    /// whether or not anyone has pushed it — the wire is simply carrying no value, which
    /// `settings(on:in:)` reads as nothing to add. An override file that may or may not exist
    /// is expressible either way; what required rules out is the formula omitting the input.
    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(basePort), .required(overridePort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let merged = settings(on: Self.basePort, in: input)
            .mergedWith(settings(on: Self.overridePort, in: input))

        return .init(outputValues: [Self.outputPort: .value(try merged.asPlainText().intern())],
                     inputWireExpectations: [:])
    }

    /// The settings arriving on one port.
    ///
    /// A wire carrying no value contributes nothing rather than failing the node — the same
    /// reading `ConfigSubset` takes. That is what makes an override file optional: a formula
    /// can name one nobody has written, and until it is, the base passes through whole.
    /// Failing instead would make every project with nothing to override unbuildable until
    /// someone wrote an empty file for it.
    ///
    /// What arrives is an *error*, not an absence: a `StaticFile` nobody has pushed publishes
    /// `noValue(.error)` carrying `initializing`. The node still runs, because
    /// `allInputsAreSatisfied` waits on `pending` but not on `error` — otherwise requiring
    /// these ports would have made an unwritten override stall the build rather than mean
    /// "nothing to add".
    ///
    /// The cost is that a genuine upstream failure looks the same as a file nobody wrote, so
    /// a broken base config would leave a partial configuration here and the tool downstream
    /// would report the setting it is missing rather than the reason it is missing. The two
    /// are separable — `initializing` is the ghost marker, and `ErrorReport` already keys on
    /// it — but this does not yet separate them.
    ///
    /// One wire per port is the intent, and both callers of this write exactly one. Wires are
    /// merged in sorted key order anyway, so that two of them cannot resolve differently
    /// between runs — but a port carrying two wires has no stated precedence, which is the
    /// thing this node exists to make explicit.
    private func settings(on port: String, in input: ProcessInput) -> [String: String] {
        let wires = input.inputValues[port] ?? [:]
        var result: [String: String] = [:]

        for wireKey in wires.keys.sorted() {

            guard let hash = try? wires[wireKey]?.expectValue(),
                  let text = try? hash.resolveAsString() else {

                continue
            }

            result = result.mergedWith([String: String](plainText: text))
        }

        return result
    }
}
