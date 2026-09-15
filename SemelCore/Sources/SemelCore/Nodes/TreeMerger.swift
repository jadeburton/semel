//
//  TreeMerger.swift
//  SemelCore
//

import SemelNodeKit

/// Several trees as one.
///
/// A bundle folder collects what several tools wrote — the asset compiler's `Assets.car`
/// and icons, the string compiler's `.lproj` folders — and a formula names one tree
/// product per folder, so the trees have to become one first. Two trees holding one path
/// are a mistake in the formula, not a choice for the last writer, and the error names
/// the path.
struct TreeMerger: Node {

    public static let kind: UInt = 32

    /// The trees to merge, one wire each; merged in wire-key order, which only matters
    /// for the error a collision produces.
    static let inputPort = "input"
    static let outputPort = "files"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        var merged: [String: TreeManifestEntry] = [:]
        var from: [String: String] = [:]

        for (key, value) in (input.inputValues[Self.inputPort] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let manifest: TreeManifest
            switch value {
            case .noValue(let reason):
                // Whatever stopped one tree stops the merge, with the same reason.
                return .init(outputValues: [Self.outputPort: .noValue(reason: reason)], inputWireSpecs: [:])
            case .value(let hash):
                manifest = try TypeRegistry.decodeAndCast(encodedJSON: try hash.resolveAsString())
            }
            for entry in manifest.entries {
                if let earlier = from[entry.path] {
                    let message = "two trees hold '\(entry.path)': \(earlier) and \(key)"
                    return .init(outputValues: [Self.outputPort: .noValue(reason: .error(messageDataObjectHash: try message.intern()))],
                                 inputWireSpecs: [:])
                }
                merged[entry.path] = entry
                from[entry.path] = key
            }
        }

        let tree = TreeManifest(entries: Array(merged.values))
        return .init(outputValues: [Self.outputPort: .value(try tree.toJSON().intern())], inputWireSpecs: [:])
    }
}
