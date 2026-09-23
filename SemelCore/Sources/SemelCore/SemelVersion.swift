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
    ///
    /// 0.1.2: a wire's name is part of its primary key, so a port pair holds the several
    /// named wires its consumers demand. The `Wire` table's key says so too, and a database
    /// keyed the other way is caught by the schema check before this marker is read: that
    /// one is not a reset but a stopped launch, telling the user which file to delete.
    ///
    /// 0.1.3: a port's reason for having no value is a state — `initializing`,
    /// `inputNotProduced`, `inputInError` — where it was an error carrying a sentence.
    /// Stored graphs hold the reason as a number per port, and the numbers an older graph
    /// holds mean something else, so the rebuild also restates the ports it preserves.
    public static let version = "0.1.3"
}
