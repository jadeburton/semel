// Renderers.swift
// semel
//
// How structured replies become text. The engine renders nothing: every reply and event
// arrives as values, and the lines are drawn here. The error report has a file of its own,
// `ErrorReportRenderer.swift`.

import Foundation
import SemelProtocol

/// The marks the prompt is allowed to use, all of them, in one place.
///
/// A mark per event type would end as a mark per command, and a screen with one of
/// everything on it says nothing. Two earn their place, and they are a pair: a mark says
/// good or bad and nothing else. A fact the line already carries in words — how much of
/// the work the cache answered — does not want a glyph of its own; a second good-news
/// symbol splits the one reading the mark exists for, and leaves the reader deciding
/// whether it is a warning. Anything else prints unmarked until there is a reason it
/// cannot.
enum Mark {
    /// Something is wrong: an invariant of the graph that does not hold, or a settle that
    /// left errors. A settle summary carrying a non-zero error count opens with it, and
    /// `check` opens every finding with it. The error report itself is unmarked: its first
    /// line is the diagnostic, as the tool wrote it, so a terminal makes it a link.
    static let failure = "❌"

    /// Nothing is wrong: a settle that left the graph with no errors in it, or a `check`
    /// that found nothing to report.
    static let settled = "✅"

    /// Not yet: the settle is still running. The one mark that says neither good nor bad,
    /// allowed because it never stays on the screen — it opens the progress line, which
    /// is redrawn in place and erased before any report prints (B-95). Nothing that
    /// scrolls may use it.
    static let working = "⏳"
}

/// How many paths any one of the prompt's reports names, one per line, before it reports
/// a count instead.
///
/// One number rather than one per report, because it is one reading: "too many paths to
/// read". A push or an `rm` of a whole project runs to thousands, a cold build publishes
/// as many products, and a wall of paths buries whatever else was said either way.
enum PathList {
    static let namedIndividually = 20
}

enum SettleSummaryRenderer {

    /// One line for one settle, or nothing when the settle had nothing to do.
    ///
    /// The counts are the engine's, passed through: each is a number of distinct nodes,
    /// and `scheduled` exceeds `computed + fromCache` by however many nodes were woken
    /// before their inputs were ready. The mark is the only reading the client adds, and
    /// it reads one thing — whether the graph is broken.
    static func line(scheduled: Int, computed: Int, fromCache: Int, errors: Int) -> String? {
        guard scheduled > 0 else {
            return nil
        }

        let mark      = errors > 0 ? Mark.failure : Mark.settled
        let nodes     = scheduled == 1 ? "node"  : "nodes"
        let errorWord = errors == 1 ? "error" : "errors"

        return "\(mark) \(scheduled) \(nodes) scheduled, \(computed) computed, "
             + "\(fromCache) from cache, \(errors) \(errorWord)"
    }
}

enum ArtifactChangeRenderer {

    /// The lines that go under the settle summary: one per artifact, in the order
    /// appeared, changed, disappeared, each group in path order.
    ///
    /// Unmarked and indented, because they belong to the line above them. A mark says
    /// good or bad and nothing else, and an artifact that changed is neither — a product
    /// that failed is in the error report, under the mark that means it.
    ///
    /// **The cap is per kind, not over the three together.** A settle that publishes ten
    /// thousand products and removes one has to show the removal: capping the combined
    /// list in order would spend the whole budget on appearances and drop the one line
    /// worth reading. So each kind names up to `PathList.namedIndividually` paths and
    /// then says how many it left out.
    static func lines(appeared: [String], changed: [String], disappeared: [String]) -> [String] {
        linesForKind(appeared, "appeared")
            + linesForKind(changed, "changed")
            + linesForKind(disappeared, "disappeared")
    }

    private static func linesForKind(_ paths: [String], _ verb: String) -> [String] {
        var lines = paths.prefix(PathList.namedIndividually).map { "   \(verb): \($0)" }

        let rest = paths.count - lines.count
        if rest > 0 {
            lines.append("   and \(rest) more \(verb)")
        }
        return lines
    }
}

enum CheckFindingRenderer {

    /// One line per finding: what it is about, then what is wrong with it. Marked as a
    /// failure, because an invariant that does not hold is one — the mark says good or bad
    /// and nothing else, and `check` has exactly those two things to say.
    static func line(for finding: CheckFinding) -> String {
        "\(Mark.failure) \(finding.subject): \(finding.sentence)"
    }

    /// What a graph with nothing wrong with it reads as. Said rather than left silent: a
    /// command that prints nothing is indistinguishable from one that did not run.
    static let nothingFound = "\(Mark.settled) no findings"

    /// What the findings have to be read against when the engine still has work to do, or
    /// nothing when it does not.
    ///
    /// Unmarked: it is neither good news nor bad, and the two marks say only that. It
    /// warns rather than gates — `check` is most wanted for a graph that is stuck, which
    /// is a graph whose nodes stay scheduled, so refusing to answer one would be refusing
    /// the case the command exists for. `wait` is what settles a graph first.
    static func inFlightCaveat(scheduledNodes: Int) -> String? {
        guard scheduledNodes > 0 else {
            return nil
        }
        let nodes = scheduledNodes == 1 ? "node was" : "nodes were"
        return "\(scheduledNodes) \(nodes) still scheduled; a finding about wiring may be work in flight — "
             + "run `wait` first."
    }
}

enum ExplanationRenderer {

    /// What `explain` says when the server has no record to read. Said as what it is,
    /// never as "not touched": a node nothing touched and a settle nobody recorded are
    /// different answers, and the second is the one a restart gives.
    static let noRecord = "No settle has done work since the server started. explain reads the last "
                        + "settle's record, which is kept in memory and forgotten by a restart."

    /// How many of one node's changed wires its line names before counting the rest.
    static let causesNamed = 3

    /// One line per node, indented under the node it woke, from the node asked about down
    /// to the sources that changed. A node two chains share is described
    /// where the walk first meets it and named as "see above" after that, so the tree has
    /// as many lines as the answer has nodes plus one per second meeting.
    ///
    /// Unmarked: a mark says good or bad, and a node that ran is neither.
    static func lines(for explanation: Explanation) -> [String] {
        var lines:   [String] = []
        var printed: Set<Int> = []

        func visit(_ index: Int, depth: Int) {
            guard explanation.nodes.indices.contains(index) else {
                return
            }
            let node   = explanation.nodes[index]
            let indent = String(repeating: "  ", count: depth)
            guard printed.insert(index).inserted else {
                lines.append("\(indent)\(node.label) — see above")
                return
            }
            lines.append("\(indent)\(node.label) — \(summary(of: node))")
            // Each source once under its consumer: a node wired to one source by two
            // ports — a product's value and its metadata — has one child, not two.
            var children: [Int] = []
            for cause in node.causes {
                if let source = cause.source, !children.contains(source) {
                    children.append(source)
                }
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }
        visit(0, depth: 0)

        if explanation.omittedNodes > 0 {
            let nodes = explanation.omittedNodes == 1 ? "node" : "nodes"
            lines.append("… and \(explanation.omittedNodes) more \(nodes) upstream: the walk stops at "
                       + "\(explanation.nodeLimit) nodes, \(explanation.depthLimit) wires deep")
        }
        return lines
    }

    /// What one node did, then the wires that reached it: the ones that brought something
    /// new by name, the ones that woke it with the value they had as a count.
    static func summary(of node: ExplainedNode) -> String {
        var outcome: String
        switch node.outcome {
        case .computed:  outcome = "computed"
        case .fromCache: outcome = "from cache"
        case .notRun:    outcome = "woken, not run (an input was not ready)"
        case .changed:   outcome = "changed"
        case .untouched: return "not touched by the last settle"
        }
        if node.isNew {
            outcome += " (new)"
        }

        let moved     = node.causes.filter { $0.change != .unchanged }
        let unchanged = node.causes.count - moved.count

        var parts = moved.prefix(causesNamed).map(phrase(for:))
        if moved.count > causesNamed {
            parts.append("\(moved.count - causesNamed) more changed")
        }
        if unchanged > 0 {
            parts.append("\(unchanged) \(unchanged == 1 ? "input" : "inputs") unchanged")
        }
        if node.unlistedCauses > 0 {
            parts.append("\(node.unlistedCauses) more \(node.unlistedCauses == 1 ? "input" : "inputs")")
        }

        guard !parts.isEmpty else {
            // A node that ran with no wire behind it and was not created in the settle was
            // put back on the schedule by hand: `nudge`, `reset`, a formula prelude
            // refreshed at start.
            let ran = node.outcome == .computed || node.outcome == .fromCache
            return ran && !node.isNew ? "\(outcome): rescheduled, not woken by a wire" : outcome
        }
        return "\(outcome): \(parts.joined(separator: "; "))"
    }

    /// One wire that brought something: its port, and its name when that says more.
    private static func phrase(for cause: ExplainedCause) -> String {
        let name = cause.wire.isEmpty || cause.wire == cause.port ? cause.port : "\(cause.port) '\(cause.wire)'"
        switch cause.change {
        case .changed:      return "\(name) changed"
        case .connected:    return "\(name) wired"
        case .disconnected: return "\(name) unwired"
        case .unchanged:    return "\(name) unchanged"
        }
    }
}
