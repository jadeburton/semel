//
//  StatusGlyphTests.swift
//  SemelMonitorTests
//
//  B-150 phase 2. The status item's glyph as a function of the app's state — no engine,
//  connected, an error card held — and its shape: three nodes, two wires drawn rim to rim.
//

import XCTest
@testable import SemelMonitor

final class StatusGlyphTests: XCTestCase {

    func test_theGlyphFollowsTheConnectionAndTheHeldErrors() {
        XCTAssertEqual(StatusGlyph.of(state: .noEngine, holdsErrors: false), .noEngine)
        XCTAssertEqual(StatusGlyph.of(state: .noEngine, holdsErrors: true), .noEngine)
        XCTAssertEqual(StatusGlyph.of(state: .connected, holdsErrors: false), .connected)
        XCTAssertEqual(StatusGlyph.of(state: .connected, holdsErrors: true), .errors)
    }

    func test_noEngineIsHollowAndErrorsAreNotATemplate() {
        XCTAssertFalse(StatusGlyph.noEngine.fillsNodes)
        XCTAssertTrue(StatusGlyph.connected.fillsNodes)
        XCTAssertTrue(StatusGlyph.errors.fillsNodes)
        XCTAssertTrue(StatusGlyph.noEngine.isTemplate)
        XCTAssertTrue(StatusGlyph.connected.isTemplate)
        XCTAssertFalse(StatusGlyph.errors.isTemplate, "red is the point, and a template would lose it")
    }

    func test_threeNodesAndTwoWiresDrawnRimToRimInsideTheSquare() {
        XCTAssertEqual(StatusGlyph.nodes.count, 3)
        XCTAssertEqual(StatusGlyph.wires.count, 2)
        for node in StatusGlyph.nodes {
            XCTAssertGreaterThanOrEqual(node.horizontal - StatusGlyph.nodeRadius, 0)
            XCTAssertLessThanOrEqual(node.horizontal + StatusGlyph.nodeRadius, StatusGlyph.side)
            XCTAssertGreaterThanOrEqual(node.vertical - StatusGlyph.nodeRadius, 0)
            XCTAssertLessThanOrEqual(node.vertical + StatusGlyph.nodeRadius, StatusGlyph.side)
        }
        for wire in StatusGlyph.wires {
            let segment = StatusGlyph.segment(of: wire)
            XCTAssertEqual(distance(segment.start, StatusGlyph.nodes[wire.source]), StatusGlyph.nodeRadius, accuracy: 1e-9)
            XCTAssertEqual(distance(segment.end, StatusGlyph.nodes[wire.target]), StatusGlyph.nodeRadius, accuracy: 1e-9)
        }
    }

    func test_thePlannerHoldsAnErrorCardOnScreenOrSwallowedUntilItIsReplaced() {
        let planner = NotificationPlanner(clock: ManualClock())
        XCTAssertFalse(planner.holdsErrorCard)
        let record = Events.compileError(products: Events.products("output:/c/hello"))
        planner.settle(.errors(records: [record]), Events.settled(errors: 1))
        XCTAssertTrue(planner.holdsErrorCard)

        planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/c/hello"]))
        XCTAssertFalse(planner.holdsErrorCard, "a settle that gave the product a value replaced it")

        planner.pause()
        planner.settle(Events.progress(), .errors(records: [record]), Events.settled(errors: 1))
        XCTAssertTrue(planner.holdsErrorCard, "a pause silences the card, not the state")
    }

    private func distance(_ point: GlyphPoint, _ other: GlyphPoint) -> Double {
        let horizontal = point.horizontal - other.horizontal
        let vertical   = point.vertical - other.vertical
        return (horizontal * horizontal + vertical * vertical).squareRoot()
    }
}
