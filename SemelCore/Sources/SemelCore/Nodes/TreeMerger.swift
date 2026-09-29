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
/// with different content are a mistake in the formula, not a choice for the last writer,
/// and the error names the path. Two trees holding the same file at one path are one
/// file: an app links two packages that both depend on a third, and each package's
/// `bundles_<Product>()` tree carries the third's resource bundle (B-77), so the same
/// `Assets.car` arrives twice with one hash and one mode, and is placed once (B-125).
struct TreeMerger: Node {

    public static let kind: UInt = 32

    /// 2: the same entry from two trees merges instead of failing.
    /// 3: a tree's symbolic links merge as entries, and one tree's link where another holds
    /// entries below it is a collision (B-77).
    public static let implementationVersion = 3

    /// The trees to merge, one wire each; merged in wire-key order, which only matters
    /// for the error a collision produces.
    static let inputPort = "input"
    static let outputPort = "files"

    /// A folder every merged entry is placed under: `FoodTruckKit_FoodTruckKit.bundle`
    /// puts a package target's resources where a bundle inside an app bundle lives
    /// (B-77). Absent or empty, the trees merge at the root.
    static let underProperty = "under"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.optional(inputPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        var merged = TreeMerge()
        let under = thisNode.properties[Self.underProperty].map { Path($0) } ?? .empty

        for (key, value) in (input.inputValues[Self.inputPort] ?? [:]).sorted(by: { $0.key < $1.key }) {
            // Whatever stopped one tree stops the merge, and demanding the value is how this
            // node says so: the engine writes the state that follows from what stood in the
            // way, rather than this node repeating a sentence another node wrote.
            let manifest: TreeManifest = try TypeRegistry.decodeAndCast(
                encodedJSON: try value.expectValue().resolveAsString())
            // Every entry under one folder, so a link, relative to its own folder, still
            // names what it named.
            if let collision = merged.add(manifest.entries.map { $0.placed(under: under) }, from: key) {
                return try failed(collision)
            }
        }
        if let collision = merged.collisionBelowALink {
            return try failed(collision)
        }

        return .init(outputValues: [Self.outputPort: .value(try merged.manifest.toJSON().intern())], inputWireSpecs: [:])
    }

    private func failed(_ collision: TreeMerge.Collision) throws -> ProcessOutput {
        .init(outputValues: [Self.outputPort: .noValue(reason: .error(messageDataObjectHash: try collision.description.intern()))],
              inputWireSpecs: [:])
    }
}
