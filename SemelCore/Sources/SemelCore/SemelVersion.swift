//
//  SemelVersion.swift
//  SemelCore
//

public enum Semel {
    /// The release version. Bumped by hand, and it guards the graph's encoding: it is
    /// recorded in every graph database, and a mismatch at launch rebuilds the graph and
    /// keeps the cache (B-29, B-102). Bump it when a stored graph means something else to
    /// this release — a renamed node type embedded in every graphSpec, a port's reason
    /// stored as a number whose meaning moved.
    ///
    /// It is not what makes a changed output recompute. A node type that emits something
    /// different for equal inputs bumps its own `implementationVersion`, which moves the
    /// keys that type produces and leaves every other type's entries hitting; a graph
    /// rebuild alone would republish what the older code computed. AGENTS.md says when to
    /// bump that one.
    ///
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
    ///
    /// 0.1.4: the last two reasons spelled as sentences are states — a source that was
    /// pushed and removed, and a folder nobody has pushed into. Stored graphs hold those as
    /// errors carrying a word, so the rebuild restates the ports it preserves again.
    ///
    /// 0.1.5: the wires arriving at an input port are indexed by the name they arrive under,
    /// so wiring a fan into one port does not re-read the fan per wire. An index is part of
    /// the schema, and a database created without it is caught by the schema check before
    /// this marker is read — a stopped launch rather than a reset, as 0.1.2's key change was.
    public static let version = "0.1.5"
}
