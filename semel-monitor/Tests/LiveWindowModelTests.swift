//
//  LiveWindowModelTests.swift
//  SemelMonitorTests
//
//  B-150 phase 3. The live window as a value, from the events alone: the running nodes
//  with how long each has run on the app's clock, from the record that first listed it;
//  the bar for pending against scheduled; the settle's counts; the last settle's products
//  and errors through the products window's model; and the lines `--print` writes on
//  `show`.
//

import SemelProtocol
import XCTest
@testable import SemelMonitor

final class LiveWindowModelTests: XCTestCase {

    private let clock = ManualClock()

    private func receive(_ events: DaemonEvent..., into model: inout LiveWindowModel) {
        for event in events {
            model.receive(event, at: clock.now)
        }
    }

    // MARK: - While a settle runs

    func test_eachRunningNodesElapsedTimeIsFromTheRecordThatFirstListedIt() {
        var model = LiveWindowModel()
        model.connected()
        receive(Events.progress(running: ["a", "b"]), into: &model)
        clock.advance(by: .milliseconds(1_500))
        receive(Events.progress(running: ["b", "c"]), into: &model)
        clock.advance(by: .milliseconds(600))

        XCTAssertEqual(model.phase, .settling)
        XCTAssertEqual(model.runningRows(at: clock.now), [
            RunningNodeRow(type: "ClangCompiler", name: "src/b.c", elapsed: .milliseconds(2_100)),
            RunningNodeRow(type: "ClangCompiler", name: "src/c.c", elapsed: .milliseconds(600)),
        ])
    }

    func test_twoRunningNodesOfOneDescriptionKeepTheirOwnStart() {
        var model = LiveWindowModel()
        receive(Events.progress(running: ["a"]), into: &model)
        clock.advance(by: .seconds(1))
        receive(Events.progress(running: ["a", "a"]), into: &model)
        XCTAssertEqual(model.runningRows(at: clock.now).map(\.elapsed), [.seconds(1), .zero])
    }

    func test_theBarAndTheCountsAreTheRecordsWhileASettleRuns() {
        var model = LiveWindowModel()
        XCTAssertEqual(model.barFraction, 0)
        XCTAssertNil(model.countsLine)
        receive(Events.progress(scheduled: 88, computed: 31, fromCache: 9, pending: 48, running: ["a", "b"]), into: &model)

        XCTAssertEqual(model.barFraction, 40.0 / 88.0)
        XCTAssertEqual(model.countsLine, "scheduled 88 · computed 31 · from cache 9 · pending 48 · running 2")
        XCTAssertEqual(model.title, "semel · settling")
    }

    // MARK: - After it

    func test_aSettledEndsTheRunningListAndFillsTheBar() {
        var model = LiveWindowModel()
        model.connected()
        receive(Events.progress(running: ["a"]), into: &model)
        receive(.settled(scheduled: 3, computed: 2, fromCache: 1, errors: 0), into: &model)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.runningRows(at: clock.now), [])
        XCTAssertEqual(model.barFraction, 1)
        XCTAssertEqual(model.countsLine, "scheduled 3 · computed 2 · from cache 1 · errors 0")
        XCTAssertEqual(model.lastSettleLine, "last settle: no product moved")
    }

    func test_theLastSettlesProductsAndErrorsAreTheProductsWindowsModel() throws {
        var model = LiveWindowModel()
        let record = Events.compileError(products: Events.products("output:/c/broken"))
        receive(Events.progress(running: ["a"]),
                .errors(records: [record], products: nil),
                .settled(scheduled: 2, computed: 2, fromCache: 0, errors: 1),
                Events.artifacts(appeared: ["output:/c/hello"], changed: ["output:/App/App.app/Info.plist"],
                                 treeFolders: ["output:/App/App.app/Info.plist": "output:/App/App.app"]),
                into: &model)

        let products = try XCTUnwrap(model.lastSettle)
        XCTAssertEqual(products.sections, [.folder("App"), .folder("c"), .errors])
        XCTAssertEqual(products.rows(in: "App").map(\.name), ["App.app/"], "a tree by its folder")
        XCTAssertEqual(products.rows(in: "App").map(\.mark), [.changed])
        XCTAssertEqual(products.rows(in: "c").map(\.name), ["broken", "hello"])
        XCTAssertEqual(products.rows(in: "c").map(\.mark), [.noValue, .appeared])
        XCTAssertEqual(products.title(of: .errors), "Errors (1)")
        XCTAssertEqual(model.lastSettleLine, "last settle: 1 product changed, 1 appeared")

        // The next settle's products replace them only when it ends.
        receive(Events.progress(running: ["b"]), into: &model)
        XCTAssertEqual(model.lastSettle, products)
        receive(.settled(scheduled: 1, computed: 1, fromCache: 0, errors: 0),
                Events.artifacts(changed: ["output:/c/hello"]), into: &model)
        XCTAssertEqual(model.lastSettle?.sections, [.folder("c"), .errors])
        XCTAssertEqual(model.lastSettle?.title(of: .errors), "Errors (0)", "the errors were the earlier settle's")
    }

    func test_aLostEngineEndsTheSettleBeingRead() {
        var model = LiveWindowModel()
        model.connected()
        receive(Events.progress(running: ["a"]), into: &model)
        model.engineLost()
        XCTAssertEqual(model.phase, .noEngine)
        XCTAssertEqual(model.title, "semel · no engine")
        XCTAssertEqual(model.runningRows(at: clock.now), [])
    }

    // MARK: - --print

    func test_theLinesPrintWritesOnShow() {
        var model = LiveWindowModel()
        model.connected()
        receive(Events.progress(scheduled: 4, pending: 2, running: ["a", "b"]), into: &model)
        clock.advance(by: .milliseconds(2_150))
        XCTAssertEqual(LiveWindowText.lines(for: model, at: clock.now), [
            "live: semel · settling",
            "  scheduled 4 · computed 0 · from cache 0 · pending 2 · running 2",
            "  started 2 of 4",
            "  ClangCompiler · src/a.c · 2.1 s",
            "  ClangCompiler · src/b.c · 2.1 s",
        ])

        receive(.settled(scheduled: 4, computed: 4, fromCache: 0, errors: 0),
                Events.artifacts(appeared: ["output:/c/hello", "output:/c/config.txt"]), into: &model)
        XCTAssertEqual(LiveWindowText.lines(for: model, at: clock.now), [
            "live: semel · idle",
            "  scheduled 4 · computed 4 · from cache 0 · errors 0",
            "  started 4 of 4",
            "  nothing running",
            "  last settle: 2 products appeared",
            "  c: config.txt · appeared",
            "  c: hello · appeared",
        ])
    }

    func test_elapsedTimeIsTenthsUnderAMinuteThenMinutes() {
        XCTAssertEqual(ElapsedText.text(.milliseconds(600)), "0.6 s")
        XCTAssertEqual(ElapsedText.text(.milliseconds(12_390)), "12.3 s")
        XCTAssertEqual(ElapsedText.text(.seconds(75)), "1 min 15 s")
    }
}
