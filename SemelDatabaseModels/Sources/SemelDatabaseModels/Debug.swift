// Debug.swift
// SemelDatabaseModels
//
// Printing for a programmer sitting in front of the code.
//
// Deliberately narrow. Not for end users, not for CLI output, and not for diagnosing a
// semelserv instance someone is driving remotely — a line that a user is meant to read is
// ordinary output and belongs wherever that output is decided. This is for the things you
// want while a change is under your hands: a sanity warning, a case you did not expect to
// reach, a note that a long step started, a rough timing.
//
// It compiles to nothing in a release build, which is the whole reason it can be used freely.

public enum Debug {

    /// Whether `log` prints. Debug builds only — in release the calls are gone regardless.
    ///
    /// A test target is a debug build, so without this every suite would carry the engine's
    /// desk-debugging output. Silencing is a property of the run rather than of the call site,
    /// which is why it is a flag here and not an argument.
    public static var isEnabled = true

    /// Prints `message` in a debug build, and does nothing at all in a release one.
    ///
    /// `@autoclosure` is load-bearing, not decoration: without it a caller writing
    /// `Debug.log("resolved \(nodes.count) in \(elapsed)s")` would build that string on every
    /// call in release too, then throw it away. Deferred, the interpolation only runs if
    /// something is going to read it.
    ///
    /// `@inlinable` is what lets the optimiser act on that across a module boundary. The
    /// release body is empty, so with the body visible it can see the closure is never called
    /// and remove the call entirely; without it, every call site still allocates a closure to
    /// hand to a function that ignores it.
    ///
    /// The closure does not throw, deliberately. A line written to explain what happened must
    /// not be able to become a second failure, and a caller reaching for `try` inside one is
    /// usually reaching past something it already holds — `thisNode.id` rather than
    /// `requireID()`.
    @inlinable
    public static func log(_ message: @autoclosure () -> String,
                           function: StaticString = #function) {
        #if DEBUG
        guard isEnabled else {
            return
        }
        print("\(function): \(message())")
        #endif
    }

    /// The same, for something that looks wrong rather than something that happened.
    ///
    /// Plain `WARNING:` rather than a yellow triangle on purpose: ⚠️ already marks output a
    /// user is meant to read, and two kinds of warning that look alike in a terminal are worse
    /// than one that is plainer.
    ///
    /// The whole facility stops here. Levels, categories, subsystems and timestamps are what a
    /// logging system grows, and this program processes nodes in parallel — interleaved output
    /// from a dozen concurrent tasks does not get easier to read by being labelled more
    /// finely. Something worth keeping across a run belongs on a node, where it is attached to
    /// the thing it describes rather than to a moment.
    @inlinable
    public static func warn(_ message: @autoclosure () -> String,
                            function: StaticString = #function) {
        #if DEBUG
        guard isEnabled else {
            return
        }
        print("WARNING: \(function): \(message())")
        #endif
    }
}
