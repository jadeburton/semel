//
//  NodeDescriptor.swift
//  build_system
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

    public init(inputPorts: [InputPort] = [], outputPorts: [String]) {
        self.inputPorts = inputPorts
        self.outputPorts = outputPorts
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
