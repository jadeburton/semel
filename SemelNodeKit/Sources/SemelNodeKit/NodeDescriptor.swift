//
//  NodeDescriptor.swift
//  semel
//

import Foundation

// Describes the input and output ports of a Node
public struct NodeDescriptor {

    public enum InputPort {
        case required(String, Arity = .one)  // static, must be wired at creation time
        case optional(String, Arity = .one)  // static, may be left not-wired at creation time
        case dynamic(String)                 // wiring managed at runtime by process(); any number of wires

        /// How many wires a static port holds.
        ///
        /// Declared rather than read off how the node uses the port, because the first
        /// reader of the answer is not the node: the applier refuses a formula that wires
        /// several sources to a one-wire port when it builds the graph, naming the formula's
        /// node, and `ProcessInput.onlyWire` refuses them again when the node runs. A port
        /// that took whichever of two wires a dictionary yielded first would pick by
        /// per-process order, so one formula would build two different things.
        public enum Arity {
            /// One wire: a configuration, the source file a compiler compiles.
            case one
            /// Any number of named wires, all of which the node reads: a linker's object
            /// files, a preprocessor's header folders.
            case many
        }

        public var name: String {
            switch self {
            case .required(let name, _), .optional(let name, _), .dynamic(let name): name
            }
        }

        /// Whether the port holds one wire. A dynamic port holds as many as its node demands.
        public var holdsOneWire: Bool {
            switch self {
            case .required(_, let arity), .optional(_, let arity): arity == .one
            case .dynamic: false
            }
        }
    }

    public let inputPorts: [InputPort]
    public let outputPorts: [String]

    /// The input ports whose node reads an absent value as nothing to add.
    ///
    /// A separate question from `required`/`optional`, which is about whether the formula
    /// has to name the input at all. This one is about the value arriving on a wire that
    /// *is* there, and it has one reader: `ErrorReport`, deciding whether a source that will
    /// never produce a value is worth a line. A port not named here needs what it is wired
    /// to, so an unpushed file feeding it is named; a port named here is one where a file
    /// nobody wrote is the expected state and naming it would be noise.
    ///
    /// The set is deliberately small — `ConfigMerger.override`, the one input in the design a
    /// formula may name for a file that need never exist, and the clang preprocessor's and
    /// include finder's header ports, which a quoted include under a false `#if` fills with
    /// a header no checkout holds and clang itself judges (B-79). It still earns its place
    /// as an axis: a project with a local override builds clean because the port says so,
    /// and the report learns that without being taught any node's type.
    public let inputPortsToleratingAbsentValue: Set<String>

    /// Per input port that carries files, the static port beside it that carries their
    /// modes: `input` → `fileMetadata` on `OutputFile` and `TreeBuilder`.
    ///
    /// A formula names only the files. The mode wires are filled where a spec is built
    /// (`GraphSpecNode.wiringFileMetadata()`), one per file wire whose source publishes a
    /// `fileMetadata` port, so a formula never spells them and a func handed a file — which
    /// cannot pick another port off it — still passes its mode on.
    public let fileMetadataInputPorts: [String: String]

    /// The property a formula's folder fills when the formula that names the node leaves it
    /// out: `root` on `SwiftFormulaConverter`, which reads the build's configuration and
    /// vendored dependencies from there.
    ///
    /// Filled by the formula's builder rather than defaulted by the node, because only the
    /// builder knows which formula named it. A node defaulting to a folder it does know —
    /// the package it converts — reads `semel.config` from inside a vendored package when a
    /// formula names one directly, and makes ghosts there of files nobody will push.
    public let formulaFolderProperty: String?

    public init(inputPorts: [InputPort] = [],
                outputPorts: [String],
                inputPortsToleratingAbsentValue: Set<String> = [],
                fileMetadataInputPorts: [String: String] = [:],
                formulaFolderProperty: String? = nil) {
        self.inputPorts = inputPorts
        self.outputPorts = outputPorts
        self.inputPortsToleratingAbsentValue = inputPortsToleratingAbsentValue
        self.fileMetadataInputPorts = fileMetadataInputPorts
        self.formulaFolderProperty = formulaFolderProperty
    }

    /// Whether a value that will never arrive on this port is something the node minds.
    public func toleratesAbsentValue(onInputPort name: String) -> Bool {
        inputPortsToleratingAbsentValue.contains(name)
    }

    /// Whether the graph has anything to hand this node.
    ///
    /// A node with no input ports is a source: its value comes from outside the graph (a
    /// pushed file, a directory listing), so it is never scheduled and never processed.
    /// This replaced a second protocol that encoded the same fact in the type system.
    public var hasInputs: Bool { !inputPorts.isEmpty }

    // MARK: - Computed views (used by existing call sites)

    public var staticInputPorts: [String] {
        inputPorts.compactMap {
            switch $0 {
            case .required(let name, _), .optional(let name, _): return name
            case .dynamic: return nil
            }
        }
    }

    /// The static ports that take one wire, which the applier refuses a second wire on.
    public var oneWireInputPorts: Set<String> {
        Set(inputPorts.filter(\.holdsOneWire).map(\.name))
    }

    /// The ports that must be wired for the node to produce anything. A required port with
    /// no wire is a node waiting for a value nothing will ever send, which is what
    /// `GraphCheck` reports and what nothing else can see.
    public var requiredInputPorts: [String] {
        inputPorts.compactMap {
            if case .required(let name, _) = $0 {
                return name
            }
            return nil
        }
    }

    public var optionalStaticInputPorts: [String] {
        inputPorts.compactMap {
            if case .optional(let name, _) = $0 {
                return name
            }
            return nil
        }
    }

    public var dynamicInputPorts: [String] {
        inputPorts.compactMap {
            if case .dynamic(let name) = $0 {
                return name
            }
            return nil
        }
    }
}
