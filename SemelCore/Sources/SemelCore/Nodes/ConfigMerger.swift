// ConfigMerger.swift
// SemelCore
//
// Lays one set of settings over another: a project's config file over the machine's, or a
// formula's `SettingsLiteral` over what a `ConfigFilter` selected. The one place in the
// graph where two sets of settings meet (B-120).
//

import SemelNodeKit

public struct ConfigMerger: Node {
    public static let kind: UInt = 26

    /// The settings to start from.
    static let basePort = "base"
    /// The settings laid over them. A key here replaces the same key in `base`.
    static let overridePort = "override"
    static let outputPort = "output"

    /// Two wires on one port are an error where they were merged in key order (B-120), so
    /// an entry the older code wrote for such a node holds a merge this one refuses.
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 3

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
    /// `settings(onPort:)` reads as nothing to add. An override file that may or may not
    /// exist is expressible either way; what required rules out is the formula omitting the
    /// input.
    ///
    /// The override is the one input in the design that may name a file nobody ever writes,
    /// so it is the one port that tolerates an absent value and the one a report says
    /// nothing about. The base is the settings this node starts from: a formula naming a
    /// base nobody pushed is a formula whose configuration is missing, and the report names
    /// the file rather than leaving the tools below to list the settings they lack.
    ///
    /// One wire on each. A second on either port has no stated precedence over the first,
    /// which is the thing this node exists to make explicit; a third set of settings is a
    /// second merger with this one on its `base` or its `override`.
    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(basePort), .required(overridePort)],
        outputPorts: [outputPort],
        inputPortsToleratingAbsentValue: [overridePort],
        // Laying one settings file over another costs what a lookup and a write cost, and the
        // merge is worth nothing to another machine (B-147).
        cachesOutputs: false
    )

    /// A wire carrying no value contributes nothing rather than failing the node — the same
    /// reading `ConfigFilter` takes. That is what makes an override file optional: a formula
    /// can name one nobody has written, and until it is, the base passes through whole.
    /// Failing instead would make every project with nothing to override unbuildable until
    /// someone wrote an empty file for it.
    ///
    /// This node treats a file nobody wrote and a genuine upstream failure alike, and it is
    /// the report rather than this node that tells the reader which it met. The two are
    /// distinguishable by state — `initializing` is the state of a port nothing has
    /// processed, where a failure is `inputInError` or an error of its own — so an unpushed
    /// base is named as the file it is, and a broken one is named where it broke. Only the
    /// override is silent, because only the override is allowed to be absent.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        let merged = try input.settings(onPort: Self.basePort)
            .mergedWith(try input.settings(onPort: Self.overridePort))

        return .init(outputValues: [Self.outputPort: .value(try merged.asPlainText().intern())],
                     inputWireSpecs: [:])
    }
}
