// EnginePlugin.swift
// semel
//
// Handles: d / debug, n / nudge, e / errors, check, collect, explain / why, reset, t / tools, wait, watch

import Foundation
import SemelNodeKit
import SemelProtocol

final class EnginePlugin: CommandPlugin {

    /// `watch` has no one-letter alias: `w` is free, but it is as much `wait` as `watch`,
    /// and the one of the two that waits for a key is the wrong one to reach by accident.
    let verbs: Set<String> = ["d", "debug", "n", "nudge", "e", "errors", "check", "collect", "explain", "why",
                              "reset", "t", "tools", "wait", "watch"]

    func handle(verb: String, tokens: [String], context: any CommandContext) throws {
        switch verb {
        case "d", "debug":      try handleDebug(tokens: tokens, context: context)
        case "n", "nudge":      _ = try context.request(.nudge)
        case "e", "errors":     try handleErrors(context: context)
        case "check":           try handleCheck(context: context)
        case "collect":         try handleCollect(context: context)
        case "explain", "why":  try handleExplain(tokens: tokens, context: context)
        case "reset":           try handleReset(tokens: tokens, context: context)
        case "t", "tools":      try handleTools(tokens: tokens, context: context)
        case "wait":            try handleWait(context: context)
        case "watch":           try handleWatch(tokens: tokens, context: context)
        default:                break
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

    // MARK: - explain

    /// `explain <path>`: why the last settle did what it did to that node — which nodes
    /// upstream of it ran, which the cache answered, and which wires changed on the way,
    /// down to the sources a push changed (B-91). The server walks and answers records;
    /// the lines are drawn here.
    private func handleExplain(tokens: [String], context: any CommandContext) throws {
        let (flagged, remaining) = parseOptionalFileSystemFlag(tokens: tokens)
        guard let token = remaining.first else {
            throw CommandParserError.missingArgument(command: "explain", expected: "path")
        }
        guard remaining.count == 1 else {
            throw CommandParserError.tooManyArguments(command: "explain")
        }

        let (fileSystem, path) = Self.explainTarget(token, flagged: flagged, context: context)
        let response: DaemonResponse
        do {
            response = try context.request(.explain(fileSystem: fileSystem.kind, path: path.string)).0
        } catch let error as ServerError {
            context.outputError("explain: \(error.description)")
            return
        }
        guard case .explain(let explanation) = response else {
            return
        }
        guard let explanation else {
            context.outputMessage(ExplanationRenderer.noRecord)
            return
        }
        ExplanationRenderer.lines(for: explanation).forEach { context.outputMessage($0) }
    }

    /// Where `explain`'s argument points, named as `ls` and `cp` name things: with its file
    /// system — `output:/hello/hello`, or `-o` before a path from that root — or relative
    /// to the session's current directory in its current file system. Resolved here, so
    /// `..` never reaches the server.
    static func explainTarget(_ token: String, flagged: FileSystemForCommand?,
                              context: any CommandContext) -> (FileSystemForCommand, Path) {
        for fileSystem in [FileSystemForCommand.output, .input] where token.hasPrefix(fileSystem.rootName) {
            let rest = String(token.dropFirst(fileSystem.rootName.count))
            return (fileSystem, context.resolve(rest, relativeTo: .empty))
        }
        let fileSystem = flagged ?? context.currentFileSystem
        let base: Path = flagged != nil ? .empty : context.currentDirectoryPath
        return (fileSystem, context.resolve(token, relativeTo: base))
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
        // The progress line lives exactly as long as the request: ended before the result
        // prints, so the result does not have to step around it.
        context.settleWaitBegan()
        let waited = Result { try context.request(.wait) }
        context.settleWaitEnded()
        _ = try waited.get()
        context.outputMessage("Settled.")
    }

    // MARK: - watch

    /// The first line of a watch: nothing is echoed while it runs, so this is what says
    /// how to leave.
    static let watchBegins = "Watching; any key returns to the prompt."

    /// `watch`: the progress line until a key is pressed, for the person who pushed at the
    /// prompt and wants to look without committing to a wait (B-95). A key leaves the
    /// settle running and says where it stood; nothing running, and the key says that.
    ///
    /// A settle that finishes ends the watch too, as `wait` would end: its summary and the
    /// artifacts it changed print through the indicator as they do during a wait, and then
    /// there is nothing left to look at. Kept open, the watch would sit over a finished
    /// settle, and the person who then started typing their next command would lose its
    /// first letter to the key that ends it.
    private func handleWatch(tokens: [String], context: any CommandContext) throws {
        guard tokens.isEmpty else {
            throw CommandParserError.tooManyArguments(command: "watch")
        }
        // A settle that ends the watch is followed by a wait for the reply's ordering,
        // below, and a batch holds back the signal that wait would wait on (B-61).
        guard context.openBatchDepth == 0 else {
            context.outputError("watch: a batch is open; `commit` ends it and waits")
            return
        }
        let keyReader = context.keyReader
        // A script's standard input is no keyboard: a watch there would never end.
        guard keyReader.isTerminal else {
            context.outputError("watch: standard input is not a terminal, so no key can end it; "
                              + "`wait` blocks until the settle ends")
            return
        }

        let settlesBefore = context.settlesFinished
        context.outputMessage(Self.watchBegins)
        // As `waitForSettle` does, so a settle's error report during the watch counts once.
        context.resetErrorRecordAccounting()
        context.settleWaitBegan()
        let watched = Result { () -> (KeyWait, ProgressRecord?) in
            let outcome = try keyReader.waitForKey(orUntil: { context.settlesFinished != settlesBefore })
            // Read before the line goes: what the key saw is what the line showed.
            let standing = context.settleInProgress
            if outcome == .stopped {
                // The `settled` event has arrived, and the artifact lines follow it on
                // the connection. A wait's reply is sent only after them, so asking for
                // one is what lands `Settled.` under them, as it lands under a `wait`.
                _ = try context.request(.wait)
            }
            return (outcome, standing)
        }
        context.settleWaitEnded()

        let (outcome, standing) = try watched.get()
        switch outcome {
        case .keyPressed: context.outputMessage(ProgressLineRenderer.standing(standing))
        case .stopped:    context.outputMessage("Settled.")
        }
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
