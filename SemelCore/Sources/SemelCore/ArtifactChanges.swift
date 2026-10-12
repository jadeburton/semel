// ArtifactChanges.swift
// SemelCore
//
// What happened to the artifacts between one settle and the next.
//
// The system is functional, so the steps inside a build are not the story: the story is
// that the graph settled and these products appeared, changed or went away. Anything a
// product did in between — woken, put back to pending, republished with the bytes it
// already had — is a mutation of an intermediate state and is not reported at all.

/// One settle's artifact diff, each list in path order.
///
/// Three kinds and no fourth. A product that failed is the error report's to tell: its
/// bytes are what they were when they were last reported, and calling that a
/// disappearance would have the same failure announced twice in two vocabularies.
public struct ArtifactChanges: Equatable, Sendable {

    /// Paths that carry a value and had no reported hash.
    public var appeared: [String]

    /// Paths whose value is not the one last reported for them.
    public var changed: [String]

    /// Paths whose `OutputFile` node was collected. The one genuinely event-shaped case:
    /// the node is gone by the time the report runs, so there is nothing left to compare.
    public var disappeared: [String]

    /// The folder of the tree product (B-63) each path above is an entry of, by path; a
    /// product named on its own has none. A client names a tree by its folder, as the
    /// error report does, and this is what lets it without taking paths apart. A path
    /// that disappeared carries its folder only when the collection that took it saw the
    /// tree: the reconciliation at a launch finds a row whose node is gone, and nothing
    /// left in the graph says which tree it was part of.
    public var treeFolders: [String: String]

    public init(appeared: [String] = [], changed: [String] = [], disappeared: [String] = [],
                treeFolders: [String: String] = [:]) {
        self.appeared    = appeared
        self.changed     = changed
        self.disappeared = disappeared
        self.treeFolders = treeFolders
    }

    public var isEmpty: Bool {
        appeared.isEmpty && changed.isEmpty && disappeared.isEmpty
    }
}
