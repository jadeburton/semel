//
//  NodeDescriptor.swift
//  semel
//

import Foundation

// Describes the input and output ports of a Node
public struct NodeDescriptor {

    public enum InputPort {
        case required(String)  // static, must be wired at creation time
        case optional(String)  // static, may be left not-wired at creation time
        case dynamic(String)   // wiring managed at runtime by process()

        public var name: String {
            switch self {
            case .required(let name), .optional(let name), .dynamic(let name): name
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

    public init(inputPorts: [InputPort] = [],
                outputPorts: [String],
                inputPortsToleratingAbsentValue: Set<String> = [],
                fileMetadataInputPorts: [String: String] = [:]) {
        self.inputPorts = inputPorts
        self.outputPorts = outputPorts
        self.inputPortsToleratingAbsentValue = inputPortsToleratingAbsentValue
        self.fileMetadataInputPorts = fileMetadataInputPorts
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
            case .required(let name), .optional(let name): return name
            case .dynamic: return nil
            }
        }
    }

    /// The ports that must be wired for the node to produce anything. A required port with
    /// no wire is a node waiting for a value nothing will ever send, which is what
    /// `GraphCheck` reports and what nothing else can see.
    public var requiredInputPorts: [String] {
        inputPorts.compactMap {
            if case .required(let name) = $0 {
                return name
            }
            return nil
        }
    }

    public var optionalStaticInputPorts: [String] {
        inputPorts.compactMap {
            if case .optional(let name) = $0 {
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
