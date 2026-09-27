// EnginePlugin.swift
// semel
//
// Handles: d / debug, n / nudge, e / errors, check, collect, reset, t / tools, wait

import Foundation
import SemelNodeKit
import SemelProtocol

final class EnginePlugin: CommandPlugin {

    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "check", "collect", "reset", "t", "tools", "wait"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":  try handleDebug(tokens: tokens, context: context)
        case "n", "nudge":  _ = try context.request(.nudge)
        case "e", "errors": try handleErrors(context: context)
        case "check":       try handleCheck(context: context)
        case "collect":     try handleCollect(context: context)
        case "reset":       try handleReset(tokens: tokens, context: context)
        case "t", "tools":  try handleTools(tokens: tokens, context: context)
        case "wait":        try handleWait(context: context)
        default:            break
        }
    }

    // MARK: - debug

    /// `debug [<cache key>]`: the whole graph, or the key material of one cache entry —
    /// the text that entry's key is the hash of. Two machines that disagreed about a build
    /// compare two of those texts; a hash on its own says only that they disagreed.
    ///
    /// Either description arrives as the reply's body rather than inside its JSON: the
    /// graph's text runs to megabytes on a real project, and the JSON section is capped.
    private func handleDebug(tokens: [String], context: any CommandContext) throws {
        guard tokens.count <= 1 else {
            context.outputError("debug: takes at most one argument, the key of a cache entry")
            return
        }
        let (response, body) = try context.request(.debug(cacheKey: tokens.first))
        guard case .debug = response else {
            return
        }
        context.outputMessage(String(decoding: body ?? Data(), as: UTF8.self))
    }

    // MARK: - wait

    /// Blocks until the build has settled: every scheduled node processed and nothing
    /// asked for another pass. What a script needs between `push` and `errors`, and what
    /// the prompt otherwise never says — a command returns while the build runs behind it.
    private func handleWait(context: any CommandContext) throws {
        // A batch holds back the very signal the wait would wait on (B-61), so this would
        // block until the commit that nobody can type while it blocks.
        guard context.openBatchDepth == 0 else {
            context.outputError("wait: a batch is open; `commit` ends it and waits")
            return
        }
        try Self.waitForSettle(context: context)
    }

    /// The wait itself, for `wait` and for the `commit` that ends a batch.
    static func waitForSettle(context: any CommandContext) throws {
        // Before, not after: the settle-time event this unblocks (see the idle-time error
        // reporter) can fire and count *during* this request, ahead of `outputMessage`
        // below ever running.
        context.resetErrorRecordAccounting()
        _ = try context.request(.wait)
        context.outputMessage("Settled.")
    }

    // MARK: - tools

    /// With no argument, every namespace. With a prefix, only the namespaces whose name
    /// starts with it — `tools clang` gives the three `clang.*` blocks instead of all
    /// eight. Filtered on the client: the records already carry the namespace, so the
    /// server has nothing to add. A report of what this server's plugins found, and
    /// nothing more: the machine file is written outside Semel, by each toolchain's own
    /// tool (B-119).
    private func handleTools(tokens: [String], context: any CommandContext) throws {
        guard !tokens.contains("--write") else {
            context.outputError("tools: lists what is installed; semel.machine.config is written by each "
                              + "toolchain's own tool — semel-clang <folder>, semel-swift prepare <folder>")
            return
        }
        var tokens = tokens
        var platform = Platform.macos
        if let flag = tokens.firstIndex(of: "--platform") {
            guard flag + 1 < tokens.count, let named = Platform(rawValue: tokens[flag + 1]) else {
                let known = Platform.allCases.map { $0.rawValue }.joined(separator: ", ")
                context.outputError("tools: --platform takes one of \(known)")
                return
            }
            platform = named
            tokens.removeSubrange(flag...(flag + 1))
        }
        guard case .tools(let namespaces) = try context.request(.tools(platform: platform.rawValue)).0 else {
            return
        }
        guard !namespaces.isEmpty else {
            context.outputMessage("No toolchains are registered.")
            return
        }

        var matching = namespaces
        if let prefix = tokens.first {
            matching = namespaces.filter { $0.namespace.hasPrefix(prefix) }
            guard !matching.isEmpty else {
                let known = namespaces.map(\.namespace).sorted().joined(separator: ", ")
                context.outputMessage("No namespace starts with '\(prefix)'. Namespaces: \(known).")
                return
            }
        }

        context.outputMessage(ToolNamespaceRenderer.text(for: matching))
    }

    // MARK: - collect

    /// `collect`: every stored object nothing refers to is deleted, now (B-14). The engine
    /// does the same on its own as the store grows, so this is for the reader who wants
    /// the space back at once, or wants to see what the collector would do.
    private func handleCollect(context: any CommandContext) throws {
        guard case .collected(let removed, let removedBytes, let kept) = try context.request(.collect).0 else {
            return
        }
        let megabytes = String(format: "%.1f", Double(removedBytes) / 1_048_576)
        guard removed > 0 else {
            context.outputMessage("Nothing to collect; \(kept) object\(kept == 1 ? "" : "s") kept.")
            return
        }
        context.outputMessage("Collected \(removed) unreferenced object\(removed == 1 ? "" : "s") (\(megabytes) MB); \(kept) kept.")
    }

    // MARK: - check

    /// Every invariant of the graph that does not hold, one line each. Nothing is repaired:
    /// `reset` is the repair, and this is what says whether it is needed and what to file.
    ///
    /// The findings arrive as the reply's body rather than inside its JSON, for the reason
    /// `debug`'s text does: a badly broken graph has a finding per node, and the JSON
    /// section is capped.
    ///
    /// Each finding is reported through `outputError`, so a scripted run whose graph broke
    /// an invariant exits non-zero — which is what makes `check` a build step in the
    /// harness. Not through `countErrorRecords`: that one deduplicates a report against the
    /// settle event that already named the same failures, and no event ever carries these.
    private func handleCheck(context: any CommandContext) throws {
        let (response, body) = try context.request(.check)
        guard case .check(let scheduledNodes) = response else {
            return
        }
        // A reply with no body is a peer that sent none, not a graph with a finding this
        // end cannot read — so it reads as the empty list it is, rather than as a decode
        // failure standing in for a report.
        let findings = try body.map { try MessageCoder.decode([CheckFinding].self, from: $0) } ?? []

        // First, so it is read before the findings it qualifies. Said rather than acted
        // on: a graph with work in flight is exactly the graph that may be stuck, and a
        // command that waited or refused would have nothing to say about it.
        if let caveat = CheckFindingRenderer.inFlightCaveat(scheduledNodes: scheduledNodes) {
            context.outputMessage(caveat)
        }

        guard !findings.isEmpty else {
            context.outputMessage(CheckFindingRenderer.nothingFound)
            return
        }

        findings.forEach { context.outputError(CheckFindingRenderer.line(for: $0)) }
    }

    // MARK: - reset

    /// `reset [--cache]`: discard the derived graph and rebuild it from what was pushed.
    /// The cached builds are kept, so the rebuild is a pass of cache lookups; `--cache`
    /// discards those too, which is the answer to an entry believed wrong and costs a cold
    /// build of every project in this home.
    private func handleReset(tokens: [String], context: any CommandContext) throws {
        var clearCache = false
        for token in tokens {
            guard token == "--cache" else {
                throw CommandParserError.unknownOption(command: "reset", option: token)
            }
            clearCache = true
        }

        let response = try context.request(.reset(clearCache: clearCache)).0
        if case .reset(let archivedGraphPath) = response, let archivedGraphPath {
            // Said with what to do about it: nothing prunes these copies, and a file in
            // someone's home that nobody claims is a file nobody dares remove.
            context.outputMessage("Graph copied to \(archivedGraphPath) — yours to delete.")
        }
        context.outputMessage(clearCache ? "Cache discarded. Rebuild started." : "Rebuild started.")
        // A reset destroys the state that made it necessary, and `check` is the only thing
        // that can name what was wrong with it — so the offer belongs beside the repair,
        // where the next reader of this reply is standing.
        context.outputMessage("Run `check` before the next reset: it names the invariants a graph is "
                            + "breaking — the evidence a reset discards.")
    }

    // MARK: - errors

    private func handleErrors(context: any CommandContext) throws {
        guard case .errors(let records) = try context.request(.errors).0 else {
            return
        }

        if records.isEmpty {
            context.outputMessage("No errors.")
            return
        }

        // Per node, as the settle summary counts them: a record naming several nodes of one
        // type carries each one's errors.
        let errorCount = records.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.ports.count } * $1.nodeCount }
        let nodeCount  = records.reduce(0) { $0 + $1.nodeCount }

        context.outputMessage("\(errorCount) error\(errorCount == 1 ? "" : "s") across " +
                              "\(nodeCount) node\(nodeCount == 1 ? "" : "s"):\n")

        // Through countErrorRecords, not outputError: a scripted run's exit status rests
        // on the count of settle reports, and the idle-time event this often follows may
        // have already counted this exact one.
        context.countErrorRecords(records)

        for record in records {
            ErrorRecordRenderer.lines(for: record).forEach { context.outputMessage($0) }
        }
    }
}
