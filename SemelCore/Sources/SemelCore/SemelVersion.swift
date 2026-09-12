//
//  SemelVersion.swift
//  SemelCore
//

public enum Semel {
    /// The release version. Bumped by hand: it is recorded in every graph database and a
    /// mismatch at launch resets the graph (B-29), so bumping it is how a release that
    /// computes different outputs from the same inputs gets those outputs recomputed.
    /// Deliberately not a hash of the binary — that would reset on every rebuild of Semel,
    /// including a comment change, and nobody developing Semel would ever see a cache hit.
    ///
    /// 0.1.1: node types renamed (B-44). Type names are embedded in every stored graphSpec,
    /// so a graph built before the rename matches nothing and has to be rebuilt.
    public static let version = "0.1.1"
}
