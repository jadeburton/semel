// ConfigMerger.swift
// SemelCore
//
// Lays one config file over another, so a shared base can be written once and a project
// state only what it changes.
//
// Killing inheritance removed every implicit way for one config to build on another — no
// ancestor walk, no cross-tool defaults — which left a project's settings complete where they
// are written, and left several projects repeating a toolchain description word for word.
// This gives back composition without giving back inheritance: nothing is found by position
// or by convention, the formula names both files, and precedence is a port rather than an
// ordering someone has to know about.
//
// `Configuration` can already merge wired text, and its `inherit` port takes any number of
// wires — but which wins is decided by sorting wire *keys*, which is invisible at the call
// site and silently wrong the moment someone names their wires `base` and `override`.
// Precedence here is the port a wire is attached to, and it reads the same way in the formula
// as it behaves.

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

    /// Both ports are required, which is about the *wire* existing, not about the file behind
    /// it having been written. A formula naming a config file creates the wire whether or not
    /// anyone has pushed that file yet, so an optional override is still expressible — the
    /// wire is there and carries no value, which `settings(on:in:)` reads as nothing to add.
    ///
    /// Optional ports would instead allow a merger with one side unwired, which merges nothing
    /// and is a node the graph would carry for no reason. Requiring both means a formula that
    /// names only one config fails when the graph is built, saying which port is unwired.
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
    /// A wire with no value contributes nothing rather than failing the node — the same
    /// reading `ConfigSubset` takes. It is what makes an override file optional: a formula can
    /// name one that has not been written, and until it is, the base passes through whole.
    /// Failing here instead would make every project that has nothing to override unbuildable
    /// until someone wrote an empty file.
    ///
    /// One wire per port is the intent, and both callers of this write exactly one. Wires are
    /// merged in sorted key order anyway, so that two of them cannot resolve differently
    /// between runs — but a port carrying two wires has no stated precedence, which is the
    /// thing this node exists to make explicit.
    private func settings(on port: String, in input: ProcessInput) -> [String: String] {
        let wires = input.inputValues[port] ?? [:]
        var result: [String: String] = [:]
        for wireKey in wires.keys.sorted() {
            guard let hash = try? wires[wireKey]!.expectValue(),
                  let text = try? hash.resolveAsString() else { continue }
            result = result.mergedWith([String: String](plainText: text))
        }
        return result
    }
}
