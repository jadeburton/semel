// NodeNotice.swift
// SemelNodeKit
//
// A line a node has for the user that is neither its output nor its failure.

/// Where a node says something to the user without failing: a vendored dependency with no
/// lock beside it (B-06) is worth a line and not worth stopping a build for.
///
/// A swappable closure, the shape of `ToolRunnerRegistry.instance`, because a toolchain
/// node cannot reach the engine that carries such a line to a terminal. The engine installs
/// its own reporter when it is built; until then, and in a test that builds nodes by hand,
/// the line is printed.
public enum NodeNotice {
    public static var reporter: (String) -> Void = { print($0) }

    public static func post(_ line: String) {
        reporter(line)
    }
}
