//
//  ProductPresenceTests.swift
//  semel_tests
//
//  A pure function, so these need no graph at all — which is the point of it living
//  outside ProjectBuilder.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class ProductPresenceTests: SemelCoreTestCase {

    private func value() throws -> NodeValue { .value(try "Product is up to date".intern()) }
    private var pending: NodeValue { .noValue(reason: .pending) }
    private func failed() throws -> NodeValue { .noValue(reason: .error(messageDataObjectHash: try "boom".intern())) }

    // MARK: - The events

    func test_aProductWithAValueForTheFirstTimeIsCreated() throws {
        let (events, existing) = ProductPresence.reconcile(existingBefore: [],
                                                           statuses: ["output:/a": try value()])

        XCTAssertEqual(events, [.created(path: "output:/a")])
        XCTAssertEqual(existing, ["output:/a"])
    }

    func test_aProductThatLosesItsWireIsDeleted() throws {
        let (events, existing) = ProductPresence.reconcile(existingBefore: ["output:/a"], statuses: [:])

        XCTAssertEqual(events, [.deleted(path: "output:/a")])
        XCTAssertEqual(existing, [])
    }

    /// An OutputFile that exists but failed is not a file. Nothing is there to copy out.
    func test_aProductThatFailsIsDeleted() throws {
        let (events, _) = ProductPresence.reconcile(existingBefore: ["output:/a"],
                                                    statuses: ["output:/a": try failed()])

        XCTAssertEqual(events, [.deleted(path: "output:/a")])
    }

    func test_aProductThatStaysIsNotReported() throws {
        let (events, existing) = ProductPresence.reconcile(existingBefore: ["output:/a"],
                                                           statuses: ["output:/a": try value()])

        XCTAssertEqual(events, [])
        XCTAssertEqual(existing, ["output:/a"])
    }

    // MARK: - The two ways this used to flap

    /// A product goes value → pending → value on every rebuild. Counting pending as absent
    /// would report a delete and a create each time, which is the noise this exists to
    /// remove — so pending means "no news", not "gone".
    func test_pendingDoesNotReportADeletion() throws {
        let (events, existing) = ProductPresence.reconcile(existingBefore: ["output:/a"],
                                                           statuses: ["output:/a": pending])

        XCTAssertEqual(events, [])
        XCTAssertEqual(existing, ["output:/a"], "the product must still be considered present")
    }

    /// And pending on something that never existed must not invent a creation either.
    func test_pendingOnAnUnknownProductReportsNothing() throws {
        let (events, existing) = ProductPresence.reconcile(existingBefore: [],
                                                           statuses: ["output:/a": pending])

        XCTAssertEqual(events, [])
        XCTAssertEqual(existing, [])
    }

    /// The original complaint: an OutputFile is deleted and recreated whenever anything
    /// upstream changes. Keyed by path, that whole cycle is invisible.
    func test_aRebuildAcrossThreePassesReportsNothing() throws {
        var existing: Set<String> = ["output:/a"]
        var allEvents: [ProductEvent] = []

        for status in [pending, pending, try value()] {
            let (events, next) = ProductPresence.reconcile(existingBefore: existing,
                                                            statuses: ["output:/a": status])
            allEvents += events
            existing = next
        }

        XCTAssertEqual(allEvents, [], "a rebuild is not a delete followed by a create")
        XCTAssertEqual(existing, ["output:/a"])
    }

    // MARK: - Ordering and round trip

    /// Events reach the user, and both Set and Dictionary iteration order vary between
    /// processes, so the order has to come from somewhere stable.
    func test_eventsAreOrderedDeterministically() throws {
        let (events, _) = ProductPresence.reconcile(
            existingBefore: [],
            statuses: ["output:/z": try value(), "output:/a": try value(), "output:/m": try value()])

        XCTAssertEqual(events, [.created(path: "output:/a"),
                                .created(path: "output:/m"),
                                .created(path: "output:/z")])
    }

    func test_theSetSurvivesARoundTrip() throws {
        let paths: Set<String> = ["output:/b", "output:/a"]

        let encoded = try ProductPresence.encode(paths)
        XCTAssertEqual(ProductPresence.decode(.value(try encoded.intern())), paths)
    }

    func test_anUnwrittenPortDecodesAsNothingKnown() {
        XCTAssertEqual(ProductPresence.decode(.noValue(reason: .pending)), [])
    }
}
