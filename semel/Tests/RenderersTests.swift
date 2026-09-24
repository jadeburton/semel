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
        let record = ErrorRecord(label: "StaticFile  'input:/a.c'",
                                 entries: [ErrorEntry(ports: ["output"], message: "boom")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile  'input:/a.c'", "   · boom", ""])
    }

    /// A file nobody has pushed reads the same over the wire as it does on the engine's own
    /// terminal, down to the count of what it stopped. `UnpushedFileReportingTests` pins the
    /// other side of this pair.
    func test_anUnpushedFileReadsTheSameThroughThisRenderer() {
        let record = ErrorRecord(label: "StaticFile  'input:/clang.cfg'",
                                 entries: [ErrorEntry(ports: ["output"],
                                                      message: "clang.cfg has not been pushed")],
                                 downstreamCarrierCount: 2)

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile  'input:/clang.cfg'",
                        "   · clang.cfg has not been pushed",
                        "   · and 2 nodes downstream carry it",
                        ""])
    }

    /// B-104. A folder is a source too, and the state it publishes sits on a port whose
    /// name is the engine's business: the line names the path to push and nothing else.
    /// `UnpushedFileReportingTests` pins the engine's side of this pair.
    func test_anUnpushedFolderReadsTheSameThroughThisRenderer() {
        let record = ErrorRecord(label: "Folder  'input:/src'",
                                 entries: [ErrorEntry(ports: ["pinned"],
                                                      message: "src/ has not been pushed")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ Folder  'input:/src'", "   · src/ has not been pushed", ""])
    }

    /// One message across several ports keeps their names, as it does on the engine's
    /// side. The count printed above these lines is a sum of ports, so a heading saying
    /// two errors sits above a line naming two ports.
    func test_onePortIsTheConditionRatherThanOneEntry() {
        let record = ErrorRecord(label: "StaticFile  'input:/a.c'",
                                 entries: [ErrorEntry(ports: ["errorLog", "output"], message: "boom")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ StaticFile  'input:/a.c'", "   · errorLog, output: boom", ""])
    }

    /// The names come back as soon as there is more than one entry: that is what they are
    /// for, and a record with two messages has something to tell apart.
    func test_theirPortsAreNamedAsSoonAsThereIsMoreThanOneEntry() {
        let record = ErrorRecord(label: "ClangCompiler  'input:/a.c'",
                                 entries: [ErrorEntry(ports: ["errorLog"], message: "bang"),
                                           ErrorEntry(ports: ["output"], message: "boom")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ ClangCompiler  'input:/a.c'",
                        "   · errorLog: bang",
                        "   · output: boom",
                        ""])
    }

    /// A message spanning lines with no port names to announce puts its first line on the
    /// bullet and indents the rest, which is the engine's twin of this line for line.
    func test_aMultiLineMessageWithoutPortNamesOpensOnTheBullet() {
        let record = ErrorRecord(label: "ClangLinker  'input:/semel.fmla'",
                                 entries: [ErrorEntry(ports: ["output"],
                                                      message: "Missing configuration. Add these:\n\nclang.linker.target=…")])

        XCTAssertEqual(ErrorRecordRenderer.lines(for: record),
                       ["❌ ClangLinker  'input:/semel.fmla'",
                        "   · Missing configuration. Add these:",
                        "     clang.linker.target=…",
                        ""])
    }
}
