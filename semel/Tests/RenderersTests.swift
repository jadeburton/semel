//
//  RenderersTests.swift
//  SemelCLITests
//
//  B-99. The prompt's marks are a set, not a habit: pinned here so a new one cannot be
//  added by a command that felt like it, and so the two that exist keep their meanings.
//

@testable import SemelCLI
import SemelProtocol
import XCTest

final class MarkTests: XCTestCase {

    /// The whole vocabulary. A third mark is a decision, and it belongs in this list
    /// before it belongs in any renderer.
    func test_theMarksAreExactlyThese() {
        XCTAssertEqual(Mark.failure, "❌")
        XCTAssertEqual(Mark.settled, "✅")
        // The third says neither good nor bad, and earns its place by never staying on the
        // screen: it opens the progress line, which is erased before any report prints (B-95).
        XCTAssertEqual(Mark.working, "⏳")
    }
}

/// B-50. What one settle did to the products, under the line that says what it did.
final class ArtifactChangeRendererTests: XCTestCase {

    private func lines(appeared: [String] = [], changed: [String] = [],
                       disappeared: [String] = []) -> [String] {
        ArtifactChangeRenderer.lines(appeared: appeared, changed: changed, disappeared: disappeared)
    }

    /// Unmarked: a mark says good or bad, and an artifact that changed is neither.
    func test_eachKindNamesItsPathsInOrder() {
        XCTAssertEqual(lines(appeared: ["output:/app"],
                             changed: ["output:/lib.a"],
                             disappeared: ["output:/old"]),
                       ["   appeared: output:/app",
                        "   changed: output:/lib.a",
                        "   disappeared: output:/old"])
    }

    func test_aSettleThatMovedNoProductSaysNothing() {
        XCTAssertEqual(lines(), [])
    }

    /// The cap: twenty paths, then how many were left out.
    func test_aKindOverTheCapNamesTwentyAndCountsTheRest() {
        let appeared = (1...25).map { "output:/p\(String(format: "%02d", $0))" }

        let rendered = lines(appeared: appeared)

        XCTAssertEqual(rendered.count, 21)
        XCTAssertEqual(rendered.first, "   appeared: output:/p01")
        XCTAssertEqual(rendered[19], "   appeared: output:/p20")
        XCTAssertEqual(rendered.last, "   and 5 more appeared")
    }

    /// The cap is per kind, not over the three together: a settle that publishes a
    /// thousand products and removes one has to show the removal, and a combined cap
    /// would spend itself on the appearances before reaching it.
    func test_aRemovalIsNamedThoughTheAppearancesFilledTheCap() {
        let appeared = (1...100).map { "output:/p\($0)" }

        let rendered = lines(appeared: appeared, disappeared: ["output:/gone"])

        XCTAssertEqual(rendered.last, "   disappeared: output:/gone")
        XCTAssertEqual(rendered[20], "   and 80 more appeared")
    }
}

final class SettleSummaryRendererTests: XCTestCase {

    private func line(scheduled: Int, computed: Int, fromCache: Int, errors: Int) -> String? {
        SettleSummaryRenderer.line(scheduled: scheduled, computed: computed, fromCache: fromCache, errors: errors)
    }

    /// Nothing was reused, so the settle did all of its own work.
    func test_aSettleThatHitNothingIsMarkedAsSettled() {
        XCTAssertEqual(line(scheduled: 12, computed: 12, fromCache: 0, errors: 0),
                       "✅ 12 nodes scheduled, 12 computed, 0 from cache, 0 errors")
    }

    /// The case the summary exists for wears the same mark: the cache fact is a column,
    /// not a glyph, and the mark says only whether anything is broken.
    func test_aSettleWithCacheHitsWearsTheSameMark() {
        XCTAssertEqual(line(scheduled: 12, computed: 3, fromCache: 9, errors: 0),
                       "✅ 12 nodes scheduled, 3 computed, 9 from cache, 0 errors")
    }

    /// The same mark the error records above it carry, so a failed build reads as one
    /// thing rather than as a wall of ❌ under a ✅.
    func test_aSettleWithErrorsCarriesTheFailureMark() {
        XCTAssertEqual(line(scheduled: 4, computed: 4, fromCache: 0, errors: 2),
                       "❌ 4 nodes scheduled, 4 computed, 0 from cache, 2 errors")
    }

    func test_oneOfEachIsSingular() {
        XCTAssertEqual(line(scheduled: 1, computed: 0, fromCache: 0, errors: 1),
                       "❌ 1 node scheduled, 0 computed, 0 from cache, 1 error")
    }

    /// A settle that woke nothing is not news; the loop passes through idle on every
    /// signal that had no work behind it.
    func test_aSettleThatScheduledNothingRendersNothing() {
        XCTAssertNil(line(scheduled: 0, computed: 0, fromCache: 0, errors: 0))
    }

    /// Nodes woken before their inputs were ready are neither computed nor hits, so the
    /// three numbers need not add up and the line must not pretend they do.
    func test_scheduledNeedNotEqualComputedPlusCached() {
        XCTAssertEqual(line(scheduled: 5, computed: 1, fromCache: 1, errors: 0),
                       "✅ 5 nodes scheduled, 1 computed, 1 from cache, 0 errors")
    }
}

final class ErrorRecordRendererMarkTests: XCTestCase {

    func test_everyRecordOpensWithTheFailureMark() {
        let record = ErrorRecord(label: "StaticFile #12 'input:/a.c'",
                                 entries: [ErrorEntry(ports: ["output"], message: "boom")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile #12 'input:/a.c'", "   · boom", ""])
    }

    /// A file nobody has pushed reads the same over the wire as it does on the engine's own
    /// terminal, down to the count of what it stopped. `UnpushedFileReportingTests` pins the
    /// other side of this pair.
    func test_anUnpushedFileReadsTheSameThroughThisRenderer() {
        let record = ErrorRecord(label: "StaticFile #12 'input:/clang.cfg'",
                                 entries: [ErrorEntry(ports: ["output"],
                                                      message: "clang.cfg has not been pushed")],
                                 downstreamCarrierCount: 2)

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile #12 'input:/clang.cfg'",
                        "   · clang.cfg has not been pushed",
                        "   · and 2 nodes downstream carry it",
                        ""])
    }

    /// B-109. A machine file nobody has written names what writes it, once, under its own
    /// line and above the count of what it stopped — as `ErrorReport.lines` writes it,
    /// which `UnpushedFileReportingTests` pins.
    func test_anUnwrittenMachineFileNamesItsWritersThroughThisRenderer() {
        let writers = [SourceWriter(command: "semel-clang", folder: "."),
                       SourceWriter(command: "semel-swift prepare", folder: ".")]
        let record = ErrorRecord(label: "StaticFile #17 'input:/semel.machine.config'",
                                 entries: [ErrorEntry(ports: ["output"],
                                                      message: "semel.machine.config has not been pushed",
                                                      missingSource: "semel.machine.config",
                                                      writers: writers)],
                                 downstreamCarrierCount: 1)

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile #17 'input:/semel.machine.config'",
                        "   · semel.machine.config has not been pushed",
                        "   · run semel-clang . and semel-swift prepare . to write it",
                        "   · and 1 node downstream carries it",
                        ""])
    }

    /// B-104. A folder is a source too, and the state it publishes sits on a port whose
    /// name is the engine's business: the line names the path to push and nothing else.
    /// `UnpushedFileReportingTests` pins the engine's side of this pair.
    func test_anUnpushedFolderReadsTheSameThroughThisRenderer() {
        let record = ErrorRecord(label: "Folder #12 'input:/src'",
                                 entries: [ErrorEntry(ports: ["pinned"],
                                                      message: "src/ has not been pushed")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ Folder #12 'input:/src'", "   · src/ has not been pushed", ""])
    }

    /// One message across several ports keeps their names, as it does on the engine's
    /// side. The count printed above these lines is a sum of ports, so a heading saying
    /// two errors sits above a line naming two ports.
    func test_onePortIsTheConditionRatherThanOneEntry() {
        let record = ErrorRecord(label: "StaticFile #12 'input:/a.c'",
                                 entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile #12 'input:/a.c'", "   · errorLog, output: boom", ""])
    }

    /// The names come back as soon as there is more than one entry: that is what they are
    /// for, and a record with two messages has something to tell apart.
    func test_theirPortsAreNamedAsSoonAsThereIsMoreThanOneEntry() {
        let record = ErrorRecord(label: "ClangCompiler #12 'input:/a.c'",
                                 entries: [ErrorEntry(ports: ["errorLog"], message: "bang"),
                                           ErrorEntry(ports: ["output"], message: "boom")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ ClangCompiler #12 'input:/a.c'",
                        "   · errorLog: bang",
                        "   · output: boom",
                        ""])
    }

    /// A message spanning lines with no port names to announce puts its first line on the
    /// bullet and indents the rest, which is the engine's twin of this line for line.
    func test_aMultiLineMessageWithoutPortNamesOpensOnTheBullet() {
        let record = ErrorRecord(label: "ClangLinker #12 'input:/semel.fmla'",
                                 entries: [ErrorEntry(ports: ["output"],
                                                      message: "Missing configuration. Add these:\n\nclang.linker.target=…")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ ClangLinker #12 'input:/semel.fmla'",
                        "   · Missing configuration. Add these:",
                        "     clang.linker.target=…",
                        ""])
    }
}

/// B-91. `explain`'s records drawn as a tree: one line per node, indented under the node
/// its changed wire reached, down to the source that changed.
final class ExplanationRendererTests: XCTestCase {

    private func cause(_ port: String, _ wire: String, _ change: ExplainedCause.Change,
                       from source: Int?, label: String = "") -> ExplainedCause {
        ExplainedCause(port: port, wire: wire, change: change, sourceLabel: label, source: source)
    }

    private func node(_ label: String, _ outcome: ExplainedNode.Outcome, isNew: Bool = false,
                      _ causes: [ExplainedCause] = [], unlisted: Int = 0) -> ExplainedNode {
        ExplainedNode(label: label, outcome: outcome, isNew: isNew, causes: causes, unlistedCauses: unlisted)
    }

    private func lines(_ nodes: [ExplainedNode], omitted: Int = 0) -> [String] {
        ExplanationRenderer.lines(for: Explanation(nodes: nodes, omittedNodes: omitted, nodeLimit: 40, depthLimit: 16))
    }

    /// The tutorial's second experiment: one source edited, one chain rebuilt, and the
    /// linker's other objects named only as a count.
    func test_aChainIsDrawnDownToTheSourceThatChanged() {
        let rendered = lines([
            node("OutputFile #62 'output:/hello/hello'", .computed, [cause("input", "hello", .changed, from: 1)]),
            node("ClangLinker #44", .computed, [cause("objects", "hello2.o", .changed, from: 2),
                                                cause("objects", "hello.o", .unchanged, from: nil),
                                                cause("objects", "main.o", .unchanged, from: nil)]),
            node("ClangCompiler #41", .computed, [cause("input", "input", .changed, from: 3)]),
            node("StaticFile #12 'input:/hello/src/hello2.c'", .changed),
        ])

        XCTAssertEqual(rendered, [
            "OutputFile #62 'output:/hello/hello' — computed: input 'hello' changed",
            "  ClangLinker #44 — computed: objects 'hello2.o' changed; 2 inputs unchanged",
            "    ClangCompiler #41 — computed: input changed",
            "      StaticFile #12 'input:/hello/src/hello2.c' — changed",
        ])
    }

    /// A node two chains share is described once, where the walk first meets it.
    func test_aSharedNodeIsDescribedOnceAndNamedAfterThat() {
        let rendered = lines([
            node("Linker #1", .computed, [cause("objects", "a.o", .changed, from: 1),
                                          cause("objects", "b.o", .changed, from: 2)]),
            node("Compiler #2", .computed, [cause("configuration", "cfg", .changed, from: 3)]),
            node("Compiler #3", .computed, [cause("configuration", "cfg", .changed, from: 3)]),
            node("ConfigFilter #4", .computed),
        ])

        XCTAssertEqual(rendered, [
            "Linker #1 — computed: objects 'a.o' changed; objects 'b.o' changed",
            "  Compiler #2 — computed: configuration 'cfg' changed",
            "    ConfigFilter #4 — computed: rescheduled, not woken by a wire",
            "  Compiler #3 — computed: configuration 'cfg' changed",
            "    ConfigFilter #4 — see above",
        ])
    }

    /// The tutorial's fourth experiment: a setting only the linker reads. The linker ran
    /// and wrote the bytes it wrote before, so the product was woken by an unchanged
    /// value — and the line under it says why the linker ran.
    func test_anUnchangedWireIsDrawnDownToTheWorkThatWokeIt() {
        let rendered = lines([
            node("OutputFile #18", .computed, [cause("input", "product", .unchanged, from: 1)]),
            node("ClangLinker #19", .computed, [cause("configuration", "wire0", .changed, from: 2)]),
            node("StaticFile #5 'input:/hello/semel.config'", .changed),
        ])

        XCTAssertEqual(rendered, [
            "OutputFile #18 — computed: 1 input unchanged",
            "  ClangLinker #19 — computed: configuration 'wire0' changed",
            "    StaticFile #5 'input:/hello/semel.config' — changed",
        ])
    }

    /// A product takes its value and its metadata from one node: one child, not two.
    func test_aSourceReachedByTwoWiresIsOneChild() {
        let rendered = lines([
            node("OutputFile #18", .computed, [cause("fileMetadata", "metadata", .changed, from: 1),
                                               cause("input", "product", .changed, from: 1)]),
            node("ClangLinker #19", .computed),
        ])

        XCTAssertEqual(rendered, [
            "OutputFile #18 — computed: fileMetadata 'metadata' changed; input 'product' changed",
            "  ClangLinker #19 — computed: rescheduled, not woken by a wire",
        ])
    }

    func test_aProductTheSettleNeverReachedIsOneLine() {
        XCTAssertEqual(lines([node("OutputFile #7 'output:/hello/config.txt'", .untouched)]),
                       ["OutputFile #7 'output:/hello/config.txt' — not touched by the last settle"])
    }

    /// Answered from the cache: woken by wires that brought nothing new, and nothing below
    /// it is drawn, because nothing below it changed.
    func test_aNodeTheCacheAnsweredCountsTheWiresThatWokeIt() {
        XCTAssertEqual(lines([node("ClangLinker #44", .fromCache, [cause("objects", "a.o", .unchanged, from: nil),
                                                                    cause("configuration", "cfg", .unchanged, from: nil)])]),
                       ["ClangLinker #44 — from cache: 2 inputs unchanged"])
    }

    /// Past three changed wires the line counts; past the listed causes it counts again.
    func test_manyChangedWiresAreNamedToThreeAndCounted() {
        let causes = (1...5).map { cause("objects", "o\($0).o", .changed, from: nil) }

        XCTAssertEqual(lines([node("ClangLinker #44", .computed, causes, unlisted: 7)]),
                       ["ClangLinker #44 — computed: objects 'o1.o' changed; objects 'o2.o' changed; "
                        + "objects 'o3.o' changed; 2 more changed; 7 more inputs"])
    }

    func test_newWiredAndUnwiredAreSaidAsSuch() {
        XCTAssertEqual(lines([node("ClangCompiler #3", .computed, isNew: true,
                                   [cause("input", "main.c", .connected, from: nil),
                                    cause("headers", "old.h", .disconnected, from: nil)])]),
                       ["ClangCompiler #3 — computed (new): input 'main.c' wired; headers 'old.h' unwired"])
    }

    func test_aNodeWokenBeforeItsInputsWereReadySaysSo() {
        XCTAssertEqual(lines([node("ClangCompiler #3", .notRun, [cause("input", "input", .changed, from: nil)])]),
                       ["ClangCompiler #3 — woken, not run (an input was not ready): input changed"])
    }

    /// Stopped by a bound, the answer says how many it left out and what the bound was.
    func test_aWalkStoppedByABoundSaysHowManyItLeftOut() {
        XCTAssertEqual(lines([node("OutputFile #1", .computed, [cause("input", "input", .changed, from: nil)])],
                             omitted: 312).last,
                       "… and 312 more nodes upstream: the walk stops at 40 nodes, 16 wires deep")
    }
}
