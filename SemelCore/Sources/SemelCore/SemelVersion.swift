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
    /// 0.1.5: stamped by an unreleased build of the change below, whose graph shape was a
    /// different one. Skipped, so that a home carrying that stamp is rebuilt rather than
    /// matched.
    ///
    /// 0.1.6: a `Folder` publishes a second derived value, the Merkle root of everything
    /// under it, on a new `contentRoot` port (B-26). A node is given one row per declared
    /// port when it is created, so every folder in a stored graph holds none for this one —
    /// a state `GraphCheck` reports as damage, a read of the port throws on, and the fold
    /// above such a folder would read as an empty subtree. The rebuild folds every preserved
    /// folder, which is what makes the rows.
    ///
    /// 0.1.7: `Configuration`'s input port is `base`, where it was `inherit` (B-109). The
    /// port name is in every `Configuration` node's spec, so the rename changes the
    /// identity of each one and of everything wired below it.
    ///
    /// 0.1.8: a node's identity is a hash one level deep — its kind, its properties and
    /// the identities on its static ports' wires — stored in `Node.identity` in place of
    /// the spec text `Node.graphSpec` held (B-115). A column with another meaning, so a
    /// stored graph is rebuilt; the cache is keyed on values, not specs, and survives.
    ///
    /// 0.1.9: the first public release. Nothing a stored graph holds means anything else;
    /// the bump is so that the banner and the release tag say the same thing, at the cost
    /// of one graph rebuild per home, the cache kept.
    ///
    /// 0.1.10: `Configuration` is `SettingsLiteral`, a source with no input port, and every
    /// formula lays its literals over its settings with a `ConfigMerger` instead (B-120). The
    /// rename alone would change nothing stored — an identity is over the kind — but a stored
    /// literal node holds a wire into the `base` port its type no longer declares, and an
    /// output merged from it that nothing would ever recompute, a source never being
    /// scheduled. The same reason as 0.1.7: what a stored node's wiring means has moved.
    ///
    /// 0.1.11: `ProjectFinder` publishes the project files a formula has to include on a
    /// new `includableProjects` port (B-10). The reason 0.1.6 was a bump: a node is given
    /// one row per declared port when it is created, so the finder in a stored graph has
    /// none for this one, and the idle report would read nothing until the next push.
    ///
    /// *Not* a bump: the `ArtifactSnapshot` table (B-50). A table is a schema change, and
    /// a schema change usually stops the launch — but this one is derived state that
    /// starts empty, `createTables` is `IF NOT EXISTS`, and a database opened without it
    /// gains it before the fingerprint is taken. The first settle of a launch reconciles
    /// it against the graph, which is what a rebuild would have achieved at the price of
    /// discarding every derived node. Nothing a stored graph holds means anything else.
    ///
    /// 0.1.12: a `StaticFile` publishes the mode it was pushed with on a new `fileMetadata`
    /// port (B-108). The reason 0.1.6 was a bump, for a type that is never scheduled: the
    /// rebuild gives every preserved file the row, with the default mode until the next
    /// push states the real one.
    ///
    /// 0.1.13: a symbolic link is pushed as one (B-77) — a file's on its metadata, a
    /// folder's on a new `symbolicLink` port — and a folder's content root is folded under
    /// `semel-folder-content-root 3`, a link a line of its own. The reason 0.1.6 was a bump,
    /// twice over: every preserved folder is given the row for the port, and folded again,
    /// since a root folded under 2 is one a lock written by `prepare` can never match. What
    /// was pushed as a copy of a link becomes the link at the next push.
    ///
    /// 0.1.14: a file's line in a content root carries its mode, under
    /// `semel-folder-content-root 4` (B-132). Every preserved folder holds a root folded
    /// under 3, which a push comparing roots with the disk would never match, so the rebuild
    /// folds them again.
    ///
    /// 0.1.15: a `Folder` publishes a third derived value, the names of everything below it,
    /// on a new `subtreeManifest` port (B-135), and `ProjectFinder` reads the input file
    /// system through it on one port where it walked the folders on two. The reason 0.1.6
    /// was a bump: the rebuild folds every preserved folder's subtree manifest, which makes
    /// the rows; and the finder it preserves drops the wires of the ports it no longer has.
    public static let version = "0.1.15"
}
