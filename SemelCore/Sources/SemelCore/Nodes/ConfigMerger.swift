// ConfigMerger.swift
// SemelCore
//
// Lays one config file over another, so a shared base can be written once and a project
// state only what it changes.
//

import SemelNodeKit

public struct ConfigMerger: Node {
    public static let kind: UInt = 26

    /// The settings to start from.
    static let basePort = "base"
    /// The settings laid over them. A key here replaces the same key in `base`.
    static let overridePort = "override"
    static let outputPort = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
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
    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(basePort), .required(overridePort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let merged = settings(on: Self.basePort, in: input)
            .mergedWith(settings(on: Self.overridePort, in: input))

        return .init(outputValues: [Self.outputPort: .value(try merged.asPlainText().intern())],
                     inputWireSpecs: [:])
    }

    /// The settings arriving on one port.
    ///
    /// A wire carrying no value contributes nothing rather than failing the node — the same
    /// reading `ConfigFilter` takes. That is what makes an override file optional: a formula
    /// can name one nobody has written, and until it is, the base passes through whole.
    /// Failing instead would make every project with nothing to override unbuildable until
    /// someone wrote an empty file for it.
    ///
    /// What arrives is not an absence: a `StaticFile` nobody has pushed publishes
    /// `noValue(.initializing)`, having no inputs and so nothing that would ever make it run.
    /// The node still runs on that, because `allInputsAreSatisfied` waits on `pending` and on
    /// nothing else — otherwise requiring these ports would make an unwritten override stall
    /// the build rather than mean "nothing to add".
    ///
    /// The cost is that this node treats a file nobody wrote and a genuine upstream failure
    /// alike, so a broken base config leaves a partial configuration here and the tool
    /// downstream reports the setting it is missing rather than the reason it is missing. The
    /// two are distinguishable — `initializing` is the state of a port nothing has processed,
    /// where a failure is `inputInError` or an error of its own — and telling the reader
    /// which one it met is B-92.
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
